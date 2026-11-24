import Foundation
import Combine

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

/// 錄影狀態與流程協調：倒數 → 錄影 → （分段：留用或重錄 → 接片）→ 完成頁。
final class RecordingViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case countdown(Int)
        case starting
        case recording
        case finishing
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

    // 分段錄影
    @Published private(set) var segments: [String] = []
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
    private var declinedSegments: [String]?
    /// 跳轉、切換之後在畫面上閃一下的字，約 1.2 秒自己消失。
    @Published private(set) var jumpNote: String?
    /// 按下錄影那一刻介面轉的角度，錄影中不跟著手機晃動改變。
    @Published private(set) var lockedAngle: Double = 0

    /// 手機現在的擺法（0 直放、±90 橫放），由畫面隨時更新。
    var deviceAngle: Double = 0
    /// 已經錄好的段落是橫的還是直的。還沒有任何一段時是 nil。
    private var takesLandscape: Bool?

    let prompter = TeleprompterModel()
    private let follower = SpeechFollower()

    /// 稿件或設定頁開著的時候，不回應音量鍵。
    var hardwareEnabled = true

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
        segments.count > 1
    }

    /// 目前提詞要顯示的文字。
    var currentText: String {
        guard isSegmented, segments.indices.contains(currentIndex) else {
            return segments.first ?? ""
        }
        return segments[currentIndex]
    }

    var allRecorded: Bool {
        isSegmented && takes.count == segments.count
    }

    var currentHasTake: Bool {
        takes[currentIndex] != nil
    }

    func attach(_ camera: CameraService, settings: SettingsStore) {
        guard self.camera == nil else { return }
        self.camera = camera
        self.settings = settings
        camera.onRecordingFinished = { [weak self] url, note in
            self?.recordingFinished(url, damaged: note != nil)
        }
        camera.onRecordingFailed = { [weak self] reason in
            self?.recordingFailed(reason)
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
    }

    // MARK: - 稿件

    /// 稿件內容、分段開關變了就重新切段。切出來不同、又已經錄了幾段時先問（force 是已經問過了）。
    /// 錄影中先記著，回到待機再套。
    func updateScript(_ script: String, force: Bool = false) {
        guard split(script) != segments else {
            waitingScript = nil
            declinedSegments = nil
            return
        }
        waitingScript = script
        guard phase == .idle, !isMerging, review == nil else { return }
        if force || recordedCount == 0 {
            discardAllTakes()
            return
        }
        guard split(script) != declinedSegments else { return }
        scriptChange = ScriptChange(count: recordedCount)
    }

    /// 換稿：已錄的各段作廢。
    func acceptScriptChange() {
        scriptChange = nil
        discardAllTakes()
    }

    /// 保留已錄的：沿用原本的段落繼續錄，全部清掉之後才套新稿。
    func declineScriptChange() {
        scriptChange = nil
        declinedSegments = waitingScript.map { split($0) }
    }

    /// 有等著套用的新稿就再看一次能不能套。
    func reconsiderScript() {
        guard let waiting = waitingScript else { return }
        updateScript(waiting)
    }

    private func split(_ script: String) -> [String] {
        ScriptSegments.segments(of: script, segmented: settings?.segmentedRecording ?? true)
    }

    private var recordedCount: Int {
        takes.count + (pending == nil ? 0 : 1)
    }

    // MARK: - 錄影鈕

    /// 錄影鈕：待機 → 倒數／開始；倒數中 → 取消；錄影中 → 停止。
    func primaryTapped(countdown: Int, autoPrompt: Bool) {
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
            self.autoPrompt = autoPrompt
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
        guard hardwareEnabled, review == nil, !isMerging, let settings else { return }
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
        guard let take = pending else { return }
        if let old = takes[currentIndex] {
            try? FileManager.default.removeItem(at: old.url)
        }
        takes[currentIndex] = take
        takesLandscape = lockedAngle != 0
        pending = nil
        prompter.reset()
        if let next = (0..<segments.count).first(where: { takes[$0] == nil }) {
            currentIndex = next
        } else {
            mergeAll()
        }
    }

    /// 丟掉剛錄的這段，留在同一段準備重錄。
    func retakePending() {
        guard let take = pending else { return }
        try? FileManager.default.removeItem(at: take.url)
        pending = nil
        prompter.reset()
    }

    /// 切到前一段／後一段（要重錄某一段時用）。
    func step(_ delta: Int) {
        guard !isBusy, pending == nil, isSegmented else { return }
        let target = min(segments.count - 1, max(0, currentIndex + delta))
        guard target != currentIndex else { return }
        currentIndex = target
        prompter.reset()
    }

    /// 把各段照順序接成一支影片，完成後進完成頁。
    func mergeAll() {
        guard allRecorded, !isMerging, pending == nil else { return }
        let trim = settings?.trimSilence ?? true
        let clips: [VideoStitcher.Clip] = (0..<segments.count).compactMap { index in
            guard let take = takes[index] else { return nil }
            var start: Double?
            var end: Double?
            if trim, let first = take.firstSound, let last = take.lastSound {
                start = max(0, first - trimLead)
                end = last + trimTail
            }
            return VideoStitcher.Clip(url: take.url, start: start, end: end)
        }
        isMerging = true
        camera?.log("開始接片：\(clips.count) 段，裁靜音 \(trim ? "開" : "關")")
        Task {
            do {
                let url = try await VideoStitcher.stitch(clips)
                await MainActor.run {
                    self.isMerging = false
                    self.camera?.log("接片完成")
                    self.review = RecordedVideo(url: url, isStitched: true,
                                                script: self.segments.joined(separator: "\n"),
                                                isLandscape: self.takesLandscape ?? false)
                }
            } catch {
                await MainActor.run {
                    self.isMerging = false
                    self.mergeError = error.localizedDescription
                    self.camera?.log("接片失敗：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 丟掉所有已錄的段落，回到第一段。
    func discardAllTakes() {
        for take in takes.values {
            try? FileManager.default.removeItem(at: take.url)
        }
        if let take = pending {
            try? FileManager.default.removeItem(at: take.url)
        }
        takes = [:]
        takesLandscape = nil
        pending = nil
        currentIndex = 0
        if let waiting = waitingScript {
            waitingScript = nil
            declinedSegments = nil
            segments = split(waiting)
        }
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
        camera?.startRecording(landscape: lockedAngle != 0)
        // 3 秒內沒有真的開始錄，就回到待機，不要卡住。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.phase == .starting else { return }
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
        } else if settings?.waitOnPause ?? false {
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
        phase = .idle
        let notice: String? = damaged ? "結尾有一小段沒存到" : nil
        if isSegmented {
            pending = SegmentTake(url: url, firstSound: firstSound, lastSound: lastSound)
            recordingError = notice
        } else {
            review = RecordedVideo(url: url, script: segments.first ?? "", isLandscape: lockedAngle != 0,
                                   notice: notice)
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
        guard !text.isEmpty else { return }
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
        guard settings?.usesPrompter ?? false, !isMerging, phase != .finishing else { return }
        moveReading(to: utf16Offset)
    }

    private func jumpSegment(forward: Bool) {
        let target = currentIndex + (forward ? 1 : -1)
        guard segments.indices.contains(target) else {
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
        guard hardwareEnabled, review == nil, !isMerging, let settings else { return }
        switch action {
        case .next:
            jump(forward: true)
        case .previous:
            jump(forward: false)
        case .playPause:
            guard settings.usesPrompter else { return }
            togglePrompter()
        case .toggleVoice:
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
        guard phase == .recording else { return }
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
        guard settings?.voiceFollow ?? false, !text.isEmpty, let camera else { return }
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

    private func recordingFailed(_ reason: String) {
        phase = .idle
        recordingError = reason
    }
}
