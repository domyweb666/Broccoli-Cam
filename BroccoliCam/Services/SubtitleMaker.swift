import Foundation
import Speech
import AVFoundation

enum SubtitleError: LocalizedError {
    case notAuthorized
    case unavailable
    case noAudio
    case nothingToWrite
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "沒有語音辨識的權限。請到「設定 → 花椰菜相機」打開「語音辨識」。"
        case .unavailable:
            return "這支手機目前不能辨識中文。請確認有連上網路，或到「設定 → 一般 → 鍵盤」打開「啟用聽寫」。"
        case .noAudio:
            return "這支影片沒有聲音，沒辦法對字幕。"
        case .nothingToWrite:
            return "沒有稿子，也沒有辨識到任何內容，產生不了字幕。"
        case .failed(let reason):
            return "字幕沒有做成功：\(reason)"
        }
    }
}

/// 用稿子幫影片做字幕檔。
/// 字用稿子裡的，語音辨識只負責找出「哪個字在第幾秒」，所以辨識認錯字也不會跑進字幕。
enum SubtitleMaker {
    /// 辨識出來的一個音，以及它在影片裡的時間。
    private struct TimedKey {
        let value: String
        let start: Double
        let end: Double
    }

    private struct Word {
        let text: String
        let start: Double
        let duration: Double
    }

    struct Result {
        let url: URL
        let cueCount: Int
        /// 稿子裡有多少比例的字，在聲音裡找到了對應的時間。
        let coverage: Double
        /// 這次有沒有真的做語音辨識。沒有的話，時間是照字數平均排的。
        let recognized: Bool
    }

    static func make(videoURL: URL, script: String, maxChars: Int,
                     log: @escaping (String) -> Void) async throws -> Result {
        guard await authorize() else { throw SubtitleError.notAuthorized }
        let scriptIsEmpty = script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 這支手機現在不能辨識中文：有稿子就照字數平均排時間，還是給得出字幕檔；沒稿子就真的做不了。
        var recognizer = SFSpeechRecognizer(locale: SpeechFollower.locale)
        if !(recognizer?.isAvailable ?? false) {
            recognizer = nil
        }
        if recognizer == nil && scriptIsEmpty {
            throw SubtitleError.unavailable
        }

        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty, duration > 0 else {
            throw SubtitleError.noAudio
        }

        // 連網辨識一次大約只吃一分鐘，切成小段；裝置端辨識沒有這個限制。
        let onDevice = recognizer?.supportsOnDeviceRecognition ?? false
        let chunkLength = onDevice ? max(duration, 1) : 50
        var words: [Word] = []
        var cursor = 0.0
        var lastError: Error?
        while let recognizer, cursor < duration - 0.05 {
            let length = min(chunkLength, duration - cursor)
            do {
                let audio = try await exportAudio(asset, start: cursor, length: length)
                defer { try? FileManager.default.removeItem(at: audio) }
                let found = try await recognize(audio, recognizer: recognizer, onDevice: onDevice)
                for word in found {
                    words.append(Word(text: word.text, start: word.start + cursor, duration: word.duration))
                }
            } catch {
                lastError = error
            }
            cursor += length
        }
        if recognizer == nil {
            log("字幕：語音辨識不可用，照字數平均排時間")
        } else {
            log("字幕辨識：\(onDevice ? "裝置端" : "連網")，\(words.count) 個詞")
        }

        let heard = timedKeys(from: words)
        let lines = SubtitleLines.split(script, maxChars: maxChars)
        let scriptKeys = lines.map { SpokenKeys.keys(of: $0).map { $0.value } }
        let hasScript = scriptKeys.contains { !$0.isEmpty }

        var cues: [SubtitleCue]
        var coverage = 0.0
        if hasScript {
            let aligned = align(lines: lines, lineKeys: scriptKeys, heard: heard, duration: duration)
            cues = aligned.0
            coverage = aligned.1
        } else if !words.isEmpty {
            cues = cuesFromWords(words, maxChars: maxChars)
            coverage = 1
        } else if let lastError {
            throw SubtitleError.failed(lastError.localizedDescription)
        } else {
            throw SubtitleError.nothingToWrite
        }
        tidy(&cues, duration: duration)
        guard !cues.isEmpty else { throw SubtitleError.nothingToWrite }
        log(String(format: "字幕 %d 句，對上 %.0f%%", cues.count, coverage * 100))

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "花椰菜相機字幕-\(formatter.string(from: Date())).srt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try SubtitleLines.srt(cues).write(to: url, atomically: true, encoding: .utf8)
        return Result(url: url, cueCount: cues.count, coverage: coverage, recognized: recognizer != nil)
    }

    // MARK: - 辨識

    private static func authorize() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// 把影片的一段聲音抽成 m4a，辨識只吃聲音檔。
    private static func exportAudio(_ asset: AVAsset, start: Double, length: Double) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw SubtitleError.failed("無法抽出聲音")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("broccoli-audio-\(UUID().uuidString).m4a")
        session.outputURL = url
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: length, preferredTimescale: 600)
        )
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw SubtitleError.failed(session.error?.localizedDescription ?? "無法抽出聲音")
        }
        return url
    }

    /// 收集辨識結果。回呼可能來很多次，也可能在不同執行緒，所以用鎖，而且只回報一次。
    private final class Collector {
        private let lock = NSLock()
        private var words: [Word] = []
        private var finished = false
        var task: SFSpeechRecognitionTask?

        func handle(_ result: SFSpeechRecognitionResult?, _ error: Error?,
                    _ continuation: CheckedContinuation<[Word], Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }

            if let result {
                let segments = result.bestTranscription.segments.map {
                    Word(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                }
                let timed = segments.contains { $0.start > 0 || $0.duration > 0 }
                if timed, let first = segments.first {
                    // 新的結果可能只含後半段（長錄音會一句一句定稿），所以只蓋掉時間重疊的部分。
                    words.removeAll { $0.start >= first.start - 0.05 }
                    words.append(contentsOf: segments)
                } else if result.isFinal, words.isEmpty {
                    words = segments
                }
                if result.isFinal {
                    finished = true
                    continuation.resume(returning: words)
                    return
                }
            }
            if let error {
                finished = true
                if words.isEmpty, !Self.isNoSpeech(error) {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: words)
                }
            }
        }

        /// 「沒有聽到人聲」不算錯，當成這一段沒有字。
        private static func isNoSpeech(_ error: Error) -> Bool {
            let nsError = error as NSError
            return nsError.domain == "kAFAssistantErrorDomain" && (nsError.code == 1110 || nsError.code == 203)
        }
    }

    private static func recognize(_ url: URL, recognizer: SFSpeechRecognizer, onDevice: Bool) async throws -> [Word] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        request.taskHint = .dictation
        if onDevice {
            request.requiresOnDeviceRecognition = true
        }
        let collector = Collector()
        return try await withCheckedThrowingContinuation { continuation in
            collector.task = recognizer.recognitionTask(with: request) { result, error in
                collector.handle(result, error, continuation)
            }
        }
    }

    /// 辨識出來的每個詞拆成一個一個音，時間平均分給詞裡的每個字。
    private static func timedKeys(from words: [Word]) -> [TimedKey] {
        var result: [TimedKey] = []
        for word in words.sorted(by: { $0.start < $1.start }) {
            let keys = SpokenKeys.keys(of: word.text)
            guard !keys.isEmpty else { continue }
            let total = word.duration > 0 ? word.duration : 0.22 * Double(keys.count)
            let each = total / Double(keys.count)
            for (index, key) in keys.enumerated() {
                let start = word.start + each * Double(index)
                result.append(TimedKey(value: key.value, start: start, end: start + each))
            }
        }
        return result
    }

    // MARK: - 稿子對時間

    /// 稿子的每個字去對辨識出來的音（最長共同子序列），對上的字拿到時間，沒對上的用前後的字內插。
    private static func align(lines: [String], lineKeys: [[String]], heard: [TimedKey],
                              duration: Double) -> ([SubtitleCue], Double) {
        let script = lineKeys.flatMap { $0 }
        let n = script.count
        let m = heard.count
        var starts = [Double?](repeating: nil, count: n)
        var ends = [Double?](repeating: nil, count: n)
        var matched = 0

        if n > 0, m > 0, n * m <= 12_000_000 {
            // direction：0 = 斜的（對上），1 = 往上，2 = 往左
            var direction = [UInt8](repeating: 0, count: n * m)
            var previous = [Int32](repeating: 0, count: m + 1)
            var current = [Int32](repeating: 0, count: m + 1)
            for i in 1...n {
                current[0] = 0
                let key = script[i - 1]
                for j in 1...m {
                    if key == heard[j - 1].value {
                        current[j] = previous[j - 1] + 1
                        direction[(i - 1) * m + (j - 1)] = 0
                    } else if previous[j] >= current[j - 1] {
                        current[j] = previous[j]
                        direction[(i - 1) * m + (j - 1)] = 1
                    } else {
                        current[j] = current[j - 1]
                        direction[(i - 1) * m + (j - 1)] = 2
                    }
                }
                swap(&previous, &current)
            }
            var i = n
            var j = m
            while i > 0 && j > 0 {
                switch direction[(i - 1) * m + (j - 1)] {
                case 0:
                    starts[i - 1] = heard[j - 1].start
                    ends[i - 1] = heard[j - 1].end
                    matched += 1
                    i -= 1
                    j -= 1
                case 1:
                    i -= 1
                default:
                    j -= 1
                }
            }
        }

        let coverage = n > 0 ? Double(matched) / Double(n) : 0
        var times = [Double](repeating: 0, count: n)
        var stops = [Double](repeating: 0, count: n)

        if coverage < 0.3 {
            // 對不太上（收音太差、沒照稿唸、辨識不可用）：照字數把稿子平均攤在有聲音的範圍裡。
            let from = heard.first?.start ?? 0
            let to = max(from + 1, heard.last?.end ?? duration)
            let each = (to - from) / Double(max(1, n))
            for index in 0..<n {
                times[index] = from + each * Double(index)
                stops[index] = times[index] + each
            }
        } else {
            let pace = 0.22
            var index = 0
            var lastKnown: (index: Int, end: Double)?
            while index < n {
                if let start = starts[index], let end = ends[index] {
                    times[index] = start
                    stops[index] = end
                    lastKnown = (index, end)
                    index += 1
                    continue
                }
                // 一串沒對上的字：找到下一個對上的，前後內插。
                var next = index
                while next < n, starts[next] == nil { next += 1 }
                let count = next - index
                let upper: Double? = next < n ? starts[next] : nil
                let lower: Double
                if let lastKnown {
                    lower = lastKnown.end
                } else if let upper {
                    lower = max(0, upper - pace * Double(count))
                } else {
                    lower = 0
                }
                let limit = upper ?? min(duration, lower + pace * Double(count))
                let each = max(0, limit - lower) / Double(count)
                for offset in 0..<count {
                    times[index + offset] = lower + each * Double(offset)
                    stops[index + offset] = times[index + offset] + each
                }
                index = next
            }
        }

        var cues: [SubtitleCue] = []
        var position = 0
        for (lineIndex, line) in lines.enumerated() {
            let count = lineKeys[lineIndex].count
            guard count > 0 else { continue }
            let first = position
            let last = position + count - 1
            position += count
            cues.append(SubtitleCue(start: times[first], end: stops[last], text: line))
        }
        return (cues, coverage)
    }

    /// 沒有稿子的時候：直接用辨識出來的字，照停頓和行長切句。
    private static func cuesFromWords(_ words: [Word], maxChars: Int) -> [SubtitleCue] {
        let limit = Double(max(4, maxChars))
        var cues: [SubtitleCue] = []
        var text = ""
        var start = 0.0
        var end = 0.0
        for word in words.sorted(by: { $0.start < $1.start }) {
            let wordEnd = word.start + max(word.duration, 0.15)
            let needsSpace = (text.last?.isASCII ?? false) && (word.text.first?.isASCII ?? false)
            let candidate = text + (needsSpace ? " " : "") + word.text
            let paused = !text.isEmpty && word.start - end > 0.6
            if !text.isEmpty && (paused || SubtitleLines.width(of: candidate) > limit) {
                cues.append(SubtitleCue(start: start, end: end, text: text))
                text = word.text
                start = word.start
            } else {
                if text.isEmpty { start = word.start }
                text = candidate
            }
            end = wordEnd
        }
        if !text.isEmpty {
            cues.append(SubtitleCue(start: start, end: end, text: text))
        }
        return cues
    }

    /// 整理時間：不重疊、不倒退、每句至少停留一下，兩句之間的小空隙補起來免得字幕閃。
    private static func tidy(_ cues: inout [SubtitleCue], duration: Double) {
        guard !cues.isEmpty else { return }
        var floor = 0.0
        for index in cues.indices {
            cues[index].start = min(max(cues[index].start, floor), max(0, duration - 0.1))
            floor = cues[index].start + 0.1
        }
        for index in cues.indices {
            let nextStart = index + 1 < cues.count ? cues[index + 1].start : duration
            var end = max(cues[index].end, cues[index].start + 0.7)
            if nextStart - end < 0.35 {
                end = nextStart
            }
            cues[index].end = max(cues[index].start + 0.1, min(end, nextStart))
        }
    }
}
