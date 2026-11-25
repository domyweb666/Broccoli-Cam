import AVFoundation
import Foundation
import Network
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

    /// log 和 progress（0 到 1）在背景執行緒呼叫。錄完檢查聽過的段落直接拿來用，fresh 是一律重新辨識。
    /// hearings 是各段聽到的字，沒辨識的是 nil。
    static func build(clips: [Clip], maxChars: Int, fresh: Bool = false, log: @escaping (String) -> Void,
                      progress: @escaping (Double) -> Void) async throws
        -> (lines: [CaptionLine], recognition: CaptionRecognition, hearings: [TakeHearing?]) {
        guard !clips.isEmpty else { throw SubtitleError.nothingToWrite }
        var remembered: [Int: Hearing] = [:]
        if !fresh {
            for (index, item) in clips.enumerated() {
                if let known = await recall(item) { remembered[index] = known }
            }
        }
        var engine = Engine.off
        // 全部聽過就不碰辨識，沒有網路也做得出來。
        if remembered.count < clips.count {
            engine = try await Engine.prepare()
            if engine.isOff {
                // 有稿子就照字數平均排時間，還是給得出字幕；沒稿子就真的做不了。
                guard !remembered.isEmpty || clips.contains(where: { hasWords($0.clip.script) }) else {
                    throw SubtitleError.unavailable
                }
                log("字幕：語音辨識不可用，照字數平均排時間")
            }
        }
        if !remembered.isEmpty { log("字幕：\(remembered.count) 段沿用錄完檢查聽到的字") }
        // 整支都沒有辨識。
        let isOff = engine.isOff && remembered.isEmpty

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
        var hearings: [TakeHearing?] = []
        progress(0)

        for (index, item) in clips.enumerated() {
            try Task.checkCancellation()
            let before = done
            let hearing: Hearing
            if let known = remembered[index] {
                hearing = known
                hearings.append(item.clip.hearing)
            } else {
                hearing = try await listen(item, engine: engine) { seconds in
                    progress(min(0.98, (before + seconds) / total))
                }
                hearings.append(record(hearing, duration: item.duration))
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
        if isOff || lines.allSatisfy({ $0.status == .unrecognized }) {
            recognition.problem = await problem(isOff, lastError, onDevice: recognition.onDevice).rawValue
        }
        progress(1)
        return (lines, recognition, hearings)
    }

    // MARK: - 錄完檢查

    /// 現在能不能直接聽，不會跳出權限視窗。
    static var canListenQuietly: Bool {
        #if targetEnvironment(simulator)
        if FakeCaptionRecognizer.scenario != nil { return true }
        #endif
        return SpeechFollower.isAuthorized
    }

    /// 只聽一支影片，不排字幕。聽不成就丟錯；只聽到一部分的，失敗的範圍會寫在裡面。
    static func hear(_ url: URL, script: String) async throws -> TakeHearing {
        guard canListenQuietly else { throw SubtitleError.notAuthorized }
        let engine = try await Engine.prepare()
        guard !engine.isOff else { throw SubtitleError.unavailable }
        guard let span = try await fileSpan(AVURLAsset(url: url)) else { throw SubtitleError.noAudio }
        let duration: Double = span.upperBound - span.lowerBound
        let clip = CaptionClip(file: url.lastPathComponent, start: nil, end: nil, script: script)
        let item: Clip = (url: url, clip: clip, offset: 0, duration: duration)
        let hearing = try await listen(item, engine: engine) { _ in }
        guard let result = record(hearing, duration: duration) else { throw SubtitleError.noAudio }
        return result
    }

    /// 換成影片檔自己的秒數留著。沒有真的聽到的是 nil。
    private static func record(_ hearing: Hearing, duration: Double) -> TakeHearing? {
        guard hearing.hasAudio, let info = hearing.info else { return nil }
        let start: Double = hearing.start
        let words: [CaptionWord] = hearing.words.map { heard in
            CaptionWord(text: heard.word.text, start: heard.word.start + start, end: heard.word.end + start)
        }
        let failed: [ClosedRange<Double>] = hearing.failed.map { range in
            (range.lowerBound + start)...(range.upperBound + start)
        }
        return TakeHearing(words: words, failed: failed, engine: info.engine, onDevice: info.onDevice,
                           fileLength: hearing.fileLength, from: start, to: start + duration)
    }

    /// 這一段之前聽過、而且整段都聽成了，就換成這一段的秒數拿來用。裁掉的地方的字不要。
    private static func recall(_ item: Clip) async -> Hearing? {
        guard let known = item.clip.hearing, known.isComplete else { return nil }
        guard let found = try? await fileSpan(AVURLAsset(url: item.url)) else { return nil }
        let span: ClosedRange<Double> = found
        let start: Double = fileStart(span, item.clip)
        guard abs(span.upperBound - known.fileLength) <= 0.1, known.from <= start + 0.1,
              known.to >= start + item.duration - 0.1 else { return nil }
        var hearing = Hearing()
        hearing.start = start
        hearing.fileLength = known.fileLength
        hearing.info = CaptionRecognizerInfo(engine: known.engine, onDevice: known.onDevice, maxSeconds: nil)
        hearing.words = known.words.compactMap { word -> HeardWord? in
            let middle: Double = (word.start + word.end) / 2 - start
            guard middle >= 0, middle <= item.duration else { return nil }
            let moved = CaptionWord(text: word.text, start: max(0, word.start - start),
                                    end: min(item.duration, word.end - start))
            return HeardWord(word: moved, confidence: nil)
        }
        return hearing
    }

    /// 整支都沒聽到，是卡在哪裡。查得出來的才講，不要什麼都說成沒網路。
    private static func problem(_ isOff: Bool, _ error: Error?, onDevice: Bool) async -> CaptionProblem {
        if isOff {
            #if targetEnvironment(simulator)
            if let scenario = FakeCaptionRecognizer.scenario {
                return scenario.contains("offline") ? .noNetwork : .unavailable
            }
            #endif
            let online = await isOnline()
            return SystemCaptionRecognizer.needsNetwork && !online ? .noNetwork : .unavailable
        }
        // 沒有錯誤卻整支沒辨識，是有稿子的段落沒有聲音。
        guard let error else { return .noSound }
        if case CaptionRecognizerError.cannotReadAudio = error { return .noSound }
        if !onDevice {
            let online = await isOnline()
            if !online || (error as NSError).code == NSURLErrorNotConnectedToInternet { return .noNetwork }
        }
        if case CaptionRecognizerError.timedOut = error { return .timedOut }
        return .failed
    }

    /// 現在連不連得上網。
    private static func isOnline() async -> Bool {
        for await path in NWPathMonitor() {
            return path.status == .satisfied
        }
        return true
    }

    private static func hasWords(_ script: String) -> Bool {
        script.contains { SpokenKeys.key(for: $0) != nil }
    }

    /// 這一段的秒數換成整支影片的秒數。
    private static func shifted(_ line: CaptionLine, by offset: Double) -> CaptionLine {
        var moved = line
        moved.start += offset
        moved.end += offset
        moved.doubtTime = moved.doubtTime.map { $0 + offset }
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
                let off = scenario.contains("offline") || scenario.contains("unavailable")
                return off ? .off : .fake(scenario)
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
        /// 這一段從影片檔的第幾秒開始、檔案的畫面到第幾秒。
        var start = 0.0
        var fileLength = 0.0
    }

    private struct Chunk {
        let start: Double
        let end: Double
        var words: [HeardWord] = []
        /// 聽到第幾秒為止。整塊失敗是 nil。
        var heardTo: Double?
    }

    /// 影片檔畫面的範圍（秒）。
    private static func fileSpan(_ asset: AVAsset) async throws -> ClosedRange<Double>? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let range = try await track.load(.timeRange)
        let lower = range.start.seconds
        let upper = range.end.seconds
        guard lower.isFinite, upper.isFinite, upper >= lower else { return nil }
        return lower...upper
    }

    /// 這一段在影片檔裡的起點。規則和接片一樣：裁完太短就整段保留。
    private static func fileStart(_ span: ClosedRange<Double>?, _ clip: CaptionClip) -> Double {
        guard let span else { return clip.start ?? 0 }
        let start = max(span.lowerBound, clip.start ?? span.lowerBound)
        let end = min(span.upperBound, clip.end ?? span.upperBound)
        return end - start < 0.5 ? span.lowerBound : start
    }

    private static func listen(_ item: Clip, engine: Engine, tick: (Double) -> Void) async throws -> Hearing {
        let asset = AVURLAsset(url: item.url)
        let hasScript = hasWords(item.clip.script)
        let span = try await fileSpan(asset)
        let start = fileStart(span, item.clip)
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
        hearing.start = start
        hearing.fileLength = span?.upperBound ?? 0
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
