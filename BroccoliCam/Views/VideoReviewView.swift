import SwiftUI
import AVKit
import AVFoundation

/// 錄影完成：預覽、儲存到照片圖庫、重新錄影、返回。
struct VideoReviewView: View {
    @EnvironmentObject private var camera: CameraService
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    let video: RecordedVideo
    /// 錄完的檢查。
    @ObservedObject var checker: TakeChecker
    /// 這個檔檢查時聽到的字。
    var hearing: (String) -> TakeHearing? = { _ in nil }
    /// 對字幕時聽到的字，交回去存。
    var onHeard: (TakeHearing, String) -> Void = { _, _ in }
    /// 這一頁關掉之後要重錄哪一個檔。
    var onRetake: (String) -> Void = { _ in }
    /// 存到照片成功。
    var onSaved: () -> Void = {}
    /// 使用者不要這一支了。檔案由外面在這一頁關掉之後刪，這裡不刪。
    var onDiscard: () -> Void = {}
    /// 丟掉接成這一支的各段（只有接好的影片會叫）。
    var onDiscardAll: () -> Void = {}

    private enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    @State private var player: AVPlayer?
    @State private var saveState: SaveState = .idle
    @State private var confirmDiscard = false
    @State private var showNotice = false
    @State private var subtitleState: SubtitleState = .idle
    @State private var sharedSubtitle: SharedFile?
    /// 完成頁開過了。被校對頁蓋住再回來時，不要重跳提示、也不要自己播。
    @State private var didStart = false
    /// 正在建字幕專案。
    @State private var isMakingProject = false
    @State private var captionProblem: String?
    @State private var captionTicket: CaptionTicket?
    /// 最近一次打開的專案。
    @State private var openedProject: UUID?
    /// 這支影片已經有字幕專案了。
    @State private var captionProject: CaptionProject?
    @State private var sendsAudioOut = false
    /// 正在聽檢查出來的那一處。
    @State private var playback: TakePlayback?
    /// 在播放視窗按了重錄，等視窗關掉。
    @State private var retakeFile: String?
    /// 字幕檔做好的時候播放視窗還開著，等它關掉再分享。
    @State private var waitingSubtitle: SharedFile?

    private enum SubtitleState: Equatable {
        case idle
        case working
        case done(String)
        case failed(String)
    }

    // body 拆成幾層（畫面、提示、彈出頁），串太長編譯器會算不完。
    var body: some View {
        prompts
            .sheet(item: $sharedSubtitle) { file in
                ShareSheet(items: [file.url])
            }
            .sheet(item: $playback, onDismiss: playbackClosed) { item in
                TakePlaybackView(playback: item, retakeTitle: retakeTitle,
                                 onRetake: { retakeFile = item.file })
            }
            .fullScreenCover(item: $captionTicket, onDismiss: captionClosed) { ticket in
                CaptionEditorView(projectID: ticket.id)
            }
            .statusBarHidden(true)
    }

    private var prompts: some View {
        screen
            .alert(video.isStitched ? "這支影片還沒儲存" : "這支影片還沒儲存，確定要丟掉重錄？",
                   isPresented: $confirmDiscard) {
                discardButtons
            }
            .alert("錄影有狀況", isPresented: $showNotice) {
                Button("好") {}
            } message: {
                Text(video.notice ?? "")
            }
            .onAppear(perform: appeared)
            .onDisappear {
                player?.pause()
                player = nil
            }
    }

    @ViewBuilder
    private var discardButtons: some View {
        if video.isStitched {
            // 各段都還留著，回去只重錄想改的那一段。
            Button("回去重錄其中一段") {
                onDiscard()
                close()
            }
            Button("全部丟掉重來", role: .destructive) {
                onDiscard()
                onDiscardAll()
                close()
            }
        } else {
            Button("丟掉並重錄", role: .destructive) {
                onDiscard()
                close()
            }
        }
        Button("取消", role: .cancel) {}
    }

    private var screen: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 14) {
                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(video.isLandscape ? 16 / 9 : 9 / 16, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    Spacer()
                }

                if case .failed(let message) = saveState {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.yellow)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                checkRow
                captionRow
                subtitleRow
                bottomRow
            }
        }
    }

    // MARK: - 這段檢查

    /// 接好的看各段，單支就看自己。沒有檢查的不列：全部都沒有是沒開，只有幾段沒有是那幾段沒有稿子。
    private var checkEntries: [TakeCheckEntry] {
        guard video.isStitched else {
            guard let check = checker.checks[video.url.lastPathComponent] else { return [] }
            return [TakeCheckEntry(title: nil, url: video.url, check: check)]
        }
        return video.takes.enumerated().compactMap { index, file -> TakeCheckEntry? in
            guard let check = checker.checks[file] else { return nil }
            return TakeCheckEntry(title: "第 \(index + 1) 段", url: TakeStore.shared.url(file), check: check)
        }
    }

    @ViewBuilder
    private var checkRow: some View {
        let entries: [TakeCheckEntry] = checkEntries
        let unscripted: Int = video.isStitched ? max(0, video.takes.count - entries.count) : 0
        if !entries.isEmpty {
            TakeCheckCard(entries: entries, sendsAudioOut: checker.sendsAudioOut,
                          unscripted: unscripted) { entry, issue in
                guard playback == nil, captionTicket == nil, !isMakingProject else { return }
                player?.pause()
                playback = TakePlayback(url: entry.url, title: entry.title, issues: entry.issues, time: issue.time)
            }
            .padding(.horizontal, 16)
        }
    }

    /// 存到照片之後各段就要收掉了，正在做別的事也不能丟，都不給重錄。
    private var retakeTitle: String? {
        switch saveState {
        case .saving, .saved: return nil
        case .idle, .failed: break
        }
        guard !isMakingProject, subtitleState != .working else { return nil }
        return video.isStitched ? "重錄這段" : "重新錄影"
    }

    private func playbackClosed() {
        guard let file = retakeFile else {
            if let waiting = waitingSubtitle {
                waitingSubtitle = nil
                sharedSubtitle = waiting
            }
            return
        }
        retakeFile = nil
        waitingSubtitle = nil
        guard video.isStitched else {
            // 單支丟了就沒了，照樣先問。
            confirmDiscard = true
            return
        }
        // 丟掉的只是接好的這支，各段都還在，重錄完再接一次。
        onDiscard()
        onRetake(file)
        close()
    }

    private var bottomRow: some View {
        HStack(spacing: 12) {
            Button {
                if saveState == .saved {
                    // 單支影片和分段沒關係，不要順手刪掉還沒接完的段落。
                    if video.isStitched { onDiscardAll() }
                    close()
                } else {
                    confirmDiscard = true
                }
            } label: {
                Text(saveState == .saved ? "再錄一支" : (video.isStitched ? "回去修改" : "重新錄影"))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            // 正在複製到照片、或正在連進字幕專案，這時候丟掉會兩頭空。
            .disabled(saveState == .saving || isMakingProject)

            Button {
                save()
            } label: {
                Group {
                    switch saveState {
                    case .saving:
                        ProgressView().tint(.black)
                    case .saved:
                        Label("已儲存", systemImage: "checkmark")
                    default:
                        Text("儲存到照片")
                    }
                }
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(saveState == .saving || saveState == .saved)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func appeared() {
        // 回放時先停相機，並把音訊切到播放，聲音才會從喇叭出來。
        camera.stop()
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
        } catch {
            camera.log("回放音訊設定失敗：\(error.localizedDescription)")
        }
        if player == nil {
            player = AVPlayer(url: video.url)
        }
        guard !didStart else { return }
        didStart = true
        showNotice = video.notice != nil
        player?.play()
        sendsAudioOut = CaptionBridge.sendsAudioOut
        refreshCaptionProject()
    }

    // MARK: - 字幕燒進影片

    private var captionRow: some View {
        VStack(spacing: 6) {
            CaptionWideButton(title: captionTitle, icon: "captions.bubble.fill", prominent: true,
                              busy: isMakingProject, action: addCaptions)
                // SRT 正在辨識的話等它做完，兩邊一起聽會互相打斷。
                .disabled(isMakingProject || subtitleState == .working)
            if sendsAudioOut {
                CaptionNetworkLine()
            }
            if let captionProblem {
                Text(captionProblem)
                    .font(.footnote)
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 16)
    }

    private var captionTitle: String {
        guard let project = captionProject, !project.lines.isEmpty else { return "加字幕" }
        return project.pendingCount > 0 ? "加字幕（還有 \(project.pendingCount) 句）" : "改字幕"
    }

    /// 把影片連進字幕專案，再打開校對頁。專案是獨立的一份，這支之後存掉或丟掉都不影響。
    private func addCaptions() {
        guard !isMakingProject, captionTicket == nil else { return }
        isMakingProject = true
        captionProblem = nil
        player?.pause()
        // 兩邊一起聽會互相打斷，檢查先讓開，校對頁關掉再繼續。
        checker.hold(.captions, true)
        let video = self.video
        let style = settings.captionStyle
        let sources = heard(video.captionSources)
        let whole = heard(video.wholeSource)
        Task { @MainActor in
            do {
                let project = try await Self.project(for: video, sources: sources, whole: whole, style: style)
                openedProject = project.id
                captionTicket = CaptionTicket(id: project.id)
            } catch {
                checker.hold(.captions, false)
                captionProblem = "字幕專案沒有建成：\(error.localizedDescription)"
            }
            isMakingProject = false
        }
    }

    /// 檢查時聽過的帶進去，同一段不辨識兩次。
    private func heard(_ sources: [CaptionSource]) -> [CaptionSource] {
        sources.map { source in
            var result = source
            result.hearing = hearing(source.url.lastPathComponent)
            return result
        }
    }

    private static func project(for video: RecordedVideo, sources: [CaptionSource], whole: [CaptionSource],
                                style: CaptionStyle) async throws -> CaptionProject {
        if let made = await existingProject(for: video) { return made }
        let store = CaptionStore.shared
        do {
            return try await store.create(sources: sources, isLandscape: video.isLandscape, style: style)
        } catch {
            // 有一段連不到，就拿接好的整支來做。
            guard !video.parts.isEmpty else { throw error }
            return try await store.create(sources: whole, isLandscape: video.isLandscape, style: style)
        }
    }

    private static func existingProject(for video: RecordedVideo) async -> CaptionProject? {
        let store = CaptionStore.shared
        if let made = await store.existing(for: video.captionSources) { return made }
        if !video.parts.isEmpty { return await store.existing(for: video.wholeSource) }
        // 重開 App 救回來的接好影片沒有各段的裁切，專案當初是用各段建的，拿段落檔名和總長去對。
        guard video.isStitched, !video.takes.isEmpty else { return nil }
        let length: Double? = try? await AVURLAsset(url: video.url).load(.duration).seconds
        return await store.existing(takes: video.takes, length: length)
    }

    private func refreshCaptionProject() {
        let video = self.video
        Task { @MainActor in
            captionProject = await Self.existingProject(for: video)
        }
    }

    /// 校對頁關掉了。沒對成字幕的空專案收掉，原片還在這一頁。
    private func captionClosed() {
        let video = self.video
        let opened = openedProject
        Task { @MainActor in
            if let opened, FileManager.default.fileExists(atPath: video.url.path) {
                await CaptionStore.shared.discardIfEmpty(opened)
            }
            let project = await Self.existingProject(for: video)
            captionProject = project
            // 校對頁剛聽過的那幾段，檢查就不用再聽。
            for clip in project?.clips ?? [] {
                if let hearing = clip.hearing { onHeard(hearing, clip.file) }
            }
            // 這中間又按了加字幕的話，等那一次關掉再放行。
            if captionTicket == nil, !isMakingProject { checker.hold(.captions, false) }
        }
    }

    // MARK: - 字幕檔

    /// 字幕檔：用稿子對這支影片的聲音，做出 SRT，再交給分享選單（存到檔案、AirDrop、傳到剪輯 App）。
    @ViewBuilder
    private var subtitleRow: some View {
        VStack(spacing: 6) {
            Button {
                makeSubtitles()
            } label: {
                HStack(spacing: 8) {
                    if subtitleState == .working {
                        ProgressView().tint(.white)
                        Text("正在對字幕…")
                    } else {
                        Image(systemName: "captions.bubble")
                        Text("產生字幕檔（SRT）")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(subtitleState == .working || isMakingProject)

            switch subtitleState {
            case .done(let note):
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
    }

    private func makeSubtitles() {
        subtitleState = .working
        player?.pause()
        checker.hold(.subtitles, true)
        let url = video.url
        let script = video.script
        let whole: [CaptionSource] = heard(video.wholeSource)
        let parts: [CaptionSource] = video.parts.isEmpty ? [] : heard(video.captionSources)
        let maxChars = Int(settings.subtitleMaxChars)
        Task {
            do {
                let result = try await SubtitleMaker.make(videoURL: url, whole: whole, parts: parts,
                                                          maxChars: maxChars) { message in
                    camera.log(message)
                }
                await MainActor.run {
                    checker.hold(.subtitles, false)
                    subtitleState = .done(Self.subtitleNote(result, script: script))
                    let file = SharedFile(url: result.url)
                    // 播放視窗開著，分享選單跳不出來。
                    if playback == nil {
                        sharedSubtitle = file
                    } else {
                        waitingSubtitle = file
                    }
                }
            } catch {
                await MainActor.run {
                    checker.hold(.subtitles, false)
                    subtitleState = .failed(error.localizedDescription)
                    camera.log("字幕失敗：\(error.localizedDescription)")
                }
            }
        }
    }

    private static func subtitleNote(_ result: SubtitleMaker.Result, script: String) -> String {
        let count = "共 \(result.cueCount) 句"
        // 字幕檔沒有校對頁，這裡不說就沒有人會知道。
        let doubts = result.doubtCount > 0 ? "有 \(result.doubtCount) 句的數字或字可能和講的不一樣。" : ""
        if script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let failed = result.hasFailures ? "有一段沒辨識到。" : ""
            return "沒有稿子，字幕是直接聽出來的，可能有錯字。\(failed)\(count)。"
        }
        if !result.recognized {
            return "這支手機現在不能辨識中文，時間是照字數平均排的，匯入後請自己調。\(count)。"
        }
        if result.hasFailures {
            // 對不太上可能只是因為沒辨識到，這時候列的也不全是聽到的話。
            let unlike = result.coverage < 0.3 ? "聲音和稿子對不太上，" : ""
            return "\(unlike)有一段沒辨識到，時間是猜的，匯入後請自己調。\(doubts)\(count)。"
        }
        if result.coverage < 0.3 {
            return "聲音和稿子對不太上，列的是聽到的話。\(count)。"
        }
        if result.heardCount * 2 > result.cueCount {
            return "大部分是直接聽出來的，可能有錯字。\(doubts)\(count)。"
        }
        return "\(count)，字用的是你的稿子。\(doubts)"
    }

    private func save() {
        saveState = .saving
        PhotoSaver.save(videoAt: video.url) { result in
            switch result {
            case .success:
                saveState = .saved
                onSaved()
                camera.log("已儲存到照片圖庫")
            case .failure(let error):
                saveState = .failed(error.localizedDescription)
                camera.log("儲存失敗：\(error.localizedDescription)")
            }
        }
    }

    private func close() {
        player?.pause()
        dismiss()
    }
}

/// 要交給分享選單的檔案。
private struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// 系統分享選單。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
