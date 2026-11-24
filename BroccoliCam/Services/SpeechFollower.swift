import Foundation
import Speech
import AVFoundation

/// 語音跟隨提詞：邊錄邊辨識，找出現在唸到稿子的哪個字。
/// 只負責「唸到哪」，不存任何辨識文字。辨識不到就什麼都不做，由呼叫端退回固定速度。
final class SpeechFollower {
    static let locale = Locale(identifier: "zh-TW")

    /// 唸到的位置往前了（主執行緒）。參數是「下一個要唸的字」在稿子裡的 UTF-16 位置。
    var onProgress: ((Int) -> Void)?
    var onLog: ((String) -> Void)?

    /// 這次錄影對上稿子的次數。一直是 0 代表辨識沒有作用。
    private(set) var matchCount = 0

    private let recognizer = SFSpeechRecognizer(locale: SpeechFollower.locale)
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let requestLock = NSLock()

    private var keys: [SpokenKeys.Key] = []
    /// 稿子全長（UTF-16），整篇唸完時回報這個位置。
    private var textLength = 0
    /// 下一個要唸的字在 keys 裡的位置。
    private var position = 0
    private var active = false
    private var generation = 0
    private var failures = 0

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// 還沒問過權限。
    static var isUndetermined: Bool {
        SFSpeechRecognizer.authorizationStatus() == .notDetermined
    }

    static func requestAuthorization(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                done(status == .authorized)
            }
        }
    }

    /// 辨識用不用得了（有授權、這個語言目前可用）。
    var isAvailable: Bool {
        Self.isAuthorized && (recognizer?.isAvailable ?? false)
    }

    /// 開始跟隨這段稿子。回傳 false 代表沒辦法跟（沒授權、辨識不可用、稿子太短）。
    func start(text: String) -> Bool {
        stop()
        guard isAvailable else { return false }
        let all = SpokenKeys.keys(of: text)
        guard all.count >= 4 else { return false }
        keys = all
        textLength = text.utf16.count
        position = 0
        matchCount = 0
        failures = 0
        active = true
        beginTask()
        return true
    }

    func stop() {
        active = false
        generation += 1
        endTask()
    }

    /// 錄影的音訊一包一包送進來。可在任何執行緒呼叫。
    func append(_ buffer: CMSampleBuffer) {
        requestLock.lock()
        let current = request
        requestLock.unlock()
        current?.appendAudioSampleBuffer(buffer)
    }

    // MARK: - 辨識工作

    private func beginTask() {
        guard active, let recognizer else { return }
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        next.taskHint = .dictation
        next.addsPunctuation = false
        let onDevice = recognizer.supportsOnDeviceRecognition
        if onDevice {
            next.requiresOnDeviceRecognition = true
        }
        requestLock.lock()
        request = next
        requestLock.unlock()

        generation += 1
        let mine = generation
        task = recognizer.recognitionTask(with: next) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let ended = error != nil || (result?.isFinal ?? false)
            let failed = error != nil
            DispatchQueue.main.async {
                self?.handle(transcript: transcript, ended: ended, failed: failed, generation: mine)
            }
        }
        if matchCount == 0 && failures == 0 {
            onLog?("語音跟隨開始（\(onDevice ? "裝置端" : "連網")辨識）")
        }
        // 連網辨識一次大約只能聽一分鐘，到時間前先換一個新的。
        if !onDevice {
            DispatchQueue.main.asyncAfter(deadline: .now() + 50) { [weak self] in
                guard let self, self.active, self.generation == mine else { return }
                self.restart()
            }
        }
    }

    private func endTask() {
        requestLock.lock()
        let current = request
        request = nil
        requestLock.unlock()
        current?.endAudio()
        task?.cancel()
        task = nil
    }

    private func restart() {
        endTask()
        beginTask()
    }

    private func handle(transcript: String?, ended: Bool, failed: Bool, generation mine: Int) {
        guard active, mine == generation else { return }
        if let transcript, !transcript.isEmpty {
            failures = 0
            advance(with: transcript)
        }
        guard ended else { return }
        if failed { failures += 1 }
        if failures > 3 {
            onLog?("語音跟隨連續失敗，停止辨識")
            stop()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.active, self.generation == mine else { return }
            self.restart()
        }
    }

    // MARK: - 對位

    /// 拿辨識結果最後幾個字，在稿子目前位置附近找最像的地方。只往前，不倒退。
    private func advance(with transcript: String) {
        let spoken = SpokenKeys.keys(of: transcript).map { $0.value }
        let tail = Array(spoken.suffix(8))
        guard tail.count >= 2, !keys.isEmpty else { return }

        let lower = max(0, position - 3)
        let upper = min(keys.count - 1, position + 35)
        guard lower <= upper else { return }

        var bestEnd = -1
        var bestScore = 0
        var bestDistance = Int.max
        for end in lower...upper {
            var score = 0
            for back in 0..<tail.count {
                let index = end - back
                if index < 0 { break }
                if keys[index].value == tail[tail.count - 1 - back] {
                    score += 1
                }
            }
            let distance = abs(end + 1 - position)
            if score > bestScore || (score == bestScore && distance < bestDistance) {
                bestScore = score
                bestEnd = end
                bestDistance = distance
            }
        }
        guard bestEnd >= 0 else { return }

        let next = bestEnd + 1
        guard next > position else { return }
        let jump = next - position
        // 跳得越遠，要對上越多字才算數，避免稿子裡重複的詞把位置帶走。
        let needed: Int
        if tail.count < 3 {
            needed = tail.count
            guard jump <= 4 else { return }
        } else if jump > 15 {
            needed = 5
        } else {
            needed = 3
        }
        guard bestScore >= min(needed, tail.count) else { return }

        position = next
        matchCount += 1
        onProgress?(position < keys.count ? keys[position].utf16Offset : textLength)
    }
}
