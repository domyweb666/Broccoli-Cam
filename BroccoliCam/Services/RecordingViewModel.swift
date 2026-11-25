import Foundation
import Combine

/// 接好的影片由哪一段、保留哪個範圍（秒，nil 是整段）、照著唸哪一段稿。
struct RecordedPart: Equatable {
    let url: URL
    let start: Double?
    let end: Double?
    let script: String
}

struct RecordedVideo: Identifiable {
    let id = UUID()
    let url: URL
    /// 是否由多段接成。接成的影片在完成頁可以回去重錄其中一段。
    var isStitched = false
    /// 這支影片照著唸的稿子，產生字幕用。沒有稿子就是空字串。
    var script = ""
    /// 是不是橫式 16:9。
    var isLandscape = false
    /// 這支影片有什麼要告訴使用者的（例如結尾沒存到）。
    var notice: String?
    /// 接成這支的各段檔名。單支是空的。
    var takes: [String] = []
    /// 接片時實際用的各段和裁切範圍，字幕逐段對時用。單支、或重開 App 救回來的是空的。
    var parts: [RecordedPart] = []

    /// 整支當成一段。
    var wholeSource: [CaptionSource] {
        [CaptionSource(url: url, script: script)]
    }

    /// 做字幕專案用的來源：拿得到各段就逐段，不然整支加整份稿子。
    var captionSources: [CaptionSource] {
        guard !parts.isEmpty else { return wholeSource }
        return parts.map { CaptionSource(url: $0.url, start: $0.start, end: $0.end, script: $0.script) }
    }
}

/// 稿子切出來的段落和已錄的不一樣，等使用者決定。
struct ScriptChange: Identifiable {
    let id = UUID()
    /// 已經錄了幾段。
    let count: Int
}

/// 一段錄好的影片，以及錄影當下量到的「有聲音」範圍（秒）。
struct SegmentTake {
    let url: URL
    let firstSound: Double?
    let lastSound: Double?
}

extension SegmentTake {
    init(_ saved: SavedTake, in store: TakeStore) {
        self.init(url: store.url(saved.file), firstSound: saved.firstSound, lastSound: saved.lastSound)
    }

    var saved: SavedTake {
        SavedTake(file: url.lastPathComponent, firstSound: firstSound, lastSound: lastSound)
    }
}

/// 錄影狀態與流程協調：倒數 → 錄影 → （分段：留用或重錄 → 接片）→ 完成頁。
final class RecordingViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case countdown(Int)
        case starting
        case recording
        case finishing
    }

    /// 上次留下來、等使用者決定的東西。
    enum Recovery {
        case video
        case takes
    }

    @Published private(set) var phase: Phase = .idle {
        didSet {
            guard phase == .idle, oldValue != .idle else { return }
            // 錄完的那一段要先記下來，再看有沒有等著套用的新稿。
            DispatchQueue.main.async { [weak self] in
                self?.reconsiderScript()
            }
        }
    }
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var review: RecordedVideo?
    /// 正在問上次留下來的哪一樣。
    @Published private(set) var recovery: Recovery?
    /// 上次留下來幾段。
    @Published private(set) var recoveredCount = 0

    // 分段錄影
    /// 要錄的各段。
    @Published private(set) var pieces: [ScriptPiece] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var takes: [Int: SegmentTake] = [:]
    /// 剛錄完、還沒決定留用或重錄的那一段。
    @Published private(set) var pending: SegmentTake?
    @Published private(set) var isMerging = false
    @Published var mergeError: String?
    /// 這一段的手機擺法和前面幾段不一樣時的提示。
    @Published var orientationError: String?
    /// 錄影失敗、或只存到一部分時的提示。
    @Published var recordingError: String?
    /// 換稿會刪掉已錄的段落，等使用者決定。
    @Published var scriptChange: ScriptChange?
    /// 還沒套用的新稿（錄影中、或使用者選了保留已錄的）。
    private var waitingScript: String?
    /// 使用者選了保留時，新稿切出來的段落。同一份不再問。
    private var declinedPieces: [ScriptPiece]?
    /// 切到「不看」時收起來的段落。檔案不動，切回有字的原樣放回去。
    private var shelf: SavedSession?
    /// 現在是不是照「不看」在錄（段落已經收好）。
    private var isOff = false
    /// 跳轉、切換之後在畫面上閃一下的字，約 1.2 秒自己消失。
    @Published private(set) var jumpNote: String?
    /// 按下錄影那一刻介面轉的角度，錄影中不跟著手機晃動改變。
    @Published private(set) var lockedAngle: Double = 0

    /// 手機現在的擺法（0 直放、±90 橫放），由畫面隨時更新。
    var deviceAngle: Double = 0
    /// 已經錄好的段落是橫的還是直的。還沒有任何一段時是 nil。
    private var takesLandscape: Bool?

    // 存檔
    private let store = TakeStore.shared
    /// 正在錄的檔（和寫檔失敗、等下次開 App 再看的檔）。
    private var recordings: [SavedRecording] = []
    /// 還沒存到照片的完成影片。
    private var videos: [SavedVideo] = []
    /// 接好的那支已經存到照片，接成它的這幾段不用再留。
    private var stitchedTakes: Set<String> = []
    /// 這次開錄的是哪一個檔。等太久取消之後，晚到的回呼靠它認出來不是這一次的。
    private var activeFile: String?
    /// 完成頁正在看的那支，關掉之後看要不要刪檔。
    private var shownVideo: URL?
    /// 上次的分段進度，使用者還沒決定要不要接著錄。
    private var recoveredSession: SavedSession?
    /// 讀完清單之前不能存，不然會用空的蓋掉上次的。
    private var loaded = false
    /// 上次留下來的還沒處理完，先不讓錄。
    private var restoring = true
    /// 按了「看影片」，完成頁還沒出來。
    private var openingVideo = false
    /// 一個視窗收起來之後隔一下再跳下一個，同時換會跳不出來。
    private let alertGap: TimeInterval = 0.45

    let prompter = TeleprompterModel()
    private let follower = SpeechFollower()

    /// 稿件或設定頁開著的時候，不回應音量鍵。
    var hardwareEnabled = true
    /// 從設定打開了字幕校對頁。這時候回到前景不可以把相機叫起來，會搶走音訊。
    var isCaptionEditing = false

    /// 有視窗或完成頁蓋在主畫面上。這時候音量鍵、藍牙鍵都不算數。
    var hasWindow: Bool {
        review != nil || openingVideo || recovery != nil || scriptChange != nil
            || mergeError != nil || orientationError != nil || recordingError != nil
    }

    private weak var camera: CameraService?
    private weak var settings: SettingsStore?
    private var cancellables = Set<AnyCancellable>()
    private var countdownTimer: Timer?
    private var elapsedTimer: Timer?
    private var noteTimer: Timer?
    private var startDate: Date?
    private var autoPrompt = false

    // 錄影中的聲音紀錄
    private var firstSound: Double?
    private var lastSound: Double?
    private var wasSpeaking = false
    private var heldByPause = false
    /// 語音跟隨開著的時候，累計「有在講話」的次數（每次 0.1 秒）。
    private var followSpeakingTicks = 0
    /// 正在問語音辨識的權限，問完之前不重複問。
    private var askingSpeech = false

    /// 判定「有聲音」的門檻（dBFS），比說話偵測寬鬆，寧可少裁。
    private let soundFloor: Float = -45
    private let trimLead: Double = 0.5
    private let trimTail: Double = 0.8

    var isBusy: Bool {
        phase != .idle || isMerging
    }

    /// 稿件有兩段以上才進分段流程；否則行為和一鏡到底一樣。
    var isSegmented: Bool {
        pieces.count > 1
    }

    /// 目前這一段。
    private var currentPiece: ScriptPiece? {
        guard isSegmented, pieces.indices.contains(currentIndex) else { return pieces.first }
        return pieces[currentIndex]
    }

    /// 目前提詞要顯示的文字。
    var currentText: String {
        currentPiece?.text ?? ""
    }

    /// 目前這段是提綱的重點：字不捲、不跟聲音、不等停頓。
    var currentIsPoint: Bool {
        currentPiece?.isPoint ?? false
    }

    /// 整支影片照著唸的稿子，重點不算在內。
    private var joinedScript: String {
        pieces.map(\.captionScript).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var allRecorded: Bool {
        isSegmented && takes.count == pieces.count
    }

    var currentHasTake: Bool {
        takes[currentIndex] != nil
    }

    func attach(_ camera: CameraService, settings: SettingsStore) {
        guard self.camera == nil else { return }
        self.camera = camera
        self.settings = settings
        isOff = settings.promptAmount == PromptAmount.none
        camera.onRecordingFinished = { [weak self] url, note in
            self?.recordingFinished(url, damaged: note != nil)
        }
        camera.onRecordingFailed = { [weak self] url, reason in
            self?.recordingFailed(url, reason)
        }
        camera.onCaptureButton = { [weak self] in
            self?.hardwareButtonPressed()
        }
        follower.onProgress = { [weak self] offset in
            guard let self else { return }
            self.prompter.follow(utf16Offset: offset, in: self.currentText)
        }
        follower.onGaveUp = { [weak self] in
            guard let self, self.prompter.isFollowing else { return }
            self.fallBackToFixedSpeed()
        }
        follower.onLog = { [weak camera] message in
            camera?.log(message)
        }
        // 跟隨中按了「回開頭」：提詞停在開頭，語音也回到開頭等。
        prompter.onReset = { [weak self] in
            guard let self, self.prompter.isFollowing else { return }
            self.follower.suspend()
            self.follower.seek(toUTF16: 0)
            self.followSpeakingTicks = 0
        }
        camera.$isRecording
            .removeDuplicates()
            .sink { [weak self] recording in
                self?.recordingChanged(recording)
            }
            .store(in: &cancellables)
        store.onLog = { [weak camera] message in
            camera?.log(message)
        }
        CaptionStore.shared.onLog = { [weak camera] message in
            camera?.log(message)
        }
        CaptionStore.shared.start()
        loadSaved()
    }

    // MARK: - 存檔與接續

    /// 把現在的狀態存下來，存成功之後才刪 urls。狀態一變就呼叫，內容沒變不會重寫。
    private func persist(deleting urls: [URL] = []) {
        guard loaded else { return }
        store.save(manifest(), deleting: urls.map { $0.lastPathComponent })
    }

    private func manifest() -> TakeManifest {
        var result = TakeManifest()
        let recordingSegment = recordings.contains { $0.index != nil && !$0.failed }
        if let recoveredSession {
            result.session = recoveredSession
        } else if isSegmented, recordedCount > 0 || recordingSegment {
            result.session = liveSession()
        }
        result.shelf = shelf
        // 已經存到照片的那幾段不再提，關掉完成頁才真的刪。
        if !stitchedTakes.isEmpty {
            result.session = result.session?.removing(stitchedTakes)
            result.shelf = result.shelf?.removing(stitchedTakes)
        }
        result.recordings = recordings
        result.videos = videos
        return result
    }

    private func liveSession() -> SavedSession {
        SavedSession(
            segments: pieces.map(\.text), currentIndex: currentIndex, takes: takes.mapValues { $0.saved },
            takesLandscape: takesLandscape, pending: pending?.saved,
            pendingAngle: lockedAngle, declinedSegments: declinedPieces?.map(\.text),
            captionScripts: pieces.map(\.captionScript), points: pieces.map(\.isPoint),
            declinedPoints: declinedPieces?.map(\.isPoint)
        )
    }

    /// 把存下來的進度放回畫面。
    private func apply(_ saved: SavedSession) {
        pieces = saved.pieces
        currentIndex = saved.currentIndex
        takes = saved.takes.mapValues { SegmentTake($0, in: store) }
        takesLandscape = saved.takesLandscape
        pending = saved.pending.map { SegmentTake($0, in: store) }
        if saved.pending != nil { lockedAngle = saved.pendingAngle }
        declinedPieces = saved.declinedPieces
        prompter.reset()
    }

    private func loadSaved() {
        Task {
            let result = await self.store.load()
            await MainActor.run {
                self.recover(result)
            }
        }
    }

    private func recover(_ result: TakeStore.Loaded) {
        for note in result.notes {
            camera?.log(note)
        }
        let saved = result.manifest
        recordings = saved.recordings
        videos = saved.videos
        // 兩個不會同時有東西：分段進度只在有字的時候，切到「不看」就整個收著。
        recoveredSession = saved.session ?? saved.shelf
        recoveredCount = recoveredSession?.count ?? 0
        loaded = true
        guard !videos.isEmpty || recoveredSession != nil else {
            restoring = false
            return
        }
        camera?.log("上次留下 \(recoveredCount) 段、\(videos.count) 支沒儲存的影片")
        askRecovery(after: 0.6)
    }

    /// 上次留下來的一樣一樣問，都問完才讓錄。
    private func askRecovery(after delay: TimeInterval) {
        guard restoring, loaded else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.restoring, self.recovery == nil, self.review == nil, !self.openingVideo else { return }
            if !self.videos.isEmpty {
                self.recovery = .video
            } else if self.recoveredSession != nil {
                self.recovery = .takes
            } else {
                self.finishRecovery()
            }
        }
    }

    private func finishRecovery() {
        restoring = false
        persist()
        // 稿子和當時不一樣的話，走一般的換稿確認。
        updateScript(settings?.activeScript ?? "")
    }

    /// 看上次沒儲存的影片。接好的那種連同各段一起放回來，才能回去只重錄其中一段。
    func openRecoveredVideo() {
        recovery = nil
        guard let video = videos.first else {
            askRecovery(after: alertGap)
            return
        }
        openingVideo = true
        if video.isStitched { takeBackSession() }
        DispatchQueue.main.asyncAfter(deadline: .now() + alertGap) { [weak self] in
            guard let self else { return }
            self.openingVideo = false
            self.show(RecordedVideo(url: self.store.url(video.file), isStitched: video.isStitched,
                                    script: video.script, isLandscape: video.isLandscape,
                                    notice: video.notice, takes: video.takes ?? []))
        }
    }

    func deleteRecoveredVideo() {
        recovery = nil
        if !videos.isEmpty {
            let video = videos.removeFirst()
            persist(deleting: [store.url(video.file)])
        }
        askRecovery(after: alertGap)
    }

    func resumeRecoveredTakes() {
        recovery = nil
        let outlined: Bool = recoveredSession?.pieces.contains { $0.isPoint } ?? false
        takeBackSession()
        // 要接著錄就得看稿；停在「不看」的話，那些段落看起來會像不見了。當初用哪一種錄的就切回哪一種。
        if let settings, settings.promptAmount == PromptAmount.none {
            settings.promptAmount = outlined ? PromptAmount.outline : PromptAmount.full
            applyMode()
        }
        askRecovery(after: alertGap)
    }

    func deleteRecoveredTakes() {
        recovery = nil
        let files = recoveredSession?.files ?? []
        recoveredSession = nil
        persist(deleting: files.map { store.url($0) })
        askRecovery(after: alertGap)
    }

    /// 上次的分段進度放回來：有字的直接接上，選不看的先收著。
    private func takeBackSession() {
        guard let saved = recoveredSession else { return }
        recoveredSession = nil
        if isOff {
            shelf = saved
        } else {
            apply(saved)
        }
        persist()
    }

    /// 進完成頁。
    private func show(_ video: RecordedVideo) {
        let file = video.url.lastPathComponent
        if !videos.contains(where: { $0.file == file }) {
            videos.append(SavedVideo(file: file, isStitched: video.isStitched, script: video.script,
                                     isLandscape: video.isLandscape, notice: video.notice,
                                     takes: video.isStitched ? video.takes : nil))
        }
        shownVideo = video.url
        review = video
        persist()
    }

    /// 已經存到照片。檔案等完成頁關掉才刪，還要拿來做字幕。
    func reviewSaved(_ video: RecordedVideo) {
        videos.removeAll { $0.file == video.url.lastPathComponent }
        if video.isStitched { stitchedTakes = Set(video.takes) }
        persist()
    }

    /// 使用者不要這一支了。檔案等完成頁關掉才刪，播放器還開著它。
    func reviewDiscarded(_ video: RecordedVideo) {
        videos.removeAll { $0.file == video.url.lastPathComponent }
        persist()
    }

    /// 完成頁關掉了。沒存、也沒說不要的，檔案留著。
    func reviewDismissed() {
        if !stitchedTakes.isEmpty { discardTakes(stitchedTakes) }
        if let url = shownVideo {
            shownVideo = nil
            if !videos.contains(where: { $0.file == url.lastPathComponent }) {
                persist(deleting: [url])
            }
        }
        askRecovery(after: alertGap)
    }

    // MARK: - 稿件

    /// 稿件內容、分段開關變了就重新切段。切出來不同、又已經錄了幾段時先問（force 是已經問過了）。
    /// 錄影中先記著，回到待機再套。
    func updateScript(_ script: String, force: Bool = false) {
        // 模式還沒換好就拿新模式的稿子來比，會誤刪已錄的。
        applyMode()
        guard split(script) != pieces else {
            waitingScript = nil
            declinedPieces = nil
            return
        }
        waitingScript = script
        guard phase == .idle, !isMerging, review == nil else { return }
        if force || recordedCount == 0 {
            discardAllTakes()
            return
        }
        guard split(script) != declinedPieces else { return }
        scriptChange = ScriptChange(count: recordedCount)
    }

    /// 換稿：已錄的各段作廢。
    func acceptScriptChange() {
        scriptChange = nil
        // 視窗開著時用別的辦法開錄了：現在刪會刪到正在錄的。新稿還記著，回到待機會再問一次。
        guard phase == .idle, !isMerging else { return }
        // 沒有等著的新稿就沒有換稿這回事，不能刪。
        guard waitingScript != nil else { return }
        discardAllTakes()
    }

    /// 保留已錄的：沿用原本的段落繼續錄，全部清掉之後才套新稿。
    func declineScriptChange() {
        scriptChange = nil
        declinedPieces = waitingScript.map { split($0) }
        persist()
    }

    /// 換了「看多少字」。有字和不看之間收放段落；全稿和提綱切出來不一樣，已經錄了就走換稿那一套。
    /// 這裡不問換稿：選單或設定頁還開著，視窗跳不出來，先記著，等那一頁關掉再由 reconsiderScript 看。
    func promptAmountChanged() {
        applyMode()
        waitingScript = settings?.activeScript ?? ""
        // 一段都還沒錄，沒有東西會不見，馬上換給使用者看。
        if recordedCount == 0 { reconsiderScript() }
        prompter.reset()
    }

    /// 有字和不看切換。不看的時候沒有稿，但稿子沒有變，已錄的各段先收著，切回有字再放回來。
    /// 有沒有聆聽者和段落無關，不會走到這裡。
    func applyMode() {
        guard let settings else { return }
        let off: Bool = settings.promptAmount == PromptAmount.none
        guard off != isOff else { return }
        guard phase == .idle, !isMerging, review == nil else { return }
        isOff = off
        scriptChange = nil
        if off {
            shelveTakes()
        } else {
            restoreTakes()
        }
    }

    private func shelveTakes() {
        if recordedCount > 0 {
            shelf = liveSession()
        }
        // 檔案交給 shelf 了，先清空，discardAllTakes 才不會刪到。
        takes = [:]
        pending = nil
        waitingScript = settings?.activeScript ?? ""
        discardAllTakes()
    }

    private func restoreTakes() {
        waitingScript = settings?.activeScript ?? ""
        guard let saved = shelf else {
            discardAllTakes()
            return
        }
        shelf = nil
        apply(saved)
        persist()
    }

    /// 有等著套用的模式或新稿就再看一次能不能套。
    func reconsiderScript() {
        applyMode()
        guard waitingScript != nil else { return }
        // 等的期間可能又換過看多少字，當時記的稿子配現在的切法會比錯，一律拿現在的。
        updateScript(settings?.activeScript ?? "")
    }

    private func split(_ script: String) -> [ScriptPiece] {
        ScriptSegments.pieces(of: script, amount: settings?.promptAmount ?? PromptAmount.full,
                              segmented: settings?.segmentedRecording ?? true)
    }

    private var recordedCount: Int {
        takes.count + (pending == nil ? 0 : 1)
    }

    // MARK: - 錄影鈕

    /// 錄影鈕：待機 → 倒數／開始；倒數中 → 取消；錄影中 → 停止。
    func primaryTapped(countdown: Int, autoPrompt: Bool) {
        if restoring {
            guard !openingVideo else { return }
            // 上次留下來的還沒決定。視窗沒跳出來（當時有別的頁面開著）的話，在這裡再問一次。
            recovery = nil
            askRecovery(after: 0.1)
            return
        }
        guard !isMerging, pending == nil else { return }
        switch phase {
        case .idle:
            lockedAngle = deviceAngle
            // 分段錄影：每一段的擺法要一樣，不然接起來會有一段是倒的。
            if isSegmented, !takes.isEmpty, let first = takesLandscape, first != (lockedAngle != 0) {
                orientationError = first
                    ? "前面幾段是橫著錄的，請把手機橫放再錄這一段。"
                    : "前面幾段是直著錄的，請把手機直放再錄這一段。"
                return
            }
            // 重點是靜止的，不用播。
            self.autoPrompt = autoPrompt && !currentIsPoint
            // 唸過的字要變色的話，另一套排版先建好，不要錄到一半才卡一下。
            if settings?.voiceFollow ?? false, !currentIsPoint { prompter.prepareSpoken(in: currentText) }
            if countdown > 0 {
                startCountdown(countdown)
            } else {
                beginRecording()
            }
        case .countdown:
            cancelCountdown()
        case .recording:
            stopRecording()
        case .starting, .finishing:
            break
        }
    }

    /// 音量鍵或藍牙遙控器：等同錄影鈕；剛錄完一段時等同「留用」。
    private func hardwareButtonPressed() {
        guard hardwareEnabled, !hasWindow, !isMerging, !restoring, let settings else { return }
        if pending != nil {
            acceptPending()
        } else {
            primaryTapped(
                countdown: settings.countdown,
                autoPrompt: settings.autoStartPrompter && settings.usesPrompter
            )
        }
    }

    func togglePrompter() {
        guard !currentIsPoint else { return }
        heldByPause = false
        guard phase == .recording else {
            prompter.toggle()
            return
        }
        if prompter.isPlaying {
            prompter.pause()
            // 暫停中講的話不算在稿子裡。
            if prompter.isFollowing { follower.suspend() }
        } else if prompter.isFollowing {
            prompter.play()
            let here = prompter.readingOffset(in: currentText)
            prompter.jump(toUTF16: here, in: currentText)
            follower.resume(atUTF16: here)
            followSpeakingTicks = 0
        } else {
            // 先播再跟：捲到底再按會先回開頭，跟隨才會從開頭開始。
            prompter.play()
            startFollowingIfWanted()
        }
    }

    /// App 進背景等情況：有在錄就收尾，倒數就取消。
    func interrupt() {
        switch phase {
        case .countdown:
            cancelCountdown()
        case .recording, .starting:
            stopRecording()
        case .idle, .finishing:
            break
        }
    }

    // MARK: - 分段

    /// 留用剛錄的這段，跳到下一個還沒錄的段落；全部錄完就接片。
    func acceptPending() {
        guard let take = pending, !restoring else { return }
        let replaced = takes[currentIndex]
        takes[currentIndex] = take
        takesLandscape = lockedAngle != 0
        pending = nil
        prompter.reset()
        let next = (0..<pieces.count).first { takes[$0] == nil }
        if let next { currentIndex = next }
        persist(deleting: replaced.map { [$0.url] } ?? [])
        if next == nil { mergeAll() }
    }

    /// 丟掉剛錄的這段，留在同一段準備重錄。
    func retakePending() {
        guard let take = pending, !restoring else { return }
        pending = nil
        persist(deleting: [take.url])
        prompter.reset()
    }

    /// 切到前一段／後一段（要重錄某一段時用）。
    func step(_ delta: Int) {
        guard !isBusy, pending == nil, isSegmented else { return }
        let target = min(pieces.count - 1, max(0, currentIndex + delta))
        guard target != currentIndex else { return }
        currentIndex = target
        persist()
        prompter.reset()
    }

    /// 把各段照順序接成一支影片，完成後進完成頁。
    func mergeAll() {
        guard allRecorded, !isMerging, pending == nil, !restoring else { return }
        let trim = settings?.trimSilence ?? true
        let parts: [RecordedPart] = (0..<pieces.count).compactMap { index in
            guard let take = takes[index] else { return nil }
            var start: Double?
            var end: Double?
            if trim, let first = take.firstSound, let last = take.lastSound {
                start = max(0, first - trimLead)
                end = last + trimTail
            }
            return RecordedPart(url: take.url, start: start, end: end, script: pieces[index].captionScript)
        }
        // 接片和字幕專案用同一組範圍，時間才對得上。
        let clips: [VideoStitcher.Clip] = parts.map { part in
            VideoStitcher.Clip(url: part.url, start: part.start, end: part.end)
        }
        isMerging = true
        let file = TakeStore.newFileName(merged: true)
        let output = store.url(file)
        let sources = clips.map { $0.url.lastPathComponent }
        // 先記下由哪幾段接成。接完還沒進完成頁就被滑掉，下次才認得出是這一批。
        recordings.append(SavedRecording(file: file, index: nil, script: joinedScript,
                                         angle: lockedAngle, takes: sources))
        persist()
        camera?.log("開始接片：\(clips.count) 段，裁靜音 \(trim ? "開" : "關")")
        Task {
            do {
                guard self.store.flush() else { throw VideoStitchError.exportFailed("手機空間不夠") }
                try await VideoStitcher.stitch(clips, to: output)
                await MainActor.run {
                    self.isMerging = false
                    self.recordings.removeAll { $0.file == file }
                    self.camera?.log("接片完成")
                    self.show(RecordedVideo(url: output, isStitched: true,
                                            script: self.joinedScript,
                                            isLandscape: self.takesLandscape ?? false, takes: sources,
                                            parts: parts))
                }
            } catch {
                await MainActor.run {
                    self.isMerging = false
                    self.recordings.removeAll { $0.file == file }
                    self.persist(deleting: [output])
                    self.mergeError = error.localizedDescription
                    self.camera?.log("接片失敗：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 丟掉接成這支影片的各段。
    func discardTakes(of video: RecordedVideo) {
        discardTakes(Set(video.takes))
    }

    /// 只丟這幾個檔，不在裡面的段落不動。
    private func discardTakes(_ files: Set<String>) {
        var doomed: [URL] = []
        if let saved = shelf {
            let gone = saved.files.filter { files.contains($0) }
            if !gone.isEmpty {
                shelf = saved.removing(files)
                doomed += gone.map { store.url($0) }
            }
        }
        let kept = takes.filter { !files.contains($0.value.url.lastPathComponent) }
        stitchedTakes = []
        if kept.isEmpty && pending == nil {
            discardAllTakes()
            persist(deleting: doomed)
            return
        }
        doomed += takes.values.map { $0.url }.filter { files.contains($0.lastPathComponent) }
        takes = kept
        if kept.isEmpty { takesLandscape = nil }
        persist(deleting: doomed)
    }

    /// 丟掉所有已錄的段落，回到第一段。
    func discardAllTakes() {
        var files = takes.values.map { $0.url }
        if let take = pending { files.append(take.url) }
        takes = [:]
        takesLandscape = nil
        pending = nil
        currentIndex = 0
        stitchedTakes = []
        if let waiting = waitingScript {
            waitingScript = nil
            declinedPieces = nil
            pieces = split(waiting)
        }
        persist(deleting: files)
        prompter.reset()
    }

    // MARK: - 倒數

    private func startCountdown(_ seconds: Int) {
        phase = .countdown(seconds)
        countdownTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.countdownTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func countdownTick() {
        guard case .countdown(let remaining) = phase else {
            countdownTimer?.invalidate()
            countdownTimer = nil
            return
        }
        if remaining <= 1 {
            countdownTimer?.invalidate()
            countdownTimer = nil
            beginRecording()
        } else {
            phase = .countdown(remaining - 1)
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        phase = .idle
    }

    // MARK: - 錄影

    private func beginRecording() {
        phase = .starting
        elapsed = 0
        // 先記下要寫哪個檔、是哪一段，存好了相機才開錄。錄到一半被滑掉，下次才找得回來。
        let file = TakeStore.newFileName()
        activeFile = file
        // 稿子存這一段的，救成單支時字幕才對得上。
        recordings.append(SavedRecording(file: file, index: isSegmented ? currentIndex : nil,
                                         script: currentPiece?.captionScript ?? "", angle: lockedAngle))
        persist()
        let store = self.store
        let url = store.url(file)
        camera?.startRecording(landscape: lockedAngle != 0, to: url) {
            store.flush()
        }
        // 3 秒內沒有真的開始錄，就回到待機，不要卡住。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.phase == .starting, self.activeFile == file else { return }
            self.activeFile = nil
            self.camera?.cancelStart(url)
            self.camera?.log("錄影未在 3 秒內開始")
            self.phase = .idle
            self.recordingError = "相機沒有開始錄，請再試一次"
        }
    }

    private func stopRecording() {
        phase = .finishing
        prompter.pause()
        camera?.stopRecording()
    }

    private func recordingChanged(_ recording: Bool) {
        // 等太久已經取消的那一個晚點才動起來，不算這一次的。
        guard let activeFile, camera?.recordingURL?.lastPathComponent == activeFile else { return }
        if recording {
            phase = .recording
            // 開防抖時影格晚到，影片第 0 秒比現在早，裁靜音的時間要對回去。
            startDate = Date().addingTimeInterval(-(camera?.recordingLag ?? 0))
            elapsed = 0
            firstSound = nil
            lastSound = nil
            wasSpeaking = false
            heldByPause = false
            elapsedTimer?.invalidate()
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.recordingTick()
            }
            RunLoop.main.add(timer, forMode: .common)
            elapsedTimer = timer
            if autoPrompt {
                prompter.play()
            }
            if prompter.isPlaying {
                startFollowingIfWanted()
            }
        } else {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
            startDate = nil
            stopFollowing()
            prompter.pause()
            // 被系統中斷而停止時，等檔案回呼。
            if phase == .recording {
                phase = .finishing
            }
        }
    }

    /// 錄影中每 0.1 秒：更新計時、記下有聲音的範圍、停頓時讓提詞等人。
    private func recordingTick() {
        guard let start = startDate else { return }
        let time = Date().timeIntervalSince(start)
        if Int(time) != Int(elapsed) {
            elapsed = time
        }
        guard let meter = camera?.meter else { return }

        if meter.level > soundFloor {
            if firstSound == nil { firstSound = time }
            lastSound = time
        }

        let speaking = meter.isSpeaking
        if prompter.isFollowing {
            // 跟著聲音走的時候不用「停頓等人」，沒唸就不會動。
            // 講了一陣子卻一個字都沒對上，代表辨識沒作用，退回固定速度。
            if speaking && prompter.isPlaying { followSpeakingTicks += 1 }
            if followSpeakingTicks > 60 && follower.matchCount == 0 {
                camera?.log("語音跟隨沒有對上稿子，改回固定速度")
                fallBackToFixedSpeed()
            }
        } else if settings?.waitOnPause ?? false, !currentIsPoint {
            if wasSpeaking && !speaking && prompter.isPlaying {
                prompter.pause()
                heldByPause = true
            } else if !wasSpeaking && speaking && heldByPause {
                heldByPause = false
                prompter.play()
            }
        }
        wasSpeaking = speaking
    }

    private func recordingFinished(_ url: URL, damaged: Bool) {
        guard url.lastPathComponent == activeFile else {
            keepForLater(url)
            return
        }
        activeFile = nil
        phase = .idle
        recordings.removeAll { $0.file == url.lastPathComponent }
        let notice: String? = damaged ? "結尾有一小段沒存到" : nil
        if isSegmented {
            pending = SegmentTake(url: url, firstSound: firstSound, lastSound: lastSound)
            recordingError = notice
            persist()
        } else {
            show(RecordedVideo(url: url, script: pieces.first?.captionScript ?? "", isLandscape: lockedAngle != 0,
                               notice: notice))
            // 跟隨會從目前讀到的位置開始，下一次重錄要從頭。
            prompter.reset()
        }
    }

    // MARK: - 跳轉

    /// 往下或往上跳。分段錄影沒在錄時是換段；錄影中、或整篇一鏡到底時，在提詞裡跳一段或一行。
    func jump(forward: Bool) {
        guard settings?.usesPrompter ?? false, !isMerging, pending == nil, phase != .finishing else { return }
        if isSegmented && phase == .idle {
            jumpSegment(forward: forward)
            return
        }
        let text = currentText
        // 重點整張看得到，沒有東西要跳。
        guard !text.isEmpty, !currentIsPoint else { return }
        let starts = TeleprompterModel.paragraphStarts(of: text)
        // 只有一個段落，逐段等於不能跳，改成逐行。
        if settings?.jumpMode == .paragraph && starts.count > 1 {
            jumpParagraph(forward: forward, starts: starts, in: text)
        } else {
            jumpLine(forward: forward, in: text)
        }
    }

    /// 點了提詞裡的某一行。
    func jumpTo(utf16Offset: Int) {
        guard settings?.usesPrompter ?? false, !currentIsPoint, !isMerging, phase != .finishing else { return }
        moveReading(to: utf16Offset)
    }

    private func jumpSegment(forward: Bool) {
        let target = currentIndex + (forward ? 1 : -1)
        guard pieces.indices.contains(target) else {
            showNote(forward ? "到結尾了" : "到開頭了")
            return
        }
        step(forward ? 1 : -1)
        showNote("第 \(currentIndex + 1) 段")
    }

    private func jumpParagraph(forward: Bool, starts: [Int], in text: String) {
        let here = prompter.readingOffset(in: text)
        let current = starts.lastIndex { $0 <= here } ?? 0
        let target: Int
        if forward {
            guard current + 1 < starts.count else {
                showNote("到結尾了")
                return
            }
            target = current + 1
        } else if current == 0 {
            moveReading(to: starts[0])
            showNote("到開頭了")
            return
        } else {
            // 已經唸進這段了就先回這段開頭，還在開頭附近才到上一段。
            target = spokenCount(from: starts[current], to: here, in: text) > 3 ? current : current - 1
        }
        moveReading(to: starts[target])
        // 分段錄影裡的是「這一段裡的小段」，不要和分段列的第幾段混在一起。
        showNote(isSegmented ? "第 \(target + 1) 小段" : "第 \(target + 1) 段")
    }

    private func jumpLine(forward: Bool, in text: String) {
        let here = prompter.readingOffset(in: text)
        if forward {
            guard let next = prompter.nextLineStart(after: here, in: text) else {
                showNote("到結尾了")
                return
            }
            moveReading(to: next)
            showNote("下一行")
        } else {
            guard let previous = prompter.previousLineStart(before: here, in: text) else {
                moveReading(to: 0)
                showNote("到開頭了")
                return
            }
            moveReading(to: previous)
            showNote("上一行")
        }
    }

    /// 這兩個位置之間有幾個會唸出來的字。
    private func spokenCount(from start: Int, to end: Int, in text: String) -> Int {
        guard end > start else { return 0 }
        return SpokenKeys.keys(of: text).filter { $0.utf16Offset >= start && $0.utf16Offset < end }.count
    }

    /// 提詞捲過去，語音跟隨也從那裡接著聽。
    private func moveReading(to utf16Offset: Int) {
        prompter.jump(toUTF16: utf16Offset, in: currentText)
        guard prompter.isFollowing else { return }
        follower.seek(toUTF16: utf16Offset)
        followSpeakingTicks = 0
    }

    private func showNote(_ text: String) {
        jumpNote = text
        noteTimer?.invalidate()
        let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.jumpNote = nil
        }
        RunLoop.main.add(timer, forMode: .common)
        noteTimer = timer
    }

    // MARK: - 藍牙控制

    /// 踏板、翻頁器、實體鍵盤按下去要做的事。
    func perform(_ action: RemoteAction) {
        guard hardwareEnabled, !hasWindow, !isMerging, let settings else { return }
        switch action {
        case .next:
            jump(forward: true)
        case .previous:
            jump(forward: false)
        case .playPause:
            guard settings.usesPrompter else { return }
            togglePrompter()
        case .toggleVoice:
            guard !currentIsPoint else { return }
            toggleVoiceFollow()
        case .toggleJumpMode:
            let next: JumpMode = settings.jumpMode == .paragraph ? .line : .paragraph
            settings.jumpMode = next
            showNote(next.label)
        case .record:
            hardwareButtonPressed()
        }
    }

    // MARK: - 語音跟隨

    /// 開關語音跟隨。還沒有權限就先問，沒給就維持關著。
    func toggleVoiceFollow() {
        guard let settings else { return }
        if settings.voiceFollow {
            setVoiceFollow(false)
            return
        }
        if SpeechFollower.isAuthorized {
            setVoiceFollow(true)
            return
        }
        guard !askingSpeech else { return }
        askingSpeech = true
        SpeechFollower.requestAuthorization { [weak self] granted in
            guard let self else { return }
            self.askingSpeech = false
            if granted {
                self.setVoiceFollow(true)
            } else {
                if self.settings?.voiceFollow == true { self.settings?.voiceFollow = false }
                self.showNote("沒有語音辨識權限")
            }
        }
    }

    private func setVoiceFollow(_ on: Bool) {
        settings?.voiceFollow = on
        applyVoiceFollowSetting()
        if on && phase == .recording && prompter.isPlaying && !prompter.isFollowing {
            showNote("語音辨識現在不能用")
        } else {
            showNote(on ? "語音跟隨 開" : "語音跟隨 關")
        }
    }

    /// 設定改了：錄影中立刻開始或停止跟隨。不在錄影就不用做什麼，開錄時會照設定。重複呼叫沒有關係。
    func applyVoiceFollowSetting() {
        guard phase == .recording, !currentIsPoint else { return }
        guard settings?.voiceFollow ?? false else {
            guard prompter.isFollowing else { return }
            // 改回固定速度，播放中的繼續播。
            heldByPause = false
            stopFollowing()
            return
        }
        guard !prompter.isFollowing else { return }
        // 停頓等人、自己捲到底停下來的，都算正在播；人按的暫停不算，按繼續時才會跟。
        guard prompter.isPlaying || heldByPause || prompter.stoppedAtEnd else { return }
        startFollowingIfWanted()
        guard prompter.isFollowing else { return }
        heldByPause = false
        prompter.play()
    }

    /// 設定有開、有授權、辨識可用，提詞就改成從目前讀到的位置跟著聲音走；任何一項不成立就維持固定速度。
    private func startFollowingIfWanted() {
        followSpeakingTicks = 0
        let text = currentText
        guard settings?.voiceFollow ?? false, !currentIsPoint, !text.isEmpty, let camera else { return }
        let here = prompter.readingOffset(in: text)
        guard follower.start(text: text, from: here) else {
            camera.log("語音跟隨無法啟動，使用固定速度")
            return
        }
        camera.audioSampleHandler = { [weak follower] buffer in
            follower?.append(buffer)
        }
        // 已經讀到結尾時 follower 會從頭開始，提詞跟著它。
        prompter.startFollowing(from: min(here, follower.currentOffset), in: text)
    }

    private func stopFollowing() {
        camera?.audioSampleHandler = nil
        follower.stop()
        prompter.stopFollowing()
    }

    private func fallBackToFixedSpeed() {
        heldByPause = false
        stopFollowing()
        showNote("改回固定速度")
    }

    private func recordingFailed(_ url: URL, _ reason: String) {
        if url.lastPathComponent == activeFile {
            activeFile = nil
            phase = .idle
            recordingError = reason
        }
        keepForLater(url)
    }

    /// 檔案還在就留著，下次開 App 再看能不能用。
    private func keepForLater(_ url: URL) {
        let file = url.lastPathComponent
        if let index = recordings.firstIndex(where: { $0.file == file }) {
            if FileManager.default.fileExists(atPath: url.path) {
                // 檔案還在只是現在打不開，下次開 App 再看一次。
                recordings[index].failed = true
            } else {
                recordings.remove(at: index)
            }
        }
        persist()
    }
}
