import Foundation
import Speech
import AVFoundation

/// 語音跟隨提詞：邊錄邊辨識，找出現在唸到稿子的哪個字。
/// 只負責「唸到哪」，不存任何辨識文字。辨識不到就什麼都不做，由呼叫端退回固定速度。
/// 怎麼對位在 SpeechAligner，這裡只管辨識工作的開關。
final class SpeechFollower {
    static let locale = Locale(identifier: "zh-TW")

    /// 唸到的位置變了（主執行緒），往前或退回去重唸都會報。參數是「下一個要唸的字」在稿子裡的 UTF-16 位置。
    var onProgress: ((Int) -> Void)?
    /// 辨識一直開不起來，已經自己停掉了（主執行緒）。
    var onGaveUp: (() -> Void)?
    var onLog: ((String) -> Void)?

    /// 這次跟隨對上稿子的次數。一直是 0 代表辨識沒有作用。
    private(set) var matchCount = 0

    private let recognizer = SFSpeechRecognizer(locale: SpeechFollower.locale)
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let requestLock = NSLock()

    private var keys: [SpokenKeys.Key] = []
    /// 稿子全長（UTF-16），整篇唸完時回報這個位置。
    private var textLength = 0
    private var aligner = SpeechAligner(keys: [])
    private var active = false
    /// 提詞暫停中：不聽，位置留著。
    private var suspended = false
    private var generation = 0
    private var failures = 0
    private var taskStartedAt = Date()

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

    /// 下一個要唸的字在稿子裡的 UTF-16 位置。
    var currentOffset: Int {
        let position = aligner.position
        return keys.indices.contains(position) ? keys[position].utf16Offset : textLength
    }

    /// 從稿子的 utf16Offset 開始跟。那裡之後已經沒有字可以唸，就從頭。
    /// 回傳 false 代表沒辦法跟（沒授權、辨識不可用、稿子太短）。
    func start(text: String, from utf16Offset: Int = 0) -> Bool {
        stop()
        guard isAvailable else { return false }
        let all = SpokenKeys.keys(of: text)
        guard all.count >= 4 else { return false }
        keys = all
        textLength = text.utf16.count
        let first = index(atUTF16: utf16Offset)
        aligner = SpeechAligner(keys: all.map { $0.value }, position: first < all.count ? first : 0)
        matchCount = 0
        failures = 0
        suspended = false
        active = true
        beginTask()
        return true
    }

    func stop() {
        active = false
        suspended = false
        generation += 1
        endTask()
    }

    /// 跳到稿子的另一個位置接著聽。
    /// 換一個新的辨識工作：還在路上的舊結果是跳之前講的話，留著會把位置又帶回去。
    func seek(toUTF16 utf16Offset: Int) {
        guard active else { return }
        aligner.seek(to: index(atUTF16: utf16Offset))
        guard !suspended else { return }
        relisten()
    }

    /// 提詞暫停：先不聽。
    func suspend() {
        guard active, !suspended else { return }
        suspended = true
        generation += 1
        endTask()
    }

    /// 提詞繼續：從指定的位置接著聽。
    func resume(atUTF16 utf16Offset: Int) {
        guard active else { return }
        suspended = false
        seek(toUTF16: utf16Offset)
    }

    /// 錄影的音訊一包一包送進來。可在任何執行緒呼叫。
    func append(_ buffer: CMSampleBuffer) {
        requestLock.lock()
        let current = request
        requestLock.unlock()
        current?.appendAudioSampleBuffer(buffer)
    }

    /// 這個位置（含）之後第一個會唸出來的字，是第幾個音。
    private func index(atUTF16 utf16Offset: Int) -> Int {
        keys.firstIndex { $0.utf16Offset >= utf16Offset } ?? keys.count
    }

    // MARK: - 辨識工作

    private func beginTask() {
        guard active, !suspended, let recognizer else { return }
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
        taskStartedAt = Date()
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

    /// 丟掉現在的辨識，隔一下再開新的。連按跳轉鍵時只有最後一次會真的開。
    private func relisten() {
        generation += 1
        let mine = generation
        endTask()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.active, !self.suspended, self.generation == mine else { return }
            self.beginTask()
        }
    }

    private func handle(transcript: String?, ended: Bool, failed: Bool, generation mine: Int) {
        guard active, mine == generation else { return }
        if let transcript, !transcript.isEmpty {
            failures = 0
            advance(with: transcript)
            // 對上之後的回呼可能已經把跟隨關掉或跳走了。
            guard active, mine == generation else { return }
        }
        guard ended else { return }
        // 聽了一陣子才結束多半是沒人講話；一開就結束的才算開不起來。
        if failed && Date().timeIntervalSince(taskStartedAt) < 2 { failures += 1 }
        if failures > 3 {
            onLog?("語音跟隨連續失敗，停止辨識")
            stop()
            onGaveUp?()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.active, self.generation == mine else { return }
            self.restart()
        }
    }

    /// 只看最後一小段，講很久的時候不用每次整串重轉拼音。
    private func advance(with transcript: String) {
        let recent = String(transcript.suffix(40))
        let spoken = SpokenKeys.keys(of: recent).map { $0.value }
        switch aligner.hear(spoken) {
        case .none:
            return
        case .forward, .backward:
            matchCount += 1
            onProgress?(currentOffset)
        }
    }
}
