import Foundation

/// 聽到的一個詞，加上辨識引擎有多確定。
struct HeardWord: Equatable {
    var word: CaptionWord
    /// 0 到 1。引擎沒給就是 nil。
    var confidence: Double?
}

/// 拿一段稿子去對同一段聲音：哪一句對上了、漏了、多講了，各在第幾秒。
/// 純邏輯，不碰辨識和影片。時間都是這一段自己的秒數，從 0 開始。
enum CaptionAligner {
    // MARK: - 門檻（起始值，要拿真實錄影調）

    /// 對上這個比例就直接用稿子。
    static let matchedRatio = 0.7
    /// 不到這個比例就當成漏講。
    static let missingRatio = 0.3
    /// 稿子沒有、連續講了這麼多字，才插一句。
    static let extraUnits = 4.0
    /// 一句最短停留（秒）。
    static let minimumDuration = 0.7
    /// 兩句之間的空隙小於這個（秒）就補起來，免得字幕閃。
    static let closeGap = 0.35
    /// 這麼短的句子常整句被聽錯；原處有聽到東西就先標黃，不當漏講。
    private static let shortLine = 3
    /// 整段都對不上、每秒又聽不到幾個音：比較像收音太差或辨識沒作用，不能說是漏講。
    private static let sparseRate = 0.5
    /// 沒對上的字用這個速度排（秒／字）。
    private static let defaultPace = 0.22
    /// 比對表最多幾格（一格一個位元組）。超過就不比，整段標成沒辨識。
    private static let cellLimit = 80_000_000

    struct Outcome {
        var lines: [CaptionLine]
        /// 稿子有幾個音、其中幾個找到時間。沒有稿子都是 0。
        var keyCount: Int
        var hitCount: Int
        /// 聽到的東西太少，整段沒對上的都標成沒辨識。
        var isSparse: Bool
    }

    /// 聽到的一個音。
    struct HeardKey {
        let value: String
        let start: Double
        let end: Double
        let word: Int
        /// 算「幾個字」用：中文一個字算 1，一個英文單字不管多長最多算 2，「嗯、啊」算 0。
        let weight: Double
    }

    /// failed 是辨識失敗的時間範圍。boundaries 是斷詞（第幾個字之前可以切）。
    static func lines(script: String, words: [CaptionWord], failed: [ClosedRange<Double>], duration: Double,
                      maxChars: Int, boundaries: @escaping (String) -> Set<Int>) -> Outcome {
        let heard = Heard(words: words, boundaries: boundaries, maxChars: maxChars)
        var solver = Solver(script: script, heard: heard, failed: failed, duration: max(0, duration),
                            maxChars: maxChars, boundaries: boundaries)
        return solver.run()
    }

    // MARK: - 聽到的字

    /// 聽到的字攤成一個一個音，同時留著原本的字，之後要拿來當字幕。
    struct Heard {
        var keys: [HeardKey] = []
        /// 全部聽到的字。英文單字之間補空白。
        var glyphs: [CaptionBreaker.Glyph] = []
        /// 第 k 個音在 glyphs 的哪裡。
        private var glyphIndex: [Int] = []
        private let boundaries: (String) -> Set<Int>
        private let maxChars: Int

        private static let fillers: Set<Character> = ["嗯", "啊", "呃", "欸", "喔", "哦", "唉", "ㄜ", "ㄟ"]

        init(words: [CaptionWord], boundaries: @escaping (String) -> Set<Int>, maxChars: Int) {
            self.boundaries = boundaries
            self.maxChars = maxChars
            var spans: [CaptionBreaker.Span] = []
            var owners: [Int] = []
            let sorted = words.sorted { $0.start < $1.start }
            for (index, word) in sorted.enumerated() {
                let values = SpokenKeys.keys(of: word.text)
                guard !values.isEmpty else { continue }
                // 有些詞的長度把後面的停頓也算進去，照字數封頂。
                var total = word.end - word.start
                if total <= 0 { total = CaptionAligner.defaultPace * Double(values.count) }
                total = min(total, 0.8 * Double(values.count))
                let each = total / Double(values.count)
                if let last = glyphs.last?.character, let first = word.text.first,
                   last.isASCII, first.isASCII, !last.isWhitespace {
                    glyphs.append(CaptionBreaker.Glyph(character: " ", key: nil))
                }
                var inside = 0
                for character in word.text {
                    guard SpokenKeys.key(for: character) != nil else {
                        glyphs.append(CaptionBreaker.Glyph(character: character, key: nil))
                        continue
                    }
                    let start = word.start + each * Double(inside)
                    glyphIndex.append(glyphs.count)
                    glyphs.append(CaptionBreaker.Glyph(character: character, key: spans.count))
                    spans.append(CaptionBreaker.Span(start: start, end: start + each))
                    owners.append(index)
                    inside += 1
                }
            }
            let weights = CaptionAligner.weights(glyphs, count: spans.count)
            for (index, span) in spans.enumerated() {
                let character = glyphs[glyphIndex[index]].character
                keys.append(HeardKey(value: SpokenKeys.key(for: character) ?? "", start: span.start, end: span.end,
                                     word: owners[index],
                                     weight: Self.fillers.contains(character) ? 0 : weights[index]))
            }
        }

        func units(_ range: Range<Int>) -> Double {
            range.reduce(0) { $0 + keys[$1].weight }
        }

        /// 這些音的字，重新編號從 0 開始。
        private func slice(_ range: Range<Int>) -> [CaptionBreaker.Glyph] {
            guard !range.isEmpty else { return [] }
            let from = glyphIndex[range.lowerBound]
            // 最後一個字後面黏著的符號（50 的 %）一起帶走。
            let to = range.upperBound < glyphIndex.count ? glyphIndex[range.upperBound] : glyphs.count
            return glyphs[from..<to].map { glyph in
                CaptionBreaker.Glyph(character: glyph.character, key: glyph.key.map { $0 - range.lowerBound })
            }
        }

        /// 「對了」的「對」已經算在稿子那句，剩下的「了」不要放在句首。
        func droppingHalfWord(_ run: Range<Int>) -> Range<Int> {
            var start = run.lowerBound
            while start > 0, start + 1 < run.upperBound,
                  CaptionBreaker.isParticle(glyphs[glyphIndex[start]].character) {
                // 「了解」這種整個詞都在這邊的不動。
                let word = keys[start].word
                guard word == keys[start - 1].word || word != keys[start + 1].word else { break }
                start += 1
            }
            return start..<run.upperBound
        }

        func text(_ range: Range<Int>) -> String {
            String(slice(range).map { $0.character }).trimmingCharacters(in: .whitespaces)
        }

        /// 把一串聽到的字排成字幕：停頓先切開，再照行長斷。
        func lines(_ range: Range<Int>, status: CaptionStatus) -> [CaptionLine] {
            let all = slice(range)
            let spans: [CaptionBreaker.Span] = range.map {
                CaptionBreaker.Span(start: keys[$0].start, end: keys[$0].end)
            }
            let known: [CaptionBreaker.Span?] = spans
            var result: [CaptionLine] = []
            for sentence in CaptionBreaker.sentences(all) {
                var piece: [CaptionBreaker.Glyph] = []
                var pieces: [[CaptionBreaker.Glyph]] = []
                var last: Int?
                for glyph in sentence {
                    if let key = glyph.key {
                        if let last, spans[key].start - spans[last].end > CaptionBreaker.sentencePause {
                            pieces.append(piece)
                            piece = []
                        }
                        last = key
                    }
                    piece.append(glyph)
                }
                pieces.append(piece)
                for piece in pieces {
                    let broken = CaptionBreaker.lines(piece, maxChars: maxChars, times: known, forced: [],
                                                      boundaries: boundaries)
                    for line in broken {
                        guard let inner = line.keys else { continue }
                        // 整行只有「嗯」「啊」就不用上字幕。
                        let here = (range.lowerBound + inner.lowerBound)..<(range.lowerBound + inner.upperBound)
                        guard units(here) > 0 else { continue }
                        let times = Array(spans[inner])
                        result.append(CaptionLine(text: line.text, scriptText: nil, heardText: line.text,
                                                  start: times[0].start, end: times[times.count - 1].end,
                                                  status: status,
                                                  words: CaptionAligner.words(line.glyphs, times: times)))
                    }
                }
            }
            return result
        }
    }

    /// 每個音算幾個字。英文單字一個字母一個音，照字母數會蓋過中文。
    static func weights(_ glyphs: [CaptionBreaker.Glyph], count: Int) -> [Double] {
        var result = [Double](repeating: 1, count: count)
        var run: [Int] = []
        func flush() {
            guard !run.isEmpty else { return }
            let each = min(1, 2 / Double(run.count))
            for key in run { result[key] = each }
            run = []
        }
        for glyph in glyphs {
            if let key = glyph.key, glyph.character.isASCII, glyph.character.isLetter {
                run.append(key)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    /// 一行字配上每個音的時間。連著的英數併成一個詞，標點黏在旁邊的詞上。
    fileprivate static func words(_ glyphs: [CaptionBreaker.Glyph], times: [CaptionBreaker.Span]) -> [CaptionWord] {
        var result: [CaptionWord] = []
        var prefix = ""
        var index = 0
        var canJoin = false
        for glyph in glyphs {
            let character = glyph.character
            if character.isWhitespace {
                canJoin = false
                continue
            }
            guard glyph.key != nil, index < times.count else {
                if result.isEmpty {
                    prefix.append(character)
                } else {
                    result[result.count - 1].text.append(character)
                }
                continue
            }
            let span = times[index]
            index += 1
            if canJoin, character.isASCII, !result.isEmpty {
                result[result.count - 1].text.append(character)
                result[result.count - 1].end = span.end
            } else {
                result.append(CaptionWord(text: prefix + String(character), start: span.start, end: span.end))
                prefix = ""
            }
            canJoin = character.isASCII
        }
        return result
    }

    // MARK: - 比對

    private struct Symbol {
        let exact: Int32
        let loose: Int32
        let isLetter: Bool
    }

    /// 台灣國語常分不清的音當成同一個：ㄓㄔㄕ／ㄗㄘㄙ、ㄥ／ㄣ。
    private static func loose(_ value: String) -> String {
        guard value.count > 1 else { return value }
        var text = value
        for head in ["zh", "ch", "sh"] where text.hasPrefix(head) {
            text.remove(at: text.index(after: text.startIndex))
            break
        }
        if text.hasSuffix("ing") || text.hasSuffix("eng") {
            text.removeLast()
        }
        return text
    }

    private struct SymbolTable {
        private var ids: [String: Int32] = [:]

        private mutating func id(_ key: String) -> Int32 {
            if let known = ids[key] { return known }
            let next = Int32(ids.count)
            ids[key] = next
            return next
        }

        mutating func symbol(_ value: String) -> Symbol {
            let isLetter = value.count == 1 && (value.first?.isASCII ?? false)
            return Symbol(exact: id("=" + value), loose: id("~" + CaptionAligner.loose(value)), isLetter: isLetter)
        }
    }

    private static func isHit(_ a: Symbol, _ b: Symbol) -> Bool {
        a.exact == b.exact || a.loose == b.loose
    }

    private static let gapOpen: Int32 = 3
    private static let unreachable: Int32 = -1_000_000_000

    private static func score(_ a: Symbol, _ b: Symbol) -> Int32 {
        if a.exact == b.exact { return a.isLetter ? 2 : 4 }
        if a.loose == b.loose { return 3 }
        return a.isLetter || b.isLetter ? -1 : -2
    }

    /// 全域比對，回傳（稿子第幾個音，聽到的第幾個音）。對錯的字也會配成一對，好借它的時間。
    /// 斷開要扣分，所以重講時會整段挑同一次，不會東拼西湊；一樣好就挑後面那次。
    /// fit：聽到的頭尾多出來的不扣分，中間拖越長扣越多，用來在一段聲音裡找一句完整的。
    private static func align(_ s: [Symbol], _ h: [Symbol], fit: Bool) -> [(Int, Int)] {
        let n = s.count
        let m = h.count
        guard n > 0, m > 0, n <= cellLimit / (m + 1) else { return [] }
        let width = m + 1
        // 每格記三個狀態各從哪裡來：0 = 配對，1 = 稿子多，2 = 聽到多。
        var trace = [UInt8](repeating: 0, count: (n + 1) * width)
        var mPrev = [Int32](repeating: unreachable, count: width)
        var xPrev = [Int32](repeating: unreachable, count: width)
        var yPrev = [Int32](repeating: unreachable, count: width)
        var mRow = mPrev
        var xRow = xPrev
        var yRow = yPrev
        mPrev[0] = 0
        for j in 1...m { yPrev[j] = fit ? 0 : -gapOpen }
        let gapExtend: Int32 = fit ? 1 : 0

        trace.withUnsafeMutableBufferPointer { trace in
            for i in 1...n {
                let a = s[i - 1]
                mRow[0] = unreachable
                yRow[0] = unreachable
                xRow[0] = -gapOpen
                // 第 0 欄只會一路往上，來源不影響結果。
                for j in 1...m {
                    var source: UInt8 = 0
                    var diagonal = mPrev[j - 1]
                    if xPrev[j - 1] > diagonal { diagonal = xPrev[j - 1]; source = 1 }
                    if yPrev[j - 1] > diagonal { diagonal = yPrev[j - 1]; source = 2 }
                    mRow[j] = diagonal + score(a, h[j - 1])

                    var up = mPrev[j] - gapOpen
                    var upSource: UInt8 = 0
                    if xPrev[j] > up { up = xPrev[j]; upSource = 1 }
                    if yPrev[j] - gapOpen > up { up = yPrev[j] - gapOpen; upSource = 2 }
                    xRow[j] = up

                    var left = mRow[j - 1] - gapOpen
                    var leftSource: UInt8 = 0
                    if yRow[j - 1] - gapExtend > left { left = yRow[j - 1] - gapExtend; leftSource = 2 }
                    if xRow[j - 1] - gapOpen > left { left = xRow[j - 1] - gapOpen; leftSource = 1 }
                    yRow[j] = left

                    trace[i * width + j] = source | (upSource << 2) | (leftSource << 4)
                }
                swap(&mPrev, &mRow)
                swap(&xPrev, &xRow)
                swap(&yPrev, &yRow)
            }
        }

        var j = m
        var state: UInt8 = 0
        if fit {
            var best: Int32 = 0
            j = 0
            for column in 1...m {
                let top = max(mPrev[column], xPrev[column])
                if top > 0, top >= best {
                    best = top
                    j = column
                }
            }
            guard j > 0 else { return [] }
            state = mPrev[j] >= xPrev[j] ? 0 : 1
        } else if xPrev[m] > mPrev[m] || yPrev[m] > mPrev[m] {
            state = xPrev[m] >= yPrev[m] ? 1 : 2
        }

        var pairs: [(Int, Int)] = []
        var i = n
        while i > 0 && j > 0 {
            let cell = trace[i * width + j]
            switch state {
            case 0:
                pairs.append((i - 1, j - 1))
                state = cell & 3
                i -= 1
                j -= 1
            case 1:
                state = (cell >> 2) & 3
                i -= 1
            default:
                state = (cell >> 4) & 3
                j -= 1
            }
        }
        return pairs.reversed()
    }

    // MARK: - 主流程

    private struct Solver {
        private let heard: Heard
        private let failed: [ClosedRange<Double>]
        private let duration: Double
        private let maxChars: Int
        private let boundaries: (String) -> Set<Int>

        private let sentences: [[CaptionBreaker.Glyph]]
        private let keySymbols: [Symbol]
        private let keyWeights: [Double]
        private let heardSymbols: [Symbol]
        /// 稿子第 i 個音配到聽到的第幾個音，沒有就是 -1。
        private var pair: [Int]
        /// 配到的是不是同一個音。
        private var hit: [Bool]
        private var pace = CaptionAligner.defaultPace

        /// 一行字幕的判斷過程。
        private struct Draft {
            var line: CaptionBreaker.Line
            var keys: Range<Int>
            var status = CaptionStatus.matched
            /// 這一行蓋到的聽到的音。
            var heard: Range<Int>?
        }

        init(script: String, heard: Heard, failed: [ClosedRange<Double>], duration: Double, maxChars: Int,
             boundaries: @escaping (String) -> Set<Int>) {
            self.heard = heard
            self.failed = failed
            self.duration = duration
            self.maxChars = maxChars
            self.boundaries = boundaries
            let glyphs = CaptionBreaker.glyphs(of: script)
            var table = SymbolTable()
            var symbols: [Symbol] = []
            for glyph in glyphs where glyph.key != nil {
                symbols.append(table.symbol(SpokenKeys.key(for: glyph.character) ?? ""))
            }
            sentences = CaptionBreaker.sentences(glyphs)
            keySymbols = symbols
            keyWeights = CaptionAligner.weights(glyphs, count: symbols.count)
            heardSymbols = heard.keys.map { table.symbol($0.value) }
            pair = [Int](repeating: -1, count: symbols.count)
            hit = [Bool](repeating: false, count: symbols.count)
        }

        mutating func run() -> Outcome {
            guard !keySymbols.isEmpty else { return withoutScript() }

            for (i, j) in CaptionAligner.align(keySymbols, heardSymbols, fit: false) {
                link(i, j)
            }
            let clauses = sentences.flatMap { CaptionBreaker.clauses($0) }
            releaseStray(clauses)
            for sentence in sentences.reversed() {
                let keys = sentence.compactMap { $0.key }
                if let first = keys.first, let last = keys.last { retake(first..<(last + 1)) }
            }
            for clause in clauses.reversed() { retake(clause) }
            pace = measuredPace()

            var drafts = breakIntoDrafts()
            for draft in drafts.reversed() where draft.keys.count >= 4 { retake(draft.keys) }
            for draft in drafts { trimStragglers(draft.keys) }

            let hits = hit.filter { $0 }.count
            let sparse = isSparse(hits: hits)
            grade(&drafts, sparse: sparse)
            let extras = claimLeftovers(&drafts)

            var visible: [CaptionLine] = []
            var hidden: [CaptionLine] = []
            place(drafts, extras: extras, visible: &visible, hidden: &hidden)
            for range in extras {
                visible.append(contentsOf: heard.lines(range, status: .extra))
            }
            return Outcome(lines: finish(visible, hidden), keyCount: keySymbols.count, hitCount: hits,
                           isSparse: sparse)
        }

        /// 沒有稿子：全部用聽到的。沒聽成的時間留一句空的，不然那段會無聲無息地沒字幕。
        private func withoutScript() -> Outcome {
            var lines = heard.keys.isEmpty ? [] : heard.lines(0..<heard.keys.count, status: .heard)
            for range in failed where range.upperBound - range.lowerBound >= CaptionAligner.minimumDuration {
                lines.append(CaptionLine(text: "", scriptText: nil, heardText: nil, start: range.lowerBound,
                                         end: range.upperBound, status: .unrecognized))
            }
            return Outcome(lines: finish(lines, []), keyCount: 0, hitCount: 0, isSparse: false)
        }

        private mutating func link(_ i: Int, _ j: Int) {
            pair[i] = j
            hit[i] = CaptionAligner.isHit(keySymbols[i], heardSymbols[j])
        }

        private mutating func release(_ range: Range<Int>) {
            for i in range {
                pair[i] = -1
                hit[i] = false
            }
        }

        private func hitCount(_ range: Range<Int>) -> Int {
            range.reduce(0) { $0 + (hit[$1] ? 1 : 0) }
        }

        private func weight(_ range: Range<Int>) -> Double {
            range.reduce(0) { $0 + keyWeights[$1] }
        }

        private func ratio(_ range: Range<Int>) -> Double {
            let total = weight(range)
            guard total > 0 else { return 0 }
            return range.reduce(0) { $0 + (hit[$1] ? keyWeights[$1] : 0) } / total
        }

        /// 這個音之前最後一個有配到的，配到聽到的第幾個音。沒有就是 -1。
        private func lastPaired(before key: Int) -> Int {
            var i = key - 1
            while i >= 0 {
                if pair[i] >= 0 { return pair[i] }
                i -= 1
            }
            return -1
        }

        /// 這個音（含）之後第一個有配到的。沒有就是聽到的總數。
        private func firstPaired(from key: Int) -> Int {
            var i = key
            while i < pair.count {
                if pair[i] >= 0 { return pair[i] }
                i += 1
            }
            return heard.keys.count
        }

        /// 漏講的短句常會沾到別句的一兩個音，先放掉，免得擋住重講的判斷。
        private mutating func releaseStray(_ clauses: [Range<Int>]) {
            for clause in clauses where clause.count <= 20 && ratio(clause) < CaptionAligner.missingRatio {
                release(clause)
            }
        }

        /// 這句在聲音裡出現不只一次，就改用最後一次。由後往前做，後面的先讓出位置。
        private mutating func retake(_ range: Range<Int>) {
            let size = range.count
            guard size >= 3 else { return }
            var lower = lastPaired(before: range.lowerBound) + 1
            let upper = firstPaired(from: range.upperBound)
            guard upper - lower >= size + max(2, size / 3) else { return }
            let needed = size == 3 ? 3 : Int((Double(size) * CaptionAligner.matchedRatio).rounded(.up))
            let floor = max(needed, hitCount(range) - max(1, size / 5))
            let symbols = Array(keySymbols[range])
            // 先找最像的一次，再看它後面還有沒有，直到沒有為止。
            while upper - lower >= needed, size <= 4_000_000 / (upper - lower + 1) {
                let found = CaptionAligner.align(symbols, Array(heardSymbols[lower..<upper]), fit: true)
                guard let first = found.first, let last = found.last else { return }
                var hits = 0
                for (i, j) in found where CaptionAligner.isHit(symbols[i], heardSymbols[lower + j]) { hits += 1 }
                let span = last.1 - first.1 + 1
                guard hits >= floor, span <= size + max(3, size / 2) else { return }
                release(range)
                for (i, j) in found {
                    link(range.lowerBound + i, lower + j)
                }
                lower += last.1 + 1
            }
        }

        /// 這個人平均一個音多長。
        private func measuredPace() -> Double {
            var lengths: [Double] = []
            for i in pair.indices where hit[i] && keyWeights[i] == 1 {
                lengths.append(heard.keys[pair[i]].end - heard.keys[pair[i]].start)
            }
            guard lengths.count >= 5 else { return CaptionAligner.defaultPace }
            lengths.sort()
            return min(0.35, max(0.1, lengths[lengths.count / 2]))
        }

        // MARK: 斷行

        private func span(_ key: Int) -> CaptionBreaker.Span? {
            guard pair[key] >= 0 else { return nil }
            let source = heard.keys[pair[key]]
            return CaptionBreaker.Span(start: source.start, end: source.end)
        }

        private func breakIntoDrafts() -> [Draft] {
            let times: [CaptionBreaker.Span?] = pair.indices.map { span($0) }
            var drafts: [Draft] = []
            for sentence in mergeTiny(sentences, times: times) {
                let keys = sentence.compactMap { $0.key }
                guard let first = keys.first, let last = keys.last else { continue }
                let forced = insertions(in: first..<(last + 1))
                let lines = CaptionBreaker.lines(sentence, maxChars: maxChars, times: times, forced: forced,
                                                 boundaries: boundaries)
                for line in lines {
                    guard let range = line.keys else { continue }
                    drafts.append(Draft(line: line, keys: range))
                }
            }
            return drafts
        }

        /// 「對。」「好。」這種一兩個字的句子，講得緊接著就和隔壁併一行，不然停不到 0.7 秒。
        private func mergeTiny(_ source: [[CaptionBreaker.Glyph]],
                               times: [CaptionBreaker.Span?]) -> [[CaptionBreaker.Glyph]] {
            var result: [[CaptionBreaker.Glyph]] = []
            for sentence in source {
                let keys = sentence.compactMap { $0.key }
                if let previous = result.last, let first = keys.first {
                    let before = previous.compactMap { $0.key }
                    let width = SubtitleLines.width(of: String(previous.map { $0.character }))
                        + SubtitleLines.width(of: String(sentence.map { $0.character })) + 0.5
                    if min(before.count, keys.count) <= 2, width <= Double(max(4, maxChars)),
                       let last = before.last, let from = times[last], let to = times[first],
                       to.start - from.end < 0.3 {
                        result[result.count - 1].append(CaptionBreaker.Glyph(character: "，", key: nil))
                        result[result.count - 1].append(contentsOf: sentence)
                        continue
                    }
                }
                result.append(sentence)
            }
            return result
        }

        /// 兩個相鄰的、有配到的音之間，聽到的比稿子多出幾個字。
        private func surplus(from a: Int, to b: Int) -> Double {
            guard pair[b] > pair[a] + 1 else { return 0 }
            return heard.units((pair[a] + 1)..<pair[b]) - weight((a + 1)..<b)
        }

        /// 句子中間插了一段稿子沒有的話：從那裡換行，多講的那句才有地方放。
        private func insertions(in range: Range<Int>) -> Set<Int> {
            var result: Set<Int> = []
            var previous: Int?
            for i in range where pair[i] >= 0 {
                if let a = previous, surplus(from: a, to: i) >= CaptionAligner.extraUnits,
                   hitCount(range.lowerBound..<(a + 1)) >= 3, hitCount(i..<range.upperBound) >= 3 {
                    result.insert(a + 1)
                }
                previous = i
            }
            return result
        }

        /// 一行的頭或尾有一兩個音落在插話的另一邊，多半是巧合，放掉它。
        private mutating func trimStragglers(_ range: Range<Int>) {
            let paired = range.filter { pair[$0] >= 0 }
            guard paired.count >= 2 else { return }
            for index in 1..<paired.count {
                let a = paired[index - 1]
                let b = paired[index]
                guard pair[a] >= 0, pair[b] >= 0, surplus(from: a, to: b) >= CaptionAligner.extraUnits else { continue }
                let left = range.lowerBound..<(a + 1)
                let right = b..<range.upperBound
                if hitCount(left) <= 2, hitCount(left) <= hitCount(right) {
                    release(left)
                } else if hitCount(right) <= 2 {
                    release(right)
                }
            }
        }

        // MARK: 分級

        private func isSparse(hits: Int) -> Bool {
            let keys = heard.keys.count
            if keys == 0 { return true }
            // 太長比不動，等於沒辨識。
            if keySymbols.count > CaptionAligner.cellLimit / (keys + 1) { return true }
            guard duration >= 5, Double(hits) < Double(keySymbols.count) * 0.3 else { return false }
            return Double(keys) / duration < CaptionAligner.sparseRate
        }

        /// 這一行應該在的時間有沒有碰到辨識失敗的範圍。
        private func touchesFailure(_ range: Range<Int>) -> Bool {
            guard !failed.isEmpty else { return false }
            let before = lastPaired(before: range.lowerBound)
            let after = firstPaired(from: range.upperBound)
            let lower = before >= 0 ? heard.keys[before].end : 0
            let upper = after < heard.keys.count ? heard.keys[after].start : duration
            return failed.contains { min(upper, $0.upperBound) - max(lower, $0.lowerBound) >= 0.3 }
        }

        private mutating func grade(_ drafts: inout [Draft], sparse: Bool) {
            for index in drafts.indices {
                let range = drafts[index].keys
                let share = ratio(range)
                if share >= CaptionAligner.matchedRatio {
                    drafts[index].status = .matched
                } else if sparse || touchesFailure(range) {
                    drafts[index].status = .unrecognized
                    if share < CaptionAligner.missingRatio { release(range) }
                } else if share >= CaptionAligner.missingRatio {
                    drafts[index].status = .uncertain
                } else {
                    drafts[index].status = .missing
                    release(range)
                }
            }
            for index in drafts.indices {
                let paired = drafts[index].keys.filter { pair[$0] >= 0 }
                if let first = paired.first, let last = paired.last {
                    drafts[index].heard = pair[first]..<(pair[last] + 1)
                }
            }
            for index in drafts.indices where drafts[index].status == .missing {
                rescueShort(&drafts, index)
            }
        }

        /// 一兩個字的句子整句聽錯就會變成 0%。原處有聽到差不多長的東西，就標黃給人看。
        private func rescueShort(_ drafts: inout [Draft], _ index: Int) {
            let range = drafts[index].keys
            guard range.count <= CaptionAligner.shortLine else { return }
            // 前後的句子也漏了就不知道聽到的是哪一句。
            if index > 0, drafts[index - 1].heard == nil { return }
            if index + 1 < drafts.count, drafts[index + 1].heard == nil { return }
            let lower = lastPaired(before: range.lowerBound) + 1
            let upper = firstPaired(from: range.upperBound)
            guard upper > lower else { return }
            let units = heard.units(lower..<upper)
            guard units > 0, units < weight(range) + CaptionAligner.extraUnits else { return }
            drafts[index].status = .uncertain
            drafts[index].heard = lower..<upper
        }

        /// 沒有人要的聲音：夠長就是多講的一句；短的、剛好補在某行沒對上的頭尾，就算那一行聽到的。
        private func claimLeftovers(_ drafts: inout [Draft]) -> [Range<Int>] {
            let total = heard.keys.count
            var owner = [Int](repeating: -1, count: total)
            for (index, draft) in drafts.enumerated() {
                if let range = draft.heard {
                    for key in range { owner[key] = index }
                }
            }
            var extras: [Range<Int>] = []
            var start = 0
            while start < total {
                guard owner[start] < 0 else {
                    start += 1
                    continue
                }
                var end = start
                while end < total, owner[end] < 0 { end += 1 }
                let run = start..<end
                let before: Int? = start > 0 ? owner[start - 1] : nil
                let after: Int? = end < total ? owner[end] : nil
                start = end

                let tail = before.map { unpairedTail(drafts[$0].keys) } ?? 0
                let head = after.map { unpairedHead(drafts[$0].keys) } ?? 0
                let units = heard.units(run)
                if units - tail - head >= CaptionAligner.extraUnits {
                    extras.append(heard.droppingHalfWord(run))
                } else if units > 0, tail + head > 0 {
                    let share = Int((Double(run.count) * tail / (tail + head)).rounded())
                    let cut = wordEdge(near: run.lowerBound + share, in: run)
                    if let before, cut > run.lowerBound, let range = drafts[before].heard {
                        drafts[before].heard = range.lowerBound..<cut
                    }
                    if let after, cut < run.upperBound, let range = drafts[after].heard {
                        drafts[after].heard = cut..<range.upperBound
                    }
                }
            }
            return extras
        }

        private func unpairedTail(_ range: Range<Int>) -> Double {
            var total = 0.0
            for i in range.reversed() {
                if pair[i] >= 0 { break }
                total += keyWeights[i]
            }
            return total
        }

        private func unpairedHead(_ range: Range<Int>) -> Double {
            var total = 0.0
            for i in range {
                if pair[i] >= 0 { break }
                total += keyWeights[i]
            }
            return total
        }

        /// 分給前後兩行時不要把一個詞切成兩半。
        private func wordEdge(near position: Int, in run: Range<Int>) -> Int {
            for offset in [0, -1, 1, -2, 2] {
                let cut = position + offset
                guard cut >= run.lowerBound, cut <= run.upperBound else { continue }
                if cut == run.lowerBound || cut == run.upperBound { return cut }
                if heard.keys[cut].word != heard.keys[cut - 1].word { return cut }
            }
            return position
        }

        // MARK: 排時間

        private func place(_ drafts: [Draft], extras: [Range<Int>], visible: inout [CaptionLine],
                           hidden: inout [CaptionLine]) {
            // 聽到的音有沒有被用掉，決定沒對上的字最多能往前後延伸到哪。
            var used = [Bool](repeating: false, count: heard.keys.count)
            for draft in drafts {
                if let range = draft.heard { for key in range { used[key] = true } }
            }
            for range in extras { for key in range { used[key] = true } }

            let timed: [[CaptionBreaker.Span]] = drafts.map { draft in
                draft.heard.map { keyTimes(draft, range: $0, used: used) } ?? []
            }
            let hasNeighbours = drafts.contains { $0.heard != nil }
            var index = 0
            var lower = 0.0
            while index < drafts.count {
                let draft = drafts[index]
                if let range = draft.heard {
                    let text = heard.text(range)
                    visible.append(make(draft, times: timed[index], heardText: text.isEmpty ? nil : text))
                    lower = timed[index].last?.end ?? lower
                    index += 1
                    continue
                }
                // 一串聲音裡找不到的句子：一起放進前後兩句中間的空檔。
                var end = index
                while end < drafts.count, drafts[end].heard == nil { end += 1 }
                let upper = end < drafts.count ? (timed[end].first?.start ?? duration) : duration
                spread(Array(drafts[index..<end]), lower: lower, upper: max(lower, upper),
                       hasNeighbours: hasNeighbours, visible: &visible, hidden: &hidden)
                index = end
            }
        }

        /// 沒聽到的句子照字數平均攤。沒辨識的放在失敗的那段時間裡；漏講的只佔個位置，不搶別句的時間。
        /// 空檔塞不下那麼多句沒辨識的，代表裡面有沒講的，但不知道是哪幾句：先藏起來等人看，
        /// 硬塞會把前後對好的句子推走。
        private func spread(_ group: [Draft], lower: Double, upper: Double, hasNeighbours: Bool,
                            visible: inout [CaptionLine], hidden: inout [CaptionLine]) {
            var from = lower
            var to = upper
            let overlaps = failed.filter { min(upper, $0.upperBound) - max(lower, $0.lowerBound) >= 0.3 }
            if let first = overlaps.map({ $0.lowerBound }).min(), let last = overlaps.map({ $0.upperBound }).max() {
                from = max(lower, first)
                to = min(upper, last)
            }
            let fits = !hasNeighbours || to - from >= CaptionAligner.minimumDuration * Double(group.count)
            let total = group.reduce(0.0) { $0 + weight($1.keys) }
            let each = max(0, to - from) / max(1, total)
            var cursor = from
            for draft in group {
                let isMissing = draft.status == .missing
                let step = isMissing ? min(each, pace) : each
                var times: [CaptionBreaker.Span] = []
                for key in draft.keys {
                    let length = step * keyWeights[key]
                    times.append(CaptionBreaker.Span(start: cursor, end: cursor + length))
                    cursor += length
                }
                var line = make(draft, times: times, heardText: nil)
                if !fits { line.isHidden = true }
                if line.isHidden {
                    hidden.append(line)
                } else {
                    visible.append(line)
                }
            }
        }

        /// 對到的音用聽到的時間；沒對到的，中間的內插，頭尾的照語速接在旁邊。
        private func keyTimes(_ draft: Draft, range: Range<Int>, used: [Bool]) -> [CaptionBreaker.Span] {
            let keys = Array(draft.keys)
            var times: [CaptionBreaker.Span?] = keys.map { span($0) }
            let known = times.indices.filter { times[$0] != nil }
            let rangeStart = heard.keys[range.lowerBound].start
            let rangeEnd = heard.keys[range.upperBound - 1].end
            guard let first = known.first, let last = known.last else {
                fill(&times, 0..<keys.count, keys, from: rangeStart, to: rangeEnd)
                return times.compactMap { $0 }
            }
            let anchor = times[first]?.start ?? rangeStart
            let finish = times[last]?.end ?? rangeEnd
            if first > 0 {
                let need = pace * weight(keys[0]..<keys[first])
                var floor = 0.0
                var key = range.lowerBound - 1
                while key >= 0 {
                    if used[key] {
                        floor = heard.keys[key].end
                        break
                    }
                    key -= 1
                }
                let start = rangeStart < anchor ? rangeStart : max(min(floor, anchor), anchor - need)
                fill(&times, 0..<first, keys, from: max(0, start), to: anchor)
            }
            if last + 1 < keys.count {
                let need = pace * weight(keys[last + 1]..<(keys[keys.count - 1] + 1))
                var ceiling = duration
                var key = range.upperBound
                while key < used.count {
                    if used[key] {
                        ceiling = heard.keys[key].start
                        break
                    }
                    key += 1
                }
                let end = rangeEnd > finish ? rangeEnd : min(max(ceiling, finish), finish + need)
                fill(&times, (last + 1)..<keys.count, keys, from: finish, to: end)
            }
            for position in known.indices.dropFirst() {
                let left = known[position - 1]
                let right = known[position]
                guard right > left + 1, let from = times[left]?.end, let to = times[right]?.start else { continue }
                fill(&times, (left + 1)..<right, keys, from: from, to: max(from, to))
            }
            return times.compactMap { $0 }
        }

        private func fill(_ times: inout [CaptionBreaker.Span?], _ range: Range<Int>, _ keys: [Int],
                          from: Double, to: Double) {
            let total = range.reduce(0.0) { $0 + keyWeights[keys[$1]] }
            guard total > 0 else { return }
            let each = max(0, to - from) / total
            var cursor = from
            for index in range {
                let length = each * keyWeights[keys[index]]
                times[index] = CaptionBreaker.Span(start: cursor, end: cursor + length)
                cursor += length
            }
        }

        private func make(_ draft: Draft, times: [CaptionBreaker.Span], heardText: String?) -> CaptionLine {
            CaptionLine(text: draft.line.text, scriptText: draft.line.text, heardText: heardText,
                        start: times.first?.start ?? 0, end: times.last?.end ?? 0, status: draft.status,
                        isHidden: draft.status == .missing,
                        words: CaptionAligner.words(draft.line.glyphs, times: times))
        }

        private func finish(_ visible: [CaptionLine], _ hidden: [CaptionLine]) -> [CaptionLine] {
            var shown = CaptionAligner.ordered(visible)
            CaptionAligner.tidy(&shown, duration: duration)
            var aside = hidden
            for index in aside.indices {
                // 藏起來的句子可以和別句重疊，只要自己站得住。
                aside[index].start = min(max(0, aside[index].start), max(0, duration - CaptionAligner.minimumDuration))
                aside[index].end = min(duration, max(aside[index].end, aside[index].start + CaptionAligner.minimumDuration))
            }
            return CaptionAligner.ordered(shown + aside)
        }
    }

    // MARK: - 整理時間

    /// 照開始時間排，一樣的維持原本順序。
    fileprivate static func ordered(_ lines: [CaptionLine]) -> [CaptionLine] {
        let order = lines.indices.sorted { a, b in
            if lines[a].start == lines[b].start { return a < b }
            return lines[a].start < lines[b].start
        }
        return order.map { lines[$0] }
    }

    /// 不重疊、每句至少 0.7 秒、不超出這一段；小空隙補起來免得字幕閃。
    static func tidy(_ lines: inout [CaptionLine], duration: Double) {
        guard !lines.isEmpty, duration > 0 else { return }
        let least = minimumDuration
        if Double(lines.count) * least > duration {
            // 塞不下，平均分，至少不重疊。
            let each = duration / Double(lines.count)
            for index in lines.indices {
                lines[index].start = each * Double(index)
                lines[index].end = each * Double(index + 1)
            }
            return
        }
        // 先用旁邊的空檔補長度：往後補，不夠再往前。
        for index in lines.indices {
            let previousEnd = index > 0 ? lines[index - 1].end : 0
            let nextStart = index + 1 < lines.count ? lines[index + 1].start : duration
            var start = max(lines[index].start, 0)
            var end = min(max(lines[index].end, start), max(nextStart, start))
            if end - start < least { end = max(end, min(nextStart, start + least)) }
            if end - start < least { start = min(start, max(previousEnd, end - least)) }
            lines[index].start = start
            lines[index].end = end
        }
        // 還是不夠就往後推。
        var cursor = 0.0
        for index in lines.indices {
            lines[index].start = max(lines[index].start, cursor)
            lines[index].end = max(lines[index].end, lines[index].start + least)
            cursor = lines[index].end
        }
        // 推出片尾了再往回擠。
        var ceiling = duration
        for index in lines.indices.reversed() {
            lines[index].end = min(lines[index].end, ceiling)
            lines[index].start = max(0, min(lines[index].start, lines[index].end - least))
            ceiling = lines[index].start
        }
        for index in lines.indices {
            let nextStart = index + 1 < lines.count ? lines[index + 1].start : duration
            if nextStart - lines[index].end < closeGap {
                lines[index].end = max(lines[index].end, nextStart)
            }
        }
    }
}
