import Foundation
import Combine

struct RecordedVideo: Identifiable {
    let id = UUID()
    let url: URL
}

/// 錄影狀態與流程協調：倒數 → 錄影 → 完成頁。
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

    let prompter = TeleprompterModel()

    private weak var camera: CameraService?
    private var cancellables = Set<AnyCancellable>()
    private var countdownTimer: Timer?
    private var elapsedTimer: Timer?
    private var startDate: Date?
    private var autoPrompt = false

    var isBusy: Bool {
        phase != .idle
    }

    func attach(_ camera: CameraService) {
        guard self.camera == nil else { return }
        self.camera = camera
        camera.onRecordingFinished = { [weak self] url in
            self?.recordingFinished(url)
        }
        camera.onRecordingFailed = { [weak self] in
            self?.recordingFailed()
        }
        camera.$isRecording
            .removeDuplicates()
            .sink { [weak self] recording in
                self?.recordingChanged(recording)
            }
            .store(in: &cancellables)
    }

    /// 錄影鈕：待機 → 倒數／開始；倒數中 → 取消；錄影中 → 停止。
    func primaryTapped(countdown: Int, autoPrompt: Bool) {
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
            elapsedTimer?.invalidate()
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
            RunLoop.main.add(timer, forMode: .common)
            elapsedTimer = timer
            if autoPrompt {
                prompter.play()
            }
        } else {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
            startDate = nil
            prompter.pause()
            // 被系統中斷而停止時，等檔案回呼。
            if phase == .recording {
                phase = .finishing
            }
        }
    }

    private func recordingFinished(_ url: URL) {
        phase = .idle
        review = RecordedVideo(url: url)
    }

    private func recordingFailed() {
        phase = .idle
    }
}
