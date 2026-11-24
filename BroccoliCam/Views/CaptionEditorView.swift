import SwiftUI
import AVFoundation
import UIKit

/// 要打開哪一個字幕專案。
struct CaptionTicket: Identifiable, Equatable {
    let id: UUID
}

/// 字幕校對頁。上面是影片（看到的就是會燒的樣子），下面是句子清單。當 fullScreenCover 的內容。
struct CaptionEditorView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var camera: CameraService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: CaptionEditorModel

    private enum Panel {
        case none
        case style
        case shift
    }

    private enum Sheet: Identifiable {
        case srt(String)
        case share(URL)

        var id: String {
            switch self {
            case .srt: return "srt"
            case .share(let url): return url.path
            }
        }
    }

    @State private var panel: Panel = .none
    @State private var keyboardUp = false
    @State private var sheet: Sheet?
    @State private var askReplace = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var askRecognize = false
    @State private var askLeave = false
    @State private var sendsAudioOut = false

    init(projectID: UUID) {
        _model = StateObject(wrappedValue: CaptionEditorModel(id: projectID))
    }

    // body 拆成幾層（畫面、生命週期、彈出視窗），串太長編譯器會算不完。
    var body: some View {
        presented
            .tint(Theme.accent)
            .statusBarHidden(true)
    }

    private var presented: some View {
        alerts
            .sheet(item: $sheet) { item in
                switch item {
                case .srt(let text):
                    CaptionSRTView(text: text) { try model.srtFile() }
                case .share(let url):
                    ShareSheet(items: [url])
                }
            }
    }

    private var alerts: some View {
        lifecycle
            .alert("全部取代", isPresented: $askReplace) {
                TextField("原本的字", text: $findText)
                TextField("換成", text: $replaceText)
                Button("取代") {
                    CaptionKeyboard.settle { model.replaceAll(findText, with: replaceText) }
                }
                Button("取消", role: .cancel) {}
            }
            .alert("重新對字幕？", isPresented: $askRecognize) {
                Button("重新對", role: .destructive) { model.recognizeAgain() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("改過的字會被蓋掉。")
            }
            .alert("字幕還沒存成功", isPresented: $askLeave) {
                Button("再存一次") { leave() }
                Button("不存離開", role: .destructive) { dismiss() }
                Button("取消", role: .cancel) {}
            } message: {
                Text(model.saveError ?? "")
            }
    }

    private var lifecycle: some View {
        screen
            .onAppear(perform: appeared)
            .onDisappear {
                model.teardown()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    model.returnToForeground()
                } else {
                    model.leaveForeground(toBackground: phase == .background)
                }
            }
            .onChange(of: model.shiftOffset) { _, offset in
                // 別的動作把平移收尾了，面板也跟著收。
                if offset == nil, panel == .shift { panel = .none }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardUp = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardUp = false
            }
    }

    private func appeared() {
        // 鏡頭和麥克風先放掉，音訊才切得到播放。
        camera.stop()
        sendsAudioOut = CaptionBridge.sendsAudioOut
        let camera = self.camera
        model.start(
            limits: CaptionEditorModel.Limits(portrait: Int(settings.captionCharsPortrait),
                                              landscape: Int(settings.captionCharsLandscape)),
            log: { [weak camera] message in
                camera?.log(message)
            }
        )
    }

    private var screen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.phase {
            case .loading:
                waiting
            case .recognizing:
                recognizing
            case .failed(let message):
                failed(message)
            case .ready:
                editor
            }
            if model.burn != .none {
                CaptionBurnView(model: model, onShare: shareBurned, onShowSRT: showSRT)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.burn == .none)
    }

    // MARK: - 還沒準備好

    private var waiting: some View {
        VStack(spacing: 24) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            CaptionTextButton(title: "取消") { dismiss() }
        }
    }

    private var recognizing: some View {
        VStack(spacing: 22) {
            CaptionProgressRing(fraction: model.progress)
            Text("正在對字幕")
                .font(.headline)
                .foregroundStyle(.white)
            if sendsAudioOut {
                CaptionNetworkLine()
            }
            CaptionWideButton(title: "取消", prominent: false) {
                if model.isFirstRecognition {
                    dismiss()
                } else {
                    model.cancelRecognizeAgain()
                }
            }
            .frame(maxWidth: 220)
        }
        .padding(24)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text(message)
                .font(.body)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if message == CaptionEditorError.notAuthorized.localizedDescription {
                CaptionWideButton(title: "前往設定", prominent: true, action: openSettings)
            } else {
                CaptionWideButton(title: "再試一次", prominent: true) { model.retry() }
            }
            CaptionWideButton(title: "關閉", prominent: false) { dismiss() }
        }
        .padding(24)
    }

    // MARK: - 校對

    private var editor: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar
                CaptionPlayerSurface(player: model.player)
                    .frame(width: geo.size.width, height: videoHeight(in: geo.size))
                    .contentShape(Rectangle())
                    .onTapGesture { model.togglePlay() }
                    .accessibilityLabel(model.isPlaying ? "暫停" : "播放")
                    .accessibilityAddTraits(.isButton)
                    .overlay { playerProblem }
                CaptionTransport(model: model, clock: model.clock)
                if let message = model.saveError {
                    ScriptErrorBanner(message: message) {
                        model.saveError = nil
                    }
                }
                middle
                if !keyboardUp {
                    bottom
                }
            }
        }
        .overlay(alignment: .center) {
            noteBubble
        }
    }

    /// 鍵盤出來時可用的高度變小，影片跟著縮，句子清單才有地方。
    private func videoHeight(in size: CGSize) -> CGFloat {
        let ratio: CGFloat = model.project.isLandscape ? 9.0 / 16.0 : 16.0 / 9.0
        let natural: CGFloat = size.width * ratio
        return max(80, min(natural, size.height * (keyboardUp ? 0.30 : 0.42)))
    }

    @ViewBuilder
    private var playerProblem: some View {
        if model.isReloading {
            ZStack {
                Color.black
                ProgressView().tint(.white)
            }
        } else if let message = model.playerProblem {
            ZStack {
                Color.black
                VStack(spacing: 2) {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.yellow)
                    CaptionTextButton(title: "重新載入") { model.reloadPlayer() }
                }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            CaptionIconButton(icon: "xmark", label: "關閉", action: leave)
            Spacer(minLength: 4)
            Text(title)
                .font(.headline)
                .foregroundStyle(model.project.pendingCount > 0 ? Color.yellow : Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            CaptionIconButton(icon: "arrow.uturn.backward", label: "撤銷") {
                CaptionKeyboard.settle { model.undo() }
            }
            .disabled(!model.canUndo || panel == .shift)
            moreMenu
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
    }

    private var title: String {
        let count = model.project.pendingCount
        if count > 0 { return "還有 \(count) 句要確認" }
        return model.project.lines.isEmpty ? "沒有字幕" : "都確認了"
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button("全部確認", systemImage: "checkmark.circle") {
                    CaptionKeyboard.settle { model.confirmAll() }
                }
                .disabled(model.project.pendingCount == 0)
                Button("全部取代", systemImage: "character.cursor.ibeam") {
                    findText = ""
                    replaceText = ""
                    model.pause()
                    CaptionKeyboard.settle { askReplace = true }
                }
                Button("整支平移", systemImage: "arrow.left.and.right") {
                    hideKeyboard()
                    // 收鍵盤時最後的字會在這一輪送進來，等它進來再記下平移的起點。
                    DispatchQueue.main.async {
                        model.beginShift()
                        panel = .shift
                    }
                }
            }
            Section {
                Button("看 SRT", systemImage: "doc.text", action: showSRT)
                Button("存原片", systemImage: "film") { model.saveOriginal() }
                    .disabled(model.originalPhoto == .saving)
                if model.burnedURL != nil {
                    Button("字幕版存到照片", systemImage: "photo") { model.saveBurnedToPhotos() }
                        .disabled(model.burnPhoto == .saving)
                    Button("分享字幕版", systemImage: "square.and.arrow.up", action: shareBurned)
                }
            }
            Section {
                Button("重新對字幕", systemImage: "waveform") {
                    hideKeyboard()
                    model.pause()
                    askRecognize = true
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多")
        .disabled(panel == .shift)
    }

    @ViewBuilder
    private var middle: some View {
        if panel == .style {
            ScrollView {
                CaptionStylePicker(style: styleBinding)
                    .padding(16)
            }
            .frame(maxHeight: .infinity)
        } else if model.project.lines.isEmpty {
            VStack(spacing: 16) {
                Text("沒有聽到可以做字幕的話")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.8))
                CaptionTextButton(title: "重新對字幕") { model.recognizeAgain() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            CaptionLineList(model: model, keyboardUp: keyboardUp, isLocked: panel == .shift)
        }
    }

    private var styleBinding: Binding<CaptionStyle> {
        Binding<CaptionStyle>(
            get: { model.project.style },
            set: { model.setStyle($0) }
        )
    }

    // MARK: - 下面一排

    @ViewBuilder
    private var bottom: some View {
        VStack(spacing: 8) {
            switch panel {
            case .none:
                burnBar
            case .style:
                CaptionWideButton(title: "完成", prominent: true) { panel = .none }
            case .shift:
                shiftBar
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.08).ignoresSafeArea(edges: .bottom))
    }

    private var burnBar: some View {
        VStack(spacing: 8) {
            if model.project.isBurnStale {
                Text("字幕改過了，要重燒")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.yellow)
            }
            if model.has4K {
                HStack(spacing: 10) {
                    ForEach(CaptionResolution.allCases) { resolution in
                        CaptionChip(title: resolution.label, selected: model.resolution == resolution) {
                            model.resolution = resolution
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                CaptionWideButton(title: "樣式", icon: "textformat", prominent: false) {
                    hideKeyboard()
                    panel = .style
                }
                .frame(maxWidth: 120)
                CaptionWideButton(title: burnTitle, prominent: true) {
                    hideKeyboard()
                    DispatchQueue.main.async {
                        model.startBurn()
                    }
                }
                .disabled(!model.project.canBurn)
            }
        }
    }

    private var burnTitle: String {
        let count = model.project.pendingCount
        if count > 0 { return "還差 \(count) 句" }
        if !model.project.canBurn { return "沒有要燒的句子" }
        return model.project.burnedFile == nil ? "燒錄" : "重新燒錄"
    }

    @ViewBuilder
    private var shiftBar: some View {
        let gone = model.shiftedOutCount
        if gone > 0 {
            Text(CaptionEditorModel.shiftedOut(gone))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.yellow)
        }
        HStack(spacing: 10) {
            CaptionChip(title: "－0.1", selected: false) { model.shift(by: -0.1) }
                .accessibilityLabel("全部早 0.1 秒")
            Text(shiftText)
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(minWidth: 84)
            CaptionChip(title: "＋0.1", selected: false) { model.shift(by: 0.1) }
                .accessibilityLabel("全部晚 0.1 秒")
            CaptionChip(title: "完成", selected: true) {
                model.endShift()
                panel = .none
            }
        }
    }

    private var shiftText: String {
        let offset = model.shiftOffset ?? 0
        return String(format: "%+.1f 秒", offset == 0 ? 0 : offset)
    }

    @ViewBuilder
    private var noteBubble: some View {
        if let note = model.note {
            Text(note)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.black.opacity(0.8), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
                .padding(.horizontal, 24)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 動作

    /// 最後的字先寫進檔案再關。
    private func leave() {
        hideKeyboard()
        // 收鍵盤時，正在組的字會在這一輪送進來，等它進來再存。
        DispatchQueue.main.async {
            model.finish { saved in
                if saved {
                    dismiss()
                } else {
                    askLeave = true
                }
            }
        }
    }

    private func showSRT() {
        hideKeyboard()
        model.pause()
        sheet = .srt(CaptionBridge.srt(model.project))
    }

    private func shareBurned() {
        guard let url = model.burnedURL else { return }
        hideKeyboard()
        model.pause()
        sheet = .share(url)
    }

    private func hideKeyboard() {
        CaptionKeyboard.hide()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

@MainActor
private enum CaptionKeyboard {
    static func hide() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// 先收鍵盤，等最後的字（注音組到一半的）在這一輪送進來，再做會動到句子的事。
    static func settle(_ action: @escaping () -> Void) {
        hide()
        DispatchQueue.main.async {
            action()
        }
    }
}

/// 連網辨識的提醒，按鈕旁邊那一行小字。
struct CaptionNetworkLine: View {
    var body: some View {
        Text("聲音會送到 Apple 辨識")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.6))
    }
}

/// 44pt 以上的圖示按鈕。
struct CaptionIconButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.white.opacity(isEnabled ? 1 : 0.3))
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - 影片

/// 只有畫面，沒有系統的播放控制，不會蓋住字幕。
private struct CaptionPlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> CaptionPlayerUIView {
        let view = CaptionPlayerUIView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: CaptionPlayerUIView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    static func dismantleUIView(_ view: CaptionPlayerUIView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

private final class CaptionPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // layerClass 已經指定，一定是它。
        layer as! AVPlayerLayer
    }
}

/// 播放鍵、進度條、時間。只有這一條跟著時間重畫。
private struct CaptionTransport: View {
    @ObservedObject var model: CaptionEditorModel
    @ObservedObject var clock: CaptionClock

    private var duration: Double { max(0.1, model.project.duration) }

    var body: some View {
        HStack(spacing: 6) {
            CaptionIconButton(icon: model.isPlaying ? "pause.fill" : "play.fill",
                              label: model.isPlaying ? "暫停" : "播放") {
                model.togglePlay()
            }
            Slider(value: position, in: 0...duration) { editing in
                if editing { model.pause() }
            }
            .accessibilityLabel("播放位置")
            Text(CaptionTime.text(clock.time))
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
    }

    private var position: Binding<Double> {
        Binding<Double>(
            get: { min(max(0, clock.time), duration) },
            set: { model.scrub(to: $0) }
        )
    }
}

enum CaptionTime {
    /// 1:03.4
    static func text(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
        let tenths = Int((seconds * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}

// MARK: - 句子清單

/// 要確認的排最前面，其餘照時間。
private struct CaptionLineList: View {
    @ObservedObject var model: CaptionEditorModel
    let keyboardUp: Bool
    /// 整支平移中：點一句照樣跳過去聽，但不能改。
    let isLocked: Bool

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: model.selectedID) { _, _ in
                    scrollToSelected(proxy)
                }
                .onChange(of: keyboardUp) { _, up in
                    guard up else { return }
                    // 等鍵盤把版面推上來，正在改的那句才不會被蓋住。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        scrollToSelected(proxy)
                    }
                }
        }
    }

    private func scrollToSelected(_ proxy: ScrollViewProxy) {
        guard let selected = model.selectedID else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(selected, anchor: .top)
        }
    }

    private var list: some View {
        List {
            ForEach(model.pending) { line in
                row(line)
            }
            ForEach(model.rest) { line in
                row(line)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .frame(maxHeight: .infinity)
    }

    private func row(_ line: CaptionLine) -> some View {
        CaptionLineRow(
            line: line,
            isSelected: model.selectedID == line.id,
            isPlaying: model.playingID == line.id,
            canMerge: model.selectedID == line.id && model.canMerge(line),
            isLocked: isLocked,
            model: model
        )
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(.white.opacity(0.12))
    }
}

private struct CaptionLineRow: View {
    let line: CaptionLine
    let isSelected: Bool
    let isPlaying: Bool
    let canMerge: Bool
    let isLocked: Bool
    /// 只拿來叫動作，不跟著它重畫。
    let model: CaptionEditorModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(markColor)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 8) {
                meta
                if isSelected && !isLocked {
                    expanded
                } else {
                    collapsedText
                }
            }
            if !isSelected && !isLocked && line.blocksBurning {
                confirmButton
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.white.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var markColor: Color {
        if line.blocksBurning { return .yellow }
        return isPlaying ? Theme.accent : Color.white.opacity(0.18)
    }

    private var meta: some View {
        HStack(spacing: 8) {
            Text("\(CaptionTime.text(line.start)) – \(CaptionTime.text(line.end))")
                .monospacedDigit()
            if line.isHidden {
                Text("不燒")
            }
            if line.blocksBurning {
                Text(statusText)
                    .foregroundStyle(.yellow)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.6))
        .contentShape(Rectangle())
        .onTapGesture { model.select(line.id) }
    }

    private var statusText: String {
        switch line.status {
        case .matched: return ""
        case .uncertain: return "對不太上"
        case .missing: return "沒講到"
        case .extra: return "稿子沒有"
        case .heard: return "聽出來的"
        case .unrecognized: return "沒辨識到"
        }
    }

    private var collapsedText: some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.body.weight(isPlaying ? .semibold : .regular))
            .foregroundStyle(.white.opacity(line.isHidden ? 0.4 : 1))
            .strikethrough(line.isHidden)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.select(line.id) }
            .accessibilityAddTraits(.isButton)
    }

    private var confirmButton: some View {
        Button {
            CaptionKeyboard.settle { model.confirm(line.id) }
        } label: {
            Image(systemName: "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.yellow)
                .frame(width: 48, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("確認")
    }

    // MARK: 展開

    @ViewBuilder
    private var expanded: some View {
        CaptionTextBox(
            text: line.text,
            onChange: { model.setText($0, of: line.id) },
            onCursor: { model.moveCursor($0, in: line.id) },
            onBegin: { model.beganTyping(line.id) },
            onEnd: { model.endedTyping() }
        )
        if line.blocksBurning, line.status == .uncertain,
           let scriptText = line.scriptText, let heardText = line.heardText {
            choice("用稿子的", scriptText)
            choice("用聽到的", heardText)
        }
        tools
        if line.blocksBurning {
            CaptionWideButton(title: "確認", icon: "checkmark", prominent: true) {
                CaptionKeyboard.settle { model.confirm(line.id) }
            }
        }
    }

    private func choice(_ title: String, _ text: String) -> some View {
        Button {
            CaptionKeyboard.settle { model.choose(text, for: line.id) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text(text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var tools: some View {
        HStack(spacing: 4) {
            tool("scissors", "拆開") {
                CaptionKeyboard.settle { model.split(line.id) }
            }
            tool("arrow.down.to.line", "併下句") {
                CaptionKeyboard.settle { model.mergeNext(line.id) }
            }
            .disabled(!canMerge)
            .opacity(canMerge ? 1 : 0.35)
            tool(line.isHidden ? "eye" : "eye.slash", line.isHidden ? "顯示" : "隱藏") {
                CaptionKeyboard.settle { model.toggleHidden(line.id) }
            }
            tool("minus.circle", "早 0.1") { model.nudge(line.id, by: -0.1) }
            tool("plus.circle", "晚 0.1") { model.nudge(line.id, by: 0.1) }
        }
    }

    private func tool(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.body)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 改字用的輸入框。SwiftUI 的輸入框在 iOS 17 拿不到游標位置，所以包 UITextView。
private struct CaptionTextBox: UIViewRepresentable {
    let text: String
    let onChange: (String) -> Void
    let onCursor: (Int) -> Void
    let onBegin: () -> Void
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.isScrollEnabled = false
        view.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        view.layer.cornerRadius = 12
        view.layer.cornerCurve = .continuous
        view.font = UIFont.preferredFont(forTextStyle: .title3)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .white
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        view.returnKeyType = .done
        view.keyboardAppearance = .dark
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.text = text
        context.coordinator.known = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.owner = self
        // 只有外面改了才換字；自己打的不要蓋回去，注音組字才不會斷。
        guard text != context.coordinator.known else { return }
        context.coordinator.known = text
        view.text = text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(48, fit.height))
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        // 列被收走時字還在組，先收進來。
        coordinator.report(view)
        view.delegate = nil
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var owner: CaptionTextBox
        /// 外面知道的字。
        var known = ""

        init(_ owner: CaptionTextBox) {
            self.owner = owner
        }

        func report(_ view: UITextView) {
            let value: String = view.text ?? ""
            guard value != known else { return }
            known = value
            let owner = self.owner
            // 可能正在更新畫面，晚一輪再送。
            DispatchQueue.main.async {
                owner.onChange(value)
            }
        }

        func textViewDidBeginEditing(_ view: UITextView) {
            let owner = self.owner
            DispatchQueue.main.async {
                owner.onBegin()
            }
        }

        func textViewDidChange(_ view: UITextView) {
            // 組字中先不送。
            guard view.markedTextRange == nil else { return }
            report(view)
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            guard view.markedTextRange == nil else { return }
            owner.onCursor(view.selectedRange.location)
        }

        func textViewDidEndEditing(_ view: UITextView) {
            // 收鍵盤才組完的字不一定會通知游標動了，拆句要用，補報一次。
            let owner = self.owner
            owner.onCursor(view.selectedRange.location)
            report(view)
            DispatchQueue.main.async {
                owner.onEnd()
            }
        }

        /// 字幕一句一行：按 Enter 就收鍵盤，貼上的換行改成空格。
        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText: String) -> Bool {
            guard replacementText.contains(where: { $0.isNewline }) else { return true }
            if replacementText.count == 1 {
                view.resignFirstResponder()
                return false
            }
            let flat = replacementText.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
            if let start = view.position(from: view.beginningOfDocument, offset: range.location),
               let end = view.position(from: start, offset: range.length),
               let target = view.textRange(from: start, to: end) {
                view.replace(target, withText: flat)
                report(view)
            }
            return false
        }
    }
}

// MARK: - SRT

/// 看 SRT 的內容，可以分享成檔案。
private struct CaptionSRTView: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    let makeFile: () throws -> URL

    @State private var file: URL?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 16)
                }
                Text(text)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .navigationTitle("SRT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let file {
                        ShareLink(item: file)
                    }
                }
            }
        }
        .onAppear {
            do {
                file = try makeFile()
            } catch {
                problem = "SRT 檔寫不出來：\(error.localizedDescription)"
            }
        }
    }
}
