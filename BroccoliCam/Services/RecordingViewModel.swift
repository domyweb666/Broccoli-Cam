import Foundation
import Combine

struct RecordedVideo: Identifiable {
    let id = UUID()
    let url: URL
    /// 是否由多段接成。接成的影片在完成頁可以回去重錄其中一段。
    var isStitched = false
    /// 這支影片照著唸的稿子，產生字幕用。沒有稿子就是空字串。
    var script = ""
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

    @Published private(set) var phase: Phase = .idle
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

    let prompter = TeleprompterModel()
    private let follower = SpeechFollower()

    /// 稿件或設定頁開著的時候，不回應音量鍵。
    var hardwareEnabled = true

    private weak var camera: CameraService?
    private weak var settings: SettingsStore?
    private var cancellables = Set<AnyCancellable>()
    private var countdownTimer: Timer?
    private var elapsedTimer: Timer?
    private var startDate: Date?
    private var autoPrompt = false

    // 錄影中的聲音紀錄
    private var firstSound: Double?
    private var lastSound: Double?
    private var wasSpeaking = false
    private var heldByPause = false
    /// 語音跟隨開著的時候，累計「有在講話」的次數（每次 0.1 秒）。
    private var followSpeakingTicks = 0

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
        camera.onRecordingFinished = { [weak self] url in
            self?.recordingFinished(url)
        }
        camera.onRecordingFailed = { [weak self] in
            self?.recordingFailed()
        }
        camera.onCaptureButton = { [weak self] in
            self?.hardwareButtonPressed()
        }
        follower.onProgress = { [weak self] offset in
            guard let self else { return }
            self.prompter.follow(utf16Offset: offset, in: self.currentText)
        }
        follower.onLog = { [weak camera] message in
            camera?.log(message)
        }
        camera.$isRecording
            .removeDuplicates()
            .sink { [weak self] recording in
                self?.recordingChanged(recording)
            }
            .store(in: &cancellables)
    }

    // MARK: - 稿件

    /// 稿件內容變了就重新切段；分段不同時，已錄的各段作廢。
    func updateScript(_ script: String) {
        let next = ScriptSegments.split(script)
        guard next != segments else { return }
        discardAllTakes()
        segments = next
    }

    // MARK: - 錄影鈕

    /// 錄影鈕：待機 → 倒數／開始；倒數中 → 取消；錄影中 → 停止。
    func primaryTapped(countdown: Int, autoPrompt: Bool) {
        guard !isMerging, pending == nil else { return }
        switch phase {
        case .idle:
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
                autoPrompt: settings.autoStartPrompter && settings.hasScript
            )
        }
    }

    func togglePrompter() {
        heldByPause = false
        prompter.toggle()
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
                                                script: self.segments.joined(separator: "\n"))
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
        pending = nil
        currentIndex = 0
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
        camera?.startRecording()
        // 3 秒內沒有真的開始錄，就回到待機，不要卡住。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.phase == .starting else { return }
            self.camera?.log("錄影未在 3 秒內開始")
            self.phase = .idle
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
            startDate = Date()
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
                startFollowingIfWanted()
                prompter.play()
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
            if speaking { followSpeakingTicks += 1 }
            if followSpeakingTicks > 60 && follower.matchCount == 0 {
                camera?.log("語音跟隨沒有對上稿子，改回固定速度")
                stopFollowing()
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

    private func recordingFinished(_ url: URL) {
        phase = .idle
        if isSegmented {
            pending = SegmentTake(url: url, firstSound: firstSound, lastSound: lastSound)
        } else {
            review = RecordedVideo(url: url, script: segments.first ?? "")
        }
    }

    // MARK: - 語音跟隨

    /// 設定有開、有授權、辨識可用，提詞就改成跟著聲音走；任何一項不成立就維持固定速度。
    private func startFollowingIfWanted() {
        followSpeakingTicks = 0
        guard settings?.voiceFollow ?? false, let camera else { return }
        guard follower.start(text: currentText) else {
            camera.log("語音跟隨無法啟動，使用固定速度")
            return
        }
        camera.audioSampleHandler = { [weak follower] buffer in
            follower?.append(buffer)
        }
        prompter.setFollowing(true)
    }

    private func stopFollowing() {
        camera?.audioSampleHandler = nil
        follower.stop()
        prompter.setFollowing(false)
    }

    private func recordingFailed() {
        phase = .idle
    }
}
