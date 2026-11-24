import AVFoundation
import Foundation
import Speech

/// 影片和稿子變成一句一句的字幕。逐段比：每段只拿自己的稿子對自己的聲音，重錄造成的錯位不會跨段。
/// 可以取消：取消呼叫它的 Task，會丟 CancellationError。
enum CaptionBuilder {
    typealias Clip = (url: URL, clip: CaptionClip, offset: Double, duration: Double)

    /// CaptionRecognition.engine 是這個字，代表這次沒有辨識。
    static let noEngine = "沒有辨識"
    /// 切段辨識時前後重疊幾秒。切點剛好在一個詞中間的話兩邊都會聽錯，重疊了就各取沒被切到的那邊。
    private static let overlap = 2.0
    /// 連續幾次失敗就不再試，多半是沒有網路或用完當天的次數。
    private static let maxFailures = 3

    /// log 和 progress（0 到 1）在背景執行緒呼叫。
    static func build(clips: [Clip], maxChars: Int, log: @escaping (String) -> Void,
                      progress: @escaping (Double) -> Void) async throws
        -> (lines: [CaptionLine], recognition: CaptionRecognition) {
        guard !clips.isEmpty else { throw SubtitleError.nothingToWrite }
        let engine = try await Engine.prepare()
        if engine.isOff {
            // 有稿子就照字數平均排時間，還是給得出字幕；沒稿子就真的做不了。
            guard clips.contains(where: { hasWords($0.clip.script) }) else { throw SubtitleError.unavailable }
            log("字幕：語音辨識不可用，照字數平均排時間")
        }

        let total = max(0.1, clips.reduce(0) { $0 + $1.duration })
        var done = 0.0
        var lines: [CaptionLine] = []
        var recognition = CaptionRecognition(engine: noEngine, onDevice: false)
        var keyCount = 0
        var hitCount = 0
        var wordCount = 0
        var confidences: [Double] = []
        var lastError: Error?
        var hasAudio = false
        progress(0)

        for (index, item) in clips.enumerated() {
            try Task.checkCancellation()
            let before = done
            let hearing = try await listen(item, engine: engine) { seconds in
                progress(min(0.98, (before + seconds) / total))
            }
            done += item.duration
            progress(min(0.98, done / total))
            hasAudio = hasAudio || hearing.hasAudio
            if let error = hearing.error { lastError = error }
            if let info = hearing.info {
                recognition.engine = info.engine
                recognition.onDevice = info.onDevice
            }
            wordCount += hearing.words.count
            confidences.append(contentsOf: hearing.words.compactMap { $0.confidence })

            let outcome = CaptionAligner.lines(script: item.clip.script, words: hearing.words.map { $0.word },
                                               failed: hearing.failed, duration: item.duration, maxChars: maxChars,
                                               boundaries: CaptionBreaker.wordBoundaries)
            keyCount += outcome.keyCount
            hitCount += outcome.hitCount
            for line in outcome.lines {
                lines.append(shifted(line, by: item.offset))
            }
            for range in hearing.failed {
                recognition.failedRanges.append((range.lowerBound + item.offset)...(range.upperBound + item.offset))
            }
            log("字幕第 \(index + 1) 段：" + summary(outcome, failures: hearing.failed.count))
        }

        guard hasAudio else { throw SubtitleError.noAudio }
        if keyCount > 0 { recognition.coverage = Double(hitCount) / Double(keyCount) }
        let mean = confidences.isEmpty ? "沒給" : String(format: "%.2f", confidences.reduce(0, +) / Double(confidences.count))
        log("字幕辨識：\(recognition.engine)，\(wordCount) 個詞，平均信心 \(mean)，失敗 \(recognition.failedRanges.count) 處"
            + (lastError.map { "（\($0.localizedDescription)）" } ?? ""))
        guard lines.contains(where: { !$0.text.isEmpty }) else {
            if let lastError { throw SubtitleError.failed(lastError.localizedDescription) }
            throw SubtitleError.nothingToWrite
        }
        progress(1)
        return (lines, recognition)
    }

    private static func hasWords(_ script: String) -> Bool {
        script.contains { SpokenKeys.key(for: $0) != nil }
    }

    /// 這一段的秒數換成整支影片的秒數。
    private static func shifted(_ line: CaptionLine, by offset: Double) -> CaptionLine {
        var moved = line
        moved.start += offset
        moved.end += offset
        for index in moved.words.indices {
            moved.words[index].start += offset
            moved.words[index].end += offset
        }
        return moved
    }

    private static func summary(_ outcome: CaptionAligner.Outcome, failures: Int) -> String {
        func count(_ status: CaptionStatus) -> Int { outcome.lines.filter { $0.status == status }.count }
        var text = "\(outcome.lines.count) 句，對上 \(outcome.hitCount)/\(outcome.keyCount) 字"
        text += "，要確認 \(count(.uncertain))、漏講 \(count(.missing))、多講 \(count(.extra))"
        text += "、沒辨識 \(count(.unrecognized))、直接聽 \(count(.heard))"
        if failures > 0 { text += "，失敗 \(failures) 處" }
        if outcome.isSparse { text += "，幾乎沒聽到" }
        return text
    }

    // MARK: - 引擎

    private enum Engine {
        case off
        case system(CaptionRecognizing)
        #if targetEnvironment(simulator)
        case fake(Set<String>)
        #endif

        var isOff: Bool {
            if case .off = self { return true }
            return false
        }

        /// 沒有權限會丟 SubtitleError.notAuthorized。
        static func prepare() async throws -> Engine {
            #if targetEnvironment(simulator)
            if let scenario = FakeCaptionRecognizer.scenario {
                return scenario.contains("offline") ? .off : .fake(scenario)
            }
            #endif
            guard await authorize() else { throw SubtitleError.notAuthorized }
            if let recognizer = SystemCaptionRecognizer() { return .system(recognizer) }
            return .off
        }

        private static func authorize() async -> Bool {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }

    // MARK: - 聽一段

    private struct Hearing {
        /// 時間是這一段自己的秒數。
        var words: [HeardWord] = []
        var failed: [ClosedRange<Double>] = []
        var hasAudio = true
        var error: Error?
        var info: CaptionRecognizerInfo?
    }

    private struct Chunk {
        let start: Double
        let end: Double
        var words: [HeardWord] = []
        /// 聽到第幾秒為止。整塊失敗是 nil。
        var heardTo: Double?
    }

    /// 這一段在影片檔裡的起點。規則和接片一樣：裁完太短就整段保留。
    private static func fileStart(_ asset: AVAsset, _ clip: CaptionClip) async throws -> Double {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return clip.start ?? 0 }
        let range = try await track.load(.timeRange)
        let lower = range.start.seconds
        let upper = range.end.seconds
        let start = max(lower, clip.start ?? lower)
        let end = min(upper, clip.end ?? upper)
        return end - start < 0.5 ? lower : start
    }

    private static func listen(_ item: Clip, engine: Engine, tick: (Double) -> Void) async throws -> Hearing {
        let asset = AVURLAsset(url: item.url)
        let hasScript = hasWords(item.clip.script)
        let start = try await fileStart(asset, item.clip)
        var lower = 0.0
        var upper = item.duration
        let available: CaptionRecognizing?

        switch engine {
        case .off:
            available = nil
        case .system(let system):
            available = system
        #if targetEnvironment(simulator)
        case .fake(let scenario):
            available = FakeCaptionRecognizer(script: item.clip.script, start: start, duration: item.duration,
                                              scenario: scenario)
        #endif
        }

        #if targetEnvironment(simulator)
        let needsAudio = FakeCaptionRecognizer.scenario == nil
        #else
        let needsAudio = true
        #endif
        if needsAudio {
            var isSilent = true
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                let range = try await track.load(.timeRange)
                lower = max(0, range.start.seconds - start)
                upper = min(item.duration, range.end.seconds - start)
                isSilent = upper - lower <= 0.05
            }
            if isSilent {
                // 沒有聲音的一段：有稿子就標成沒辨識讓人看，沒稿子就不用字幕。
                var hearing = Hearing()
                hearing.hasAudio = false
                if hasScript { hearing.failed = [0...max(0, item.duration)] }
                return hearing
            }
        }
        guard let recognizer = available else {
            var hearing = Hearing()
            hearing.failed = [0...max(0, item.duration)]
            return hearing
        }

        var chunks: [Chunk] = []
        var failures = 0
        var lastError: Error?
        var cursor = lower
        while true {
            try Task.checkCancellation()
            var end = upper
            if let most = recognizer.info.maxSeconds { end = min(upper, cursor + most) }
            var chunk = Chunk(start: cursor, end: end)
            if failures < maxFailures {
                let heard = try await hear(recognizer, asset: asset, from: start + cursor, seconds: end - cursor,
                                           hasScript: hasScript)
                chunk.words = heard.words.map { moved($0, by: cursor) }
                chunk.heardTo = heard.seconds.map { min(end, cursor + $0) }
                failures = heard.error == nil ? 0 : failures + 1
                if let error = heard.error { lastError = error }
            }
            chunks.append(chunk)
            tick(end)
            if end >= upper - 0.05 { break }
            cursor = max(cursor + 1, end - overlap)
        }

        var hearing = Hearing()
        hearing.words = spliced(chunks)
        hearing.failed = gaps(chunks, lower: lower, upper: upper)
        hearing.error = lastError
        hearing.info = recognizer.info
        return hearing
    }

    private static func moved(_ heard: HeardWord, by offset: Double) -> HeardWord {
        var result = heard
        result.word.start += offset
        result.word.end += offset
        return result
    }

    /// 辨識一塊。seconds 是聽到第幾秒為止，整塊失敗是 nil。連網的失敗了再試一次。
    private static func hear(_ recognizer: CaptionRecognizing, asset: AVAsset, from start: Double, seconds: Double,
                             hasScript: Bool) async throws -> (words: [HeardWord], seconds: Double?, error: Error?) {
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                duration: CMTime(seconds: seconds, preferredTimescale: 600))
        var tries = recognizer.info.onDevice ? 1 : 2
        while true {
            do {
                let words = try await recognizer.transcribe(asset: asset, range: range)
                return (words, seconds, nil)
            } catch let error as CancellationError {
                throw error
            } catch CaptionRecognizerError.noSpeech {
                return ([], seconds, nil)
            } catch CaptionRecognizerError.maybeSilent where !hasScript {
                // 沒稿子就沒有漏講這回事，當成沒人講話。有稿子的不能猜，往下算失敗。
                return ([], seconds, nil)
            } catch {
                try Task.checkCancellation()
                tries -= 1
                if tries > 0 {
                    try await Task.sleep(nanoseconds: 800_000_000)
                    continue
                }
                if case CaptionRecognizerError.partial(let words, _) = error {
                    return (words, words.map { $0.word.end }.max(), error)
                }
                return ([], nil, error)
            }
        }
    }

    /// 重疊的地方從中間接起來，前後各取離自己切點遠的詞。
    private static func spliced(_ chunks: [Chunk]) -> [HeardWord] {
        var result: [HeardWord] = []
        var floor = -Double.infinity
        for (index, chunk) in chunks.enumerated() {
            guard let heardTo = chunk.heardTo else {
                floor = -Double.infinity
                continue
            }
            var ceiling = Double.infinity
            if index + 1 < chunks.count, chunks[index + 1].heardTo != nil, chunks[index + 1].start < heardTo {
                ceiling = (chunks[index + 1].start + heardTo) / 2
            }
            for heard in chunk.words {
                let middle = (heard.word.start + heard.word.end) / 2
                if middle >= floor, middle < ceiling { result.append(heard) }
            }
            floor = ceiling.isFinite ? ceiling : -Double.infinity
        }
        return result
    }

    /// 沒有任何一塊聽到的時間。
    private static func gaps(_ chunks: [Chunk], lower: Double, upper: Double) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        var covered = lower
        for chunk in chunks {
            guard let heardTo = chunk.heardTo else { continue }
            if chunk.start - covered >= 0.3 { result.append(covered...chunk.start) }
            covered = max(covered, heardTo)
        }
        if upper - covered >= 0.3 { result.append(covered...upper) }
        return result
    }
}
