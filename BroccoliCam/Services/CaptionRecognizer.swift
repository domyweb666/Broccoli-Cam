import AVFoundation
import Foundation
import Speech

struct CaptionRecognizerInfo {
    /// 給人看的名字，例如「裝置端」「連網」。
    let engine: String
    let onDevice: Bool
    /// 一次最多聽幾秒。nil 是不限。
    let maxSeconds: Double?
}

/// 把一段聲音變成有時間的字。之後要換引擎就再寫一個。
protocol CaptionRecognizing {
    var info: CaptionRecognizerInfo { get }
    /// 回傳的時間從 range 的開頭算起。沒聽成要丟錯，不可以回空的：空的會被當成沒人講話。
    func transcribe(asset: AVAsset, range: CMTimeRange) async throws -> [HeardWord]
}

enum CaptionRecognizerError: LocalizedError {
    /// 確定沒有人講話。
    case noSpeech
    /// 系統叫我們再試一次。多半是沒人講話，但也可能是沒辨識成。
    case maybeSilent
    /// 聽到一半斷掉，前面聽到的還能用。
    case partial([HeardWord], reason: String)
    case timedOut
    case cannotReadAudio(String)

    var errorDescription: String? {
        switch self {
        case .noSpeech, .maybeSilent: return "沒有聽到人聲。"
        case .partial(_, let reason): return reason
        case .timedOut: return "語音辨識等太久沒有回應。"
        case .cannotReadAudio(let reason): return reason
        }
    }
}

/// 系統的語音辨識（SFSpeechRecognizer）。能在裝置端做就在裝置端做。
final class SystemCaptionRecognizer: CaptionRecognizing {
    let info: CaptionRecognizerInfo
    private let recognizer: SFSpeechRecognizer

    /// 這支手機現在不能辨識中文就是 nil。
    init?() {
        guard let recognizer = SFSpeechRecognizer(locale: SpeechFollower.locale), recognizer.isAvailable else {
            return nil
        }
        self.recognizer = recognizer
        let onDevice = recognizer.supportsOnDeviceRecognition
        // 連網辨識一次大約只吃一分鐘，裝置端沒有這個限制。
        info = CaptionRecognizerInfo(engine: onDevice ? "裝置端" : "連網", onDevice: onDevice,
                                     maxSeconds: onDevice ? nil : 50)
    }

    /// 這支手機做字幕要不要把聲音送出去。
    static var needsNetwork: Bool {
        !(SFSpeechRecognizer(locale: SpeechFollower.locale)?.supportsOnDeviceRecognition ?? false)
    }

    func transcribe(asset: AVAsset, range: CMTimeRange) async throws -> [HeardWord] {
        let audio = try await Self.exportAudio(asset, range: range)
        defer { try? FileManager.default.removeItem(at: audio) }
        try Task.checkCancellation()

        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        request.taskHint = .dictation
        if info.onDevice {
            request.requiresOnDeviceRecognition = true
        }
        let recognizer = self.recognizer
        let collector = Collector()
        // 沒有網路時偶爾兩邊都不回，不能讓使用者一直等。
        let patience = 60 + range.duration.seconds * (info.onDevice ? 2 : 1)
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(patience * 1_000_000_000))
            guard !Task.isCancelled else { return }
            collector.stop(because: CaptionRecognizerError.timedOut)
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HeardWord], Error>) in
                collector.start(continuation) {
                    recognizer.recognitionTask(with: request) { result, error in
                        collector.handle(result, error)
                    }
                }
            }
        } onCancel: {
            collector.stop(because: CancellationError())
        }
    }

    /// AVAssetExportSession 要能從取消的那個執行緒叫停。
    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    /// 把影片的一段聲音抽成 m4a，辨識只吃聲音檔。
    private static func exportAudio(_ asset: AVAsset, range: CMTimeRange) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CaptionRecognizerError.cannotReadAudio("無法抽出聲音")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("broccoli-audio-\(UUID().uuidString).m4a")
        session.outputURL = url
        session.outputFileType = .m4a
        session.timeRange = range
        let box = SessionBox(session)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                box.session.exportAsynchronously {
                    continuation.resume()
                }
            }
        } onCancel: {
            box.session.cancelExport()
        }
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            try Task.checkCancellation()
            throw CaptionRecognizerError.cannotReadAudio(session.error?.localizedDescription ?? "無法抽出聲音")
        }
        return url
    }

    /// 收集辨識結果。回呼可能來很多次，也可能在不同執行緒，所以用鎖，而且只回報一次。
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var words: [HeardWord] = []
        private var finished = false
        private var continuation: CheckedContinuation<[HeardWord], Error>?
        private var task: SFSpeechRecognitionTask?

        func start(_ continuation: CheckedContinuation<[HeardWord], Error>, begin: () -> SFSpeechRecognitionTask) {
            lock.lock()
            if finished {
                // 還沒開始就被取消了。
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()

            let created = begin()
            lock.lock()
            let late = finished
            if !late { task = created }
            lock.unlock()
            if late { created.cancel() }
        }

        func handle(_ result: SFSpeechRecognitionResult?, _ error: Error?) {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            if let result { merge(result) }
            let heard = words
            let isFinal = result?.isFinal ?? false
            lock.unlock()

            if isFinal {
                finish(.success(heard), cancels: false)
            } else if let error {
                finish(Self.outcome(of: error, heard: heard), cancels: false)
            }
        }

        func stop(because error: Error) {
            lock.lock()
            let heard = words
            lock.unlock()
            if error is CancellationError {
                finish(.failure(error), cancels: true)
            } else {
                finish(Self.outcome(of: error, heard: heard), cancels: true)
            }
        }

        private func finish(_ outcome: Swift.Result<[HeardWord], Error>, cancels: Bool) {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            let waiting = continuation
            let running = task
            continuation = nil
            task = nil
            lock.unlock()
            if cancels { running?.cancel() }
            waiting?.resume(with: outcome)
        }

        private func merge(_ result: SFSpeechRecognitionResult) {
            let segments: [HeardWord] = result.bestTranscription.segments.map { segment in
                let word = CaptionWord(text: segment.substring, start: segment.timestamp,
                                       end: segment.timestamp + segment.duration)
                // 還沒定稿的結果信心都是 0，當作沒給。
                let confidence = Double(segment.confidence)
                return HeardWord(word: word, confidence: confidence > 0 ? confidence : nil)
            }
            let timed = segments.contains { $0.word.end > 0 }
            if timed, let first = segments.first {
                // 新的結果可能只含後半段（長錄音會一句一句定稿），所以只蓋掉時間重疊的部分。
                words.removeAll { $0.word.start >= first.word.start - 0.05 }
                words.append(contentsOf: segments)
            } else if result.isFinal, words.isEmpty {
                words = segments
            }
        }

        /// 「沒有聽到人聲」不算錯；聽到一半斷掉要講清楚斷在哪，不能當成全部聽完了。
        private static func outcome(of error: Error, heard: [HeardWord]) -> Swift.Result<[HeardWord], Error> {
            let nsError = error as NSError
            let isAssistant = nsError.domain == "kAFAssistantErrorDomain"
            if isAssistant, nsError.code == 1110 {
                return heard.isEmpty ? .failure(CaptionRecognizerError.noSpeech) : .success(heard)
            }
            if !heard.isEmpty {
                return .failure(CaptionRecognizerError.partial(heard, reason: error.localizedDescription))
            }
            if isAssistant, nsError.code == 203 {
                return .failure(CaptionRecognizerError.maybeSilent)
            }
            return .failure(error)
        }
    }
}

#if targetEnvironment(simulator)
/// 測試用：模擬器沒有中文辨識，照稿子編出聽到的字和時間。
/// UserDefaults 的 debugFakeCaptions 寫情境，用逗號隔開：normal、missing（漏第二句）、extra（第一句後面多講）、
/// repeat（第一句講兩次）、misheard（最後一句一半聽錯）、fail（後半辨識失敗）、silent（什麼都沒聽到）、
/// offline（沒有網路）、unavailable（不能辨識）、timeout（整支等不到回應）、mixed（漏、多、重講、聽錯一次來）、
/// number（第一個數字講成別的）、negate（拿掉或加上一個「不」）。
struct FakeCaptionRecognizer: CaptionRecognizing {
    static var scenario: Set<String>? {
        guard let text = UserDefaults.standard.string(forKey: "debugFakeCaptions"), !text.isEmpty else { return nil }
        var names = Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        if names.contains("mixed") { names.formUnion(["missing", "extra", "repeat", "misheard"]) }
        return names
    }

    let info: CaptionRecognizerInfo
    private let words: [CaptionWord]
    private let start: Double
    private let fails: Bool
    private let neverAnswers: Bool

    /// start 是這一段在影片檔裡的起點，duration 是長度。
    init(script: String, start: Double, duration: Double, scenario: Set<String>) {
        self.start = start
        fails = scenario.contains("fail")
        neverAnswers = scenario.contains("timeout")
        info = CaptionRecognizerInfo(engine: "假辨識", onDevice: true,
                                     maxSeconds: fails ? max(2, duration * 0.6) : nil)
        words = scenario.contains("silent") ? [] : Self.speak(script, duration: duration, scenario: scenario)
    }

    func transcribe(asset: AVAsset, range: CMTimeRange) async throws -> [HeardWord] {
        // 看得到進度條、來得及按取消。
        try await Task.sleep(nanoseconds: 1_200_000_000)
        if neverAnswers { throw CaptionRecognizerError.timedOut }
        let lower = range.start.seconds - start
        let upper = lower + range.duration.seconds
        if fails, lower > 0.05 || range.duration.seconds < 1.9 { throw CaptionRecognizerError.timedOut }
        let here = words.filter { $0.start >= lower && $0.start < upper }
        if here.isEmpty { throw CaptionRecognizerError.noSpeech }
        return here.map {
            HeardWord(word: CaptionWord(text: $0.text, start: $0.start - lower, end: $0.end - lower), confidence: 0.8)
        }
    }

    private static func speak(_ script: String, duration: Double, scenario: Set<String>) -> [CaptionWord] {
        let source = SpokenKeys.keys(of: script).isEmpty ? "這支影片沒有稿子。我是直接想到什麼就講什麼。" : script
        var sentences = CaptionBreaker.sentences(CaptionBreaker.glyphs(of: source))
            .map { String($0.map { $0.character }) }
        if scenario.contains("number") { sentences = changingNumber(sentences) }
        if scenario.contains("negate") { sentences = negating(sentences) }
        if scenario.contains("misheard"), let last = sentences.last {
            var wrong = ""
            for (index, character) in last.enumerated() {
                wrong.append(index % 2 == 1 ? Character("喔") : character)
            }
            sentences[sentences.count - 1] = wrong
        }
        if scenario.contains("missing"), sentences.count > 1 {
            sentences.remove(at: 1)
        }
        if let first = sentences.first {
            if scenario.contains("extra") { sentences.insert("對了先幫我按個訂閱", at: 1) }
            if scenario.contains("repeat") { sentences.insert(first, at: 0) }
        }

        let total = sentences.reduce(0) { $0 + SpokenKeys.keys(of: $1).count }
        let room = max(0.2, duration - 0.4 - 0.4 * Double(sentences.count))
        let pace = min(0.22, room / Double(max(1, total)))
        var result: [CaptionWord] = []
        var time = 0.2
        for sentence in sentences {
            for piece in pieces(sentence) {
                let length = pace * Double(SpokenKeys.keys(of: piece).count)
                result.append(CaptionWord(text: piece, start: time, end: time + length))
                time += length
            }
            time += min(0.4, duration * 0.05)
        }
        return result
    }

    /// 中文一個字一個詞，連著的英數算一個詞（30%、1,000），和真的辨識一樣。
    private static func pieces(_ sentence: String) -> [String] {
        let characters = Array(sentence)
        var result: [String] = []
        var canJoin = false
        for (index, character) in characters.enumerated() {
            if SpokenKeys.key(for: character) != nil {
                if canJoin, character.isASCII, !result.isEmpty {
                    result[result.count - 1].append(character)
                } else {
                    result.append(String(character))
                }
                canJoin = character.isASCII
                continue
            }
            let isNextDigit = index + 1 < characters.count && characters[index + 1].isASCII
                && characters[index + 1].isNumber
            if canJoin, !result.isEmpty, character == "%" {
                result[result.count - 1].append(character)
                canJoin = false
            } else if canJoin, !result.isEmpty, isNextDigit, [".", ",", ":"].contains(character) {
                result[result.count - 1].append(character)
            } else {
                canJoin = false
            }
        }
        return result
    }

    /// 第一個數字換成別的值，寫法不變。
    private static func changingNumber(_ sentences: [String]) -> [String] {
        let chinese: [Character] = ["一", "二", "三", "四", "五", "六", "七", "八", "九"]
        var result = sentences
        for (index, sentence) in sentences.enumerated() {
            guard let number = SpokenNumbers.values(in: sentence).first(where: { !$0.isWeak }) else { continue }
            var changed = ""
            var isDone = false
            for character in number.text {
                if isDone {
                    changed.append(character)
                } else if character.isASCII, let digit = character.wholeNumberValue {
                    changed.append(String(digit % 9 + 1))
                    isDone = true
                } else if character == "兩" {
                    changed.append("三")
                    isDone = true
                } else if let place = chinese.firstIndex(of: character) {
                    changed.append(chinese[(place + 1) % chinese.count])
                    isDone = true
                } else {
                    changed.append(character)
                }
            }
            // 只有一個「十」。
            if !isDone { changed = "二" + number.text }
            let range = NSRange(location: number.range.lowerBound, length: number.range.count)
            result[index] = (sentence as NSString).replacingCharacters(in: range, with: changed)
            return result
        }
        return result
    }

    /// 有「不」就拿掉第一個，沒有就在第一句的第二個字後面加一個。
    private static func negating(_ sentences: [String]) -> [String] {
        var result = sentences
        for (index, sentence) in sentences.enumerated() {
            var characters = Array(sentence)
            for place in characters.indices where place > 0 && characters[place] == "不" {
                guard place + 1 < characters.count, SpokenKeys.key(for: characters[place - 1]) != nil,
                      SpokenKeys.key(for: characters[place + 1]) != nil,
                      CaptionDoubtFinder.isNegation(characters, place) else { continue }
                characters.remove(at: place)
                result[index] = String(characters)
                return result
            }
        }
        for (index, sentence) in sentences.enumerated() {
            var characters = Array(sentence)
            guard characters.count >= 4, characters[..<4].allSatisfy({ SpokenKeys.key(for: $0) != nil }) else { continue }
            characters.insert("不", at: 2)
            result[index] = String(characters)
            return result
        }
        return result
    }
}
#endif
