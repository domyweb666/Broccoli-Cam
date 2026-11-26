import Foundation
import Speech
import AVFoundation

/// 語音跟隨提詞：邊錄邊辨識，找出現在唸到稿子的哪個字。
/// 只負責「唸到哪」，不存任何辨識文字。辨識不到就什麼都不做，由呼叫端退回固定速度。
/// 怎麼對位在 SpeechAligner，這裡只管辨識工作的開關。
final class SpeechFollower {
    static let locale = Locale(identifier: "zh-TW")

    /// 畫面上唸到的位置變了（主執行緒），往前、退回去重唸、先走一步、先走的收回來都會報。
    /// 參數是「下一個要唸的字」在稿子裡的 UTF-16 位置。
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
    /// 辨識結果晚到，畫面先照語速走一步，見 SpeechLead。
    private var lead = SpeechLead(stops: [], position: 0, rate: 220 / 60)
    /// 量到的語速，下一次開始跟的時候先用這個。
    private var learnedRate: Double?
    /// 最後一次報給畫面的位置（UTF-16），可能比 currentOffset 多走一點。
    private(set) var shownOffset = 0

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// 還沒問過權限。
    static var isUndetermined: Bool {
        SFSpeechRecognizer.authorizationStatus() == .notDetermined
    }

    /// 除錯紀錄用。
    static var authorizationText: String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return "已授權"
        case .denied: return "拒絕"
        case .restricted: return "受限"
        case .notDetermined: return "沒問過"
        @unknown default: return "不明"
        }
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
        offset(ofKey: aligner.position)
    }

    /// 從稿子的 utf16Offset 開始跟。那裡之後已經沒有字可以唸，就從頭。
    /// charsPerMinute 是設定裡的語速，還沒量到這個人講多快之前先用它。
    /// 回傳 false 代表沒辦法跟（沒授權、辨識不可用、稿子太短）。
    func start(text: String, from utf16Offset: Int = 0, charsPerMinute: Double = 220) -> Bool {
        stop()
        guard isAvailable else { return false }
        // 換稿時多半已經在背景算好了，沒算好才當下算。
        let prepared = SpokenScriptCache.shared.entry(for: text)
        let all = prepared.keys
        guard all.count >= 4 else { return false }
        keys = all
        textLength = text.utf16.count
        let first = index(atUTF16: utf16Offset)
        let position = first < all.count ? first : 0
        aligner = SpeechAligner(keys: all.map { $0.value }, position: position)
        lead = SpeechLead(stops: prepared.stops, position: position,
                          rate: learnedRate ?? charsPerMinute / 60)
        shownOffset = currentOffset
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
        if let rate = lead.measuredRate { learnedRate = rate }
        resetLead()
    }

    /// 跳到稿子的另一個位置接著聽。
    /// 換一個新的辨識工作：還在路上的舊結果是跳之前講的話，留著會把位置又帶回去。
    func seek(toUTF16 utf16Offset: Int) {
        guard active else { return }
        aligner.seek(to: index(atUTF16: utf16Offset))
        resetLead()
        guard !suspended else { return }
        relisten()
    }

    /// 提詞暫停：先不聽。
    func suspend() {
        guard active, !suspended else { return }
        suspended = true
        generation += 1
        endTask()
        // 先走的部分不報給畫面，要收回來由呼叫端決定（回開頭時畫面已經自己歸零了）。
        resetLead()
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

    /// 錄影中每 0.1 秒：講話中辨識結果還沒到，畫面照語速先往前走一點；停下來太久就收回來。
    /// speaking 是說話偵測（停一下下還算在講），voiced 是這一下真的有出聲。只動畫面，不動對位。
    func tick(speaking: Bool, voiced: Bool) {
        guard active, !suspended else { return }
        lead.tick(now: ProcessInfo.processInfo.systemUptime, speaking: speaking, voiced: voiced)
        report()
    }

    /// 第 index 個音在稿子裡的位置，唸完了是全長。
    private func offset(ofKey index: Int) -> Int {
        keys.indices.contains(index) ? keys[index].utf16Offset : textLength
    }

    /// 畫面該顯示到哪，和上次報的不一樣才報。
    private func report() {
        var target = offset(ofKey: lead.shown)
        if let edge = lead.stopOffset { target = min(target, edge) }
        guard target != shownOffset else { return }
        shownOffset = target
        onProgress?(target)
    }

    /// 位置換了：先走的全部重來，畫面另外由呼叫端處理，這裡不報。
    private func resetLead() {
        lead.reset(to: aligner.position)
        shownOffset = currentOffset
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
            // 裝置端辨識整段不換新，講越久整串越長。比對只看最後 40 個字（advance），
            // 在這裡就先切好，不要每次都把整串搬到主執行緒。
            let transcript = result.map { String($0.bestTranscription.formattedString.suffix(SpeechFollower.tailLength)) }
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
        let quick = Date().timeIntervalSince(taskStartedAt) < 2
        if failed && quick { failures += 1 }
        if failures > 3 {
            onLog?("語音跟隨連續失敗，停止辨識")
            stop()
            onGaveUp?()
            return
        }
        // 正常結束的馬上接著聽，隔一下的空檔裡剛開口的字會漏掉；一開就結束的才隔一下再試，免得一直空轉。
        DispatchQueue.main.asyncAfter(deadline: .now() + (quick ? 0.2 : 0)) { [weak self] in
            guard let self, self.active, self.generation == mine else { return }
            self.restart()
        }
    }

    /// 比對只看辨識結果的最後幾個字。
    private static let tailLength = 40

    /// 只看最後一小段，講很久的時候不用每次整串重轉拼音。
    private func advance(with transcript: String) {
        let recent = String(transcript.suffix(Self.tailLength))
        let spoken = SpokenKeys.keys(of: recent).map { $0.value }
        switch aligner.hear(spoken) {
        case .none:
            return
        case .forward:
            matchCount += 1
            lead.confirmForward(to: aligner.position)
        case .backward:
            matchCount += 1
            lead.confirmBackward(to: aligner.position)
        }
        report()
    }
}
