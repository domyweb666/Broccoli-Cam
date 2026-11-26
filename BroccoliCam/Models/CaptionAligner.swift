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

    /// 設成 true 的工作被取消時，比對會中途放棄、回傳沒對上（結果要丟掉）。
    /// 只給「錄完檢查」用：它被取消就不會用結果。字幕那邊不設，行為完全照舊。
    @TaskLocal static var stopsWhenCancelled = false

    /// 比對表超過這麼多格才改用省記憶體的算法；以下照原本整張表記著。
    private static let compactCells = 4_000_000

    /// 全域比對，回傳（稿子第幾個音，聽到的第幾個音）。對錯的字也會配成一對，好借它的時間。
    /// 斷開要扣分，所以重講時會整段挑同一次，不會東拼西湊；一樣好就挑後面那次。
    /// fit：聽到的頭尾多出來的不扣分，中間拖越長扣越多，用來在一段聲音裡找一句完整的。
    private static func align(_ s: [Symbol], _ h: [Symbol], fit: Bool) -> [(Int, Int)] {
        let n = s.count
        let m = h.count
        guard n > 0, m > 0, n <= cellLimit / (m + 1) else { return [] }
        let width = m + 1
        let watchesCancel: Bool = stopsWhenCancelled
        var mPrev = [Int32](repeating: unreachable, count: width)
        var xPrev = [Int32](repeating: unreachable, count: width)
        var yPrev = [Int32](repeating: unreachable, count: width)
        var mRow = mPrev
        var xRow = xPrev
        var yRow = yPrev
        mPrev[0] = 0
        for j in 1...m { yPrev[j] = fit ? 0 : -gapOpen }
        let gapExtend: Int32 = fit ? 1 : 0
        var cancelled = false

        if (n + 1) * width <= compactCells {
            // 每格記三個狀態各從哪裡來：0 = 配對，1 = 稿子多，2 = 聽到多。
            var trace = [UInt8](repeating: 0, count: (n + 1) * width)
            trace.withUnsafeMutableBufferPointer { trace in
                for i in 1...n {
                    if watchesCancel, i & 31 == 0, Task.isCancelled {
                        cancelled = true
                        return
                    }
                    fillRow(s[i - 1], h, m: m, gapExtend: gapExtend, mPrev: mPrev, xPrev: xPrev, yPrev: yPrev,
                            mRow: &mRow, xRow: &xRow, yRow: &yRow, trace: trace, offset: i * width)
                    swap(&mPrev, &mRow)
                    swap(&xPrev, &xRow)
                    swap(&yPrev, &yRow)
                }
            }
            if cancelled { return [] }
            return traceBack(n: n, m: m, fit: fit, mLast: mPrev, xLast: xPrev, yLast: yPrev) { i, j in
                trace[i * width + j]
            }
        }

        // 長稿：整張來源表要 n × m 個位元組。改成每隔 block 列記一次分數（檢查點），
        // 往回找的時候再從檢查點把那一塊重算出來。每一格的算法和上面同一個 fillRow，結果相同，只是多算一遍。
        let block: Int = max(1, Int((12 * Double(n)).squareRoot()))
        var checkpoints: [(m: [Int32], x: [Int32], y: [Int32])] = []
        checkpoints.reserveCapacity(n / block + 1)
        var scratch = [UInt8](repeating: 0, count: width)
        scratch.withUnsafeMutableBufferPointer { scratch in
            for i in 1...n {
                if (i - 1) % block == 0 {
                    if watchesCancel, Task.isCancelled {
                        cancelled = true
                        return
                    }
                    // 第 i - 1 列算完的分數，第 i 列起的這一塊從這裡重算。
                    checkpoints.append((mPrev, xPrev, yPrev))
                }
                fillRow(s[i - 1], h, m: m, gapExtend: gapExtend, mPrev: mPrev, xPrev: xPrev, yPrev: yPrev,
                        mRow: &mRow, xRow: &xRow, yRow: &yRow, trace: scratch, offset: 0)
                swap(&mPrev, &mRow)
                swap(&xPrev, &xRow)
                swap(&yPrev, &yRow)
            }
        }
        if cancelled { return [] }

        var blockTrace = [UInt8](repeating: 0, count: block * width)
        var loadedBlock = -1
        var blockFirstRow = 1
        /// 把第 index 塊（第 index × block + 1 列起）每格的來源重算進 blockTrace。
        func load(_ index: Int) {
            let first: Int = index * block + 1
            let last: Int = min(n, (index + 1) * block)
            var mp: [Int32] = checkpoints[index].m
            var xp: [Int32] = checkpoints[index].x
            var yp: [Int32] = checkpoints[index].y
            var mr = [Int32](repeating: unreachable, count: width)
            var xr = mr
            var yr = mr
            blockTrace.withUnsafeMutableBufferPointer { trace in
                for i in first...last {
                    fillRow(s[i - 1], h, m: m, gapExtend: gapExtend, mPrev: mp, xPrev: xp, yPrev: yp,
                            mRow: &mr, xRow: &xr, yRow: &yr, trace: trace, offset: (i - first) * width)
                    swap(&mp, &mr)
                    swap(&xp, &xr)
                    swap(&yp, &yr)
                }
            }
            loadedBlock = index
            blockFirstRow = first
        }
        return traceBack(n: n, m: m, fit: fit, mLast: mPrev, xLast: xPrev, yLast: yPrev) { i, j in
            let index: Int = (i - 1) / block
            if index != loadedBlock { load(index) }
            return blockTrace[(i - blockFirstRow) * width + j]
        }
    }

    /// 算比對表的一列（a 是這一列的稿子音）。prev 是上一列，算好的放進 row，
    /// 每格的來源寫進 trace[offset + j]（第 0 格不寫）。
    @inline(__always)
    private static func fillRow(_ a: Symbol, _ h: [Symbol], m: Int, gapExtend: Int32,
                                mPrev: [Int32], xPrev: [Int32], yPrev: [Int32],
                                mRow: inout [Int32], xRow: inout [Int32], yRow: inout [Int32],
                                trace: UnsafeMutableBufferPointer<UInt8>, offset: Int) {
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

            trace[offset + j] = source | (upSource << 2) | (leftSource << 4)
        }
    }

    /// 從最後一列往回走。cell(i, j) 給第 i 列第 j 格的來源，i 只會越來越小。
    private static func traceBack(n: Int, m: Int, fit: Bool, mLast mPrev: [Int32], xLast xPrev: [Int32],
                                  yLast yPrev: [Int32], cell: (Int, Int) -> UInt8) -> [(Int, Int)] {
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
            let source: UInt8 = cell(i, j)
            switch state {
            case 0:
                pairs.append((i - 1, j - 1))
                state = source & 3
                i -= 1
                j -= 1
            case 1:
                state = (source >> 2) & 3
                i -= 1
            default:
                state = (source >> 4) & 3
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

        private let glyphs: [CaptionBreaker.Glyph]
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
            var doubt: CaptionDoubtFinder.Found?
        }

        /// 一行可能落在的時間。
        private struct Window {
            var lower: Double
            var upper: Double
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
            self.glyphs = glyphs
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
            markDoubts(&drafts)

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

        /// 這段時間有沒有碰到辨識失敗的範圍。
        private func touchesFailure(_ lower: Double, _ upper: Double) -> Bool {
            failed.contains { min(upper, $0.upperBound) - max(lower, $0.lowerBound) >= 0.3 }
        }

        /// 聽到的第 key 個音和前一個音之間，夾著一段辨識失敗。
        private func isHole(before key: Int) -> Bool {
            touchesFailure(heard.keys[key - 1].end, heard.keys[key].start)
        }

        /// 斷線前後聽到的一兩個音常聽錯，會碰巧配給斷點另一邊那句，那句就被拉成橫跨整段失敗，
        /// 夾在中間的句子沒有地方放。隔的時間比那幾個字該花的長很多，就放掉音少的那一邊。
        private mutating func trimAcrossFailure(_ range: Range<Int>) {
            let paired = range.filter { pair[$0] >= 0 }
            guard paired.count >= 2 else { return }
            for index in 1..<paired.count {
                let a = paired[index - 1]
                let b = paired[index]
                guard pair[a] >= 0, pair[b] >= 0 else { continue }
                let from = heard.keys[pair[a]].end
                let to = heard.keys[pair[b]].start
                let needed = pace * weight((a + 1)..<b) + 1
                guard touchesFailure(from, to), to - from >= needed else { continue }
                let left = range.lowerBound..<(a + 1)
                let right = b..<range.upperBound
                if hitCount(left) <= 2, hitCount(left) <= hitCount(right) {
                    release(left)
                } else if hitCount(right) <= 2 {
                    release(right)
                }
            }
        }

        /// 對得上又夠長，時間靠得住。短句可能是碰巧，不能拿來當前後的界線。
        private func isAnchor(_ range: Range<Int>) -> Bool {
            weight(range) > Double(CaptionAligner.shortLine) && ratio(range) >= CaptionAligner.matchedRatio
        }

        /// 每一行最寬可能落在哪段時間：只認前後靠得住的行，中間那些自己也不確定的不算數。
        private func windows(_ drafts: [Draft]) -> [Window] {
            var result = [Window](repeating: Window(lower: 0, upper: duration), count: drafts.count)
            var lower = 0.0
            for index in drafts.indices {
                result[index].lower = lower
                let keys = drafts[index].keys
                if isAnchor(keys), let last = keys.last(where: { hit[$0] }) {
                    lower = heard.keys[pair[last]].end
                }
            }
            var upper = duration
            for index in drafts.indices.reversed() {
                result[index].upper = upper
                let keys = drafts[index].keys
                if isAnchor(keys), let first = keys.first(where: { hit[$0] }) {
                    upper = heard.keys[pair[first]].start
                }
            }
            return result
        }

        /// 有兩個以上的音對上、不是碰巧，知道自己在哪。
        private func isSolid(_ range: Range<Int>) -> Bool {
            guard hitCount(range) >= 2 else { return false }
            return weight(range) > Double(CaptionAligner.shortLine) || ratio(range) >= CaptionAligner.matchedRatio
        }

        private func isSilent(_ range: Range<Int>) -> Bool {
            range.allSatisfy { pair[$0] < 0 }
        }

        /// 只靠一兩個音站住的短句，旁邊整句沒聽到、中間又沒有失敗可以解釋：多半是斷點旁聽錯的音碰巧一樣。
        /// 放掉它，不然隔壁真的講了的句子會被擠到沒地方放。
        private mutating func releaseDoubtful(_ drafts: [Draft], _ windows: [Window]) {
            guard !failed.isEmpty else { return }
            var changed = true
            while changed {
                changed = false
                for index in drafts.indices {
                    let range = drafts[index].keys
                    let window = windows[index]
                    guard !isSolid(range), touchesFailure(window.lower, window.upper) else { continue }
                    let paired = range.filter { pair[$0] >= 0 }
                    guard let first = paired.first, let last = paired.last else { continue }
                    let start = heard.keys[pair[first]].start
                    let end = heard.keys[pair[last]].end
                    var isDoubtful = false
                    if index > 0, isSilent(drafts[index - 1].keys), !touchesFailure(window.lower, start) {
                        isDoubtful = true
                    }
                    if index + 1 < drafts.count, isSilent(drafts[index + 1].keys), !touchesFailure(end, window.upper) {
                        isDoubtful = true
                    }
                    if isDoubtful {
                        release(range)
                        changed = true
                    }
                }
            }
        }

        /// 沒對上的這一行可能落在哪。自己有聽到幾個音的看前後配到的音；其他的看前後靠得住的行，寧可多標沒辨識。
        private func reach(_ range: Range<Int>, _ window: Window) -> Window {
            guard isSolid(range) else { return window }
            let before = lastPaired(before: range.lowerBound)
            let after = firstPaired(from: range.upperBound)
            return Window(lower: before >= 0 ? heard.keys[before].end : 0,
                          upper: after < heard.keys.count ? heard.keys[after].start : duration)
        }

        private mutating func grade(_ drafts: inout [Draft], sparse: Bool) {
            if !failed.isEmpty {
                for draft in drafts { trimAcrossFailure(draft.keys) }
            }
            // 先把對不上的行碰巧沾到的音全部放掉再判，不然前面的行會拿後面還沒放掉的當界線。
            for draft in drafts where ratio(draft.keys) < CaptionAligner.missingRatio {
                release(draft.keys)
            }
            let areas = windows(drafts)
            releaseDoubtful(drafts, areas)
            for index in drafts.indices {
                let range = drafts[index].keys
                let share = ratio(range)
                let area = reach(range, areas[index])
                if share >= CaptionAligner.matchedRatio {
                    drafts[index].status = .matched
                } else if sparse || touchesFailure(area.lower, area.upper) {
                    drafts[index].status = .unrecognized
                } else if share >= CaptionAligner.missingRatio {
                    drafts[index].status = .uncertain
                } else {
                    drafts[index].status = .missing
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
                // 中間斷過就分開算，斷點兩邊的聲音不能接給同一行。
                while end < total, owner[end] < 0, end == start || !isHole(before: end) { end += 1 }
                let run = start..<end
                var before: Int?
                if start > 0, owner[start - 1] >= 0, !isHole(before: start) { before = owner[start - 1] }
                var after: Int?
                if end < total, owner[end] >= 0, !isHole(before: end) { after = owner[end] }
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

        /// 音對得夠多、但數字或關鍵的字可能不一樣：降成要確認。漏講和沒辨識的判斷不受影響。
        private func markDoubts(_ drafts: inout [Draft]) {
            let finder = CaptionDoubtFinder(script: glyphs, heard: heard, pair: pair, hit: hit, failed: failed)
            for index in drafts.indices {
                let status = drafts[index].status
                guard status == .matched || status == .uncertain, let range = drafts[index].heard else { continue }
                let row = CaptionDoubtFinder.Row(keys: drafts[index].keys, heard: range)
                guard let found = finder.find(in: row) else { continue }
                drafts[index].doubt = found
                drafts[index].status = .uncertain
            }
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
                        words: CaptionAligner.words(draft.line.glyphs, times: times),
                        doubt: draft.doubt?.kind, doubtScript: draft.doubt?.script, doubtHeard: draft.doubt?.heard,
                        doubtTime: draft.doubt?.time)
        }

        private func finish(_ visible: [CaptionLine], _ hidden: [CaptionLine]) -> [CaptionLine] {
            var shown = CaptionAligner.ordered(visible)
            CaptionAligner.tidy(&shown, duration: duration)
            var aside = hidden
            for index in aside.indices {
                // 藏起來的句子可以和別句重疊，只要自己站得住。靠近片尾往前挪時不能跑到前一句的前面，順序會亂。
                let wanted = aside[index].start
                var previous = 0.0
                if let line = shown.last(where: { $0.start < wanted }) { previous = line.start + 0.01 }
                let latest = max(0, duration - CaptionAligner.minimumDuration)
                aside[index].start = max(previous, min(max(0, wanted), latest))
                aside[index].end = min(duration, max(aside[index].end, aside[index].start + CaptionAligner.minimumDuration))
                CaptionAligner.fitWords(&aside[index])
            }
            // 開始時間一樣的，藏著的排前面：它是塞在兩句中間的，接在前一句後面。
            return CaptionAligner.ordered(aside + shown)
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
    /// least 是最短停留。closesGaps 關掉就不補空隙，使用者調過的時間不要動。
    static func tidy(_ lines: inout [CaptionLine], duration: Double,
                     least shortest: Double = CaptionAligner.minimumDuration, closesGaps: Bool = true) {
        guard !lines.isEmpty, duration > 0 else { return }
        // 塞不下就縮短最短停留，已經對好的時間盡量留著。只取平均的一半：取滿的話每一句都被擠成一樣長，等於重分。
        let average = duration / Double(lines.count)
        let least = shortest > average ? average / 2 : shortest
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
            if closesGaps, nextStart - lines[index].end < closeGap {
                lines[index].end = max(lines[index].end, nextStart)
            }
            fitWords(&lines[index])
        }
    }

    /// 句子挪過之後，詞的時間跟著收進句子裡，不然拆句的切點會歪。沒跑出去的不動。
    static func fitWords(_ line: inout CaptionLine) {
        guard let from = line.words.map({ $0.start }).min(), let to = line.words.map({ $0.end }).max(),
              line.end >= line.start, to > from else { return }
        if from >= line.start - 0.01, to <= line.end + 0.01 { return }
        let scale = min(1, (line.end - line.start) / (to - from))
        let origin = min(max(from, line.start), line.end - (to - from) * scale)
        for index in line.words.indices {
            line.words[index].start = origin + (line.words[index].start - from) * scale
            line.words[index].end = origin + (line.words[index].end - from) * scale
        }
    }
}

// MARK: - 講的和寫的不一樣

/// 音對上了、意思可能不同的地方：數字不一樣、相反字（買／賣）、多一個或少一個「不」。
/// 拼音沒有聲調，四和十又當成同一個音，光看對上幾成抓不到。辨識也會寫錯，所以只標出來給人聽，不下判斷。
struct CaptionDoubtFinder {
    /// 一行字幕：蓋到稿子的哪些音、聽到的哪些音。
    struct Row {
        let keys: Range<Int>
        let heard: Range<Int>
    }

    struct Found {
        let kind: CaptionDoubt
        let script: String
        /// 沒聽到是 nil。
        let heard: String?
        let time: Double
    }

    /// 一個數字蓋到的音。
    private struct Placed {
        let number: SpokenNumber
        let keys: Range<Int>
    }

    /// 前後多看幾個聽到的音。「百分之十三」的前半可能沒算進這一行。
    private static let reach = 8
    /// 重講的同一句，兩次的數字至少隔這麼多個音。
    private static let retakeDistance = 6

    private static let opposites: [Character: Set<Character>] = {
        let pairs = ["買賣", "多少", "加減", "增減", "升降", "漲跌", "高低", "大小", "前後", "上下", "左右", "內外", "有無",
                     "進出", "早晚", "先後"]
        var result: [Character: Set<Character>] = [:]
        for pair in pairs {
            guard let first = pair.first, let last = pair.last else { continue }
            result[first, default: []].insert(last)
            result[last, default: []].insert(first)
        }
        return result
    }()

    private static let negations: Set<Character> = ["不", "沒", "無", "未", "別", "勿", "非"]
    /// 這些詞裡的不是否定，多一個少一個意思不會反過來。
    private static let notNegations: [[Character]] = [
        "不過", "不管", "不論", "不但", "不僅", "不然", "不如", "不妨", "不得了", "差不多", "了不起", "對不起", "不好意思",
        "只不過", "無論", "非常", "非洲", "除非", "是非", "特別", "別人", "分別", "個別", "性別", "類別", "級別", "區別",
        "差別", "告別", "離別", "別墅", "未來",
        // 加不加都是同一個意思的。「好不公平」是真的否定，所以「好不」不能整個放進來。
        "好不容易", "好不熱鬧", "好不威風", "好不快活", "好不得意", "不也", "不正是", "豈不", "恨不得", "巴不得", "不由得",
        "不愧", "不外乎", "未免", "莫非", "無非", "非得", "非要", "難免不會", "小心不要", "小心別", "當心不要", "當心別"
    ].map { Array($0) }
    /// 「不就」是反問（這不就好了），但不就業、不就醫、不就近是否定。
    private static let afterNotJust: Set<Character> = [
        "業", "醫", "職", "學", "讀", "寢", "範", "任", "位", "座", "近", "事", "地"
    ]
    /// 「差點沒摔倒」和「差點摔倒」一樣；「差點沒趕上」就不一樣。
    private static let mishaps: Set<Character> = [
        "摔", "跌", "死", "昏", "暈", "氣", "笑", "嚇", "哭", "吐", "瘋", "撞", "崩", "累", "掉"
    ]
    /// 「不得不、不能不」兩個「不」一起少，意思一樣。
    private static let doubled: Set<Character> = ["得", "能", "可", "會", "敢"]
    /// 句尾是「嗎」的反問。
    private static let rhetorical: [[Character]] = ["不是", "不覺得"].map { Array($0) }

    private let pair: [Int]
    private let hit: [Bool]
    /// 每個音的字。
    private let scriptText: [Character]
    private let heardText: [Character]
    /// 這個音和下一個音在稿子裡緊連著，中間沒有標點。
    private let isJoined: [Bool]
    private let heardKeys: [CaptionAligner.HeardKey]
    private let failed: [ClosedRange<Double>]
    private let scriptNumbers: [Placed]
    private let heardNumbers: [Placed]
    /// 稿子第幾個音在數字裡。
    private let isInNumber: [Bool]
    /// 聽到的第幾個音有配到稿子。
    private let isPaired: [Bool]

    init(script: [CaptionBreaker.Glyph], heard: CaptionAligner.Heard, pair: [Int], hit: [Bool],
         failed: [ClosedRange<Double>]) {
        let scriptText: [Character] = script.filter { $0.key != nil }.map { $0.character }
        var joined = [Bool](repeating: false, count: scriptText.count)
        for index in script.indices.dropLast() {
            if let key = script[index].key, script[index + 1].key != nil { joined[key] = true }
        }
        let numbers = Self.numbers(script, swapping: [:])
        var inside = [Bool](repeating: false, count: scriptText.count)
        for number in numbers {
            for key in number.keys { inside[key] = true }
        }
        // 和稿子同音、稿子那裡又不是數字的，用稿子的字：「是」聽成「四」不能當成講了四。
        // 前後要緊接著，不然「是11」聽成「是十一」，稿子的「是」可能配到「十」。
        let heardText: [Character] = heard.glyphs.filter { $0.key != nil }.map { $0.character }
        var swaps: [Int: Character] = [:]
        for index in pair.indices where hit[index] && !inside[index] {
            let other = pair[index]
            let left = index == 0 ? other == 0 : pair[index - 1] == other - 1
            let right = index + 1 == pair.count || inside[index + 1] || pair[index + 1] == other + 1
            // 前一個就是稿子的那個字，這個「十」是真的十（「開始是十九」的「是」配到了「十」）。
            let isShifted = other > 0 && heardText[other - 1] == scriptText[index]
            if left, right, !isShifted { swaps[other] = scriptText[index] }
        }
        self.pair = pair
        self.hit = hit
        self.failed = failed
        self.scriptText = scriptText
        self.heardText = heardText
        isJoined = joined
        heardKeys = heard.keys
        scriptNumbers = numbers
        heardNumbers = Self.numbers(heard.glyphs, swapping: swaps)
        isInNumber = inside
        var paired = [Bool](repeating: false, count: heard.keys.count)
        for other in pair where other >= 0 { paired[other] = true }
        isPaired = paired
    }

    private static func numbers(_ glyphs: [CaptionBreaker.Glyph], swapping: [Int: Character]) -> [Placed] {
        var text = ""
        // 第幾個 UTF-16 是哪一個字。
        var origin: [Int] = []
        for (index, glyph) in glyphs.enumerated() {
            var character = glyph.character
            if let key = glyph.key, let swap = swapping[key] { character = swap }
            text.append(character)
            for _ in 0..<character.utf16.count { origin.append(index) }
        }
        var result: [Placed] = []
        for number in SpokenNumbers.values(in: text) {
            guard !number.range.isEmpty, number.range.upperBound <= origin.count else { continue }
            let from = origin[number.range.lowerBound]
            let to = origin[number.range.upperBound - 1]
            let keys = glyphs[from...to].compactMap { $0.key }
            guard let first = keys.first, let last = keys.last else { continue }
            result.append(Placed(number: number, keys: first..<(last + 1)))
        }
        return result
    }

    func find(in row: Row) -> Found? {
        for index in scriptNumbers.indices where row.keys.contains(scriptNumbers[index].keys.lowerBound) {
            if let found = judge(index, row) { return found }
        }
        for key in row.keys {
            if let found = opposite(key) ?? dropped(key) ?? swapped(key) ?? added(key) { return found }
        }
        return nil
    }

    // MARK: 數字

    /// 稿子這個數字，拿前後兩個對上的字中間聽到的數字來比。
    private func judge(_ index: Int, _ row: Row) -> Found? {
        let mine = scriptNumbers[index]
        let before: Int? = (0..<mine.keys.lowerBound).last(where: { hit[$0] && !isInNumber[$0] })
        let after: Int? = (mine.keys.upperBound..<pair.count).first(where: { hit[$0] && !isInNumber[$0] })
        let from = before.map { $0 + 1 } ?? 0
        let to = after ?? pair.count
        // 同一處稿子連著幾個數字，要一起比。
        let block: [Int] = scriptNumbers.indices.filter {
            scriptNumbers[$0].keys.lowerBound >= from && scriptNumbers[$0].keys.upperBound <= to
        }
        let lower = max(before.map { pair[$0] + 1 } ?? 0, row.heard.lowerBound - Self.reach)
        let upper = min(after.map { pair[$0] } ?? heardKeys.count, row.heard.upperBound + Self.reach)
        guard lower < upper else { return unspoken(mine, row) }
        let nearby = heardNumbers.filter { $0.keys.overlaps(lower..<upper) }

        var rest = nearby
        var missing: [Int] = []
        var same: Placed?
        for number in block {
            if let found = rest.firstIndex(where: { $0.number.matches(scriptNumbers[number].number) }) {
                if number == index { same = rest[found] }
                rest.remove(at: found)
            } else {
                missing.append(number)
            }
        }
        let spoken = Set(mine.keys.map { pair[$0] }.filter { $0 >= 0 })
        let own: Placed? = rest.first { other in other.keys.contains { spoken.contains($0) } }
        if let same {
            // 前一次講對、重講的那次講錯：以對到的那次為準。
            guard let own, !own.number.matches(mine.number),
                  same.keys.upperBound + Self.retakeDistance <= own.keys.lowerBound else { return nil }
            return differs(mine, own)
        }
        guard !rest.isEmpty, let turn = missing.firstIndex(of: index) else { return nil }
        // 只是斷的地方不一樣：二零二五／三月、二零二五三月。個數一樣就不是斷法的問題（1.5 億和 15 億）。
        if block.count != nearby.count, spelling(block.map { scriptNumbers[$0] }) == spelling(nearby) { return nil }
        if missing.count != rest.count, spelling(missing.map { scriptNumbers[$0] }) == spelling(rest) { return nil }
        if block.count != nearby.count,
           SpokenNumbers.spelling(scriptText[from..<to]) == SpokenNumbers.spelling(heardText[lower..<upper]) {
            return nil
        }
        if isRunTogether(missing.map { scriptNumbers[$0] }, rest) { return nil }
        if let own { return differs(mine, own) }
        // 沒有和這個數字重疊，範圍又拉得很大，可能是別句的數字。
        guard upper - lower <= mine.keys.count + Self.reach else { return nil }
        return differs(mine, rest[min(turn, rest.count - 1)])
    }

    /// 「五到十分鐘」少聽一個「到」，辨識會寫成 510 分鐘。聽到的是國字（五百一十）就是真的講了那個數。
    private func isRunTogether(_ mine: [Placed], _ said: [Placed]) -> Bool {
        guard said.count < mine.count, said.allSatisfy({ isWrittenInFigures($0.number.text) }) else { return false }
        for index in mine.indices.dropFirst()
        where mine[index].keys.lowerBound - mine[index - 1].keys.upperBound > 1 { return false }
        guard let first = figures(mine), let second = figures(said) else { return false }
        return first == second
    }

    private func isWrittenInFigures(_ text: String) -> Bool {
        text.allSatisfy { $0.isASCII || $0 == "趴" || $0 == "％" }
    }

    /// 寫成阿拉伯數字接起來。有小數就不接。
    private func figures(_ numbers: [Placed]) -> String? {
        var result = ""
        for placed in numbers {
            guard placed.number.denominator == placed.number.scale else { return nil }
            result += placed.number.numerator.description
        }
        return result
    }

    private func spelling(_ numbers: [Placed]) -> String {
        numbers.map { $0.number.spelling }.joined()
    }

    private func differs(_ mine: Placed, _ other: Placed) -> Found? {
        if mine.number.isWeak || other.number.isWeak {
            // 「一個」常常只是順口，位置要剛好、後面的字也對上才算。
            let next = mine.keys.upperBound
            guard mine.keys.count == 1, other.keys.count == 1, pair[mine.keys.lowerBound] == other.keys.lowerBound,
                  next < pair.count, hit[next], pair[next] == other.keys.upperBound else { return nil }
        }
        // 貼著辨識失敗的地方，聽到的數字可能只有半個。
        let first = other.keys.lowerBound
        let last = other.keys.upperBound - 1
        let before = first > 0 ? heardKeys[first - 1].end : 0
        let after = last + 1 < heardKeys.count ? heardKeys[last + 1].start : Double.greatestFiniteMagnitude
        if fails(before, heardKeys[first].start) || fails(heardKeys[last].end, after) { return nil }
        return Found(kind: .number, script: mine.number.text, heard: other.number.text,
                     time: heardKeys[first].start)
    }

    /// 稿子的數字整個沒有聲音，同一行其他的字都對上，前後又緊接著：多半是漏講了。
    private func unspoken(_ mine: Placed, _ row: Row) -> Found? {
        let keys = mine.keys
        guard !mine.number.isWeak, keys.allSatisfy({ pair[$0] < 0 }) else { return nil }
        // 「一公尺七三」聽成 1.73 公尺，七三在公尺前面講了。
        if heardNumbers.contains(where: { $0.keys.overlaps(row.heard) && mine.number.isReread(as: $0.number) }) { return nil }
        let left = keys.lowerBound - 1
        let right = keys.upperBound
        // F16、B2B 這種和英文黏在一起的，辨識的寫法太多。
        if left >= 0, isJoined[left], isLetter(scriptText[left]) { return nil }
        if right < scriptText.count, isJoined[right - 1], isLetter(scriptText[right]) { return nil }
        let others = row.keys.filter { !keys.contains($0) }
        guard others.count >= 2, others.allSatisfy({ hit[$0] }) else { return nil }

        var time = 0.0
        if left >= 0, right < pair.count {
            guard hit[left], hit[right], pair[right] == pair[left] + 1,
                  !fails(heardKeys[pair[left]].end, heardKeys[pair[right]].start) else { return nil }
            time = heardKeys[pair[right]].start
        } else if left >= 0 {
            // 整段的結尾：後面要真的沒有別的聲音。
            guard hit[left], pair[left] == heardKeys.count - 1,
                  !fails(heardKeys[pair[left]].end, .greatestFiniteMagnitude) else { return nil }
            time = heardKeys[pair[left]].start
        } else {
            guard right < pair.count, hit[right], pair[right] == 0,
                  !fails(0, heardKeys[pair[right]].start) else { return nil }
            time = heardKeys[pair[right]].start
        }
        return Found(kind: .number, script: mine.number.text, heard: nil, time: time)
    }

    private func isLetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }

    /// 這段時間碰到辨識失敗，不知道有沒有講。
    private func fails(_ lower: Double, _ upper: Double) -> Bool {
        failed.contains { min(upper, $0.upperBound) - max(lower, $0.lowerBound) >= 0.3 }
    }

    // MARK: 一字之差

    /// 兩邊成對的字是一組相反字。
    private func opposite(_ key: Int) -> Found? {
        let other = pair[key]
        guard other >= 0 else { return nil }
        let mine = scriptText[key]
        let said = heardText[other]
        guard Self.opposites[mine]?.contains(said) == true else { return nil }
        // 「多少」「買賣」兩個字都在，配錯邊而已。
        if isBeside(scriptText, key, said) || isBeside(heardText, other, mine) { return nil }
        // 「增加」講成「減少」，兩個字都不一樣，旁邊那個一起帶走。
        var lower = key
        var upper = key + 1
        if lower > 0, !hit[lower - 1], pair[lower - 1] >= 0, pair[lower - 1] == other - 1 {
            lower -= 1
        } else if upper < pair.count, !hit[upper], pair[upper] == other + 1 {
            upper += 1
        }
        guard isHeld(lower, upper) else { return nil }
        return Found(kind: .word, script: String(scriptText[lower..<upper]),
                     heard: String(heardText[pair[lower]...pair[upper - 1]]), time: heardKeys[pair[lower]].start)
    }

    /// 前後都是對上的字。剛好在一個小段落的頭或尾，另一邊要有兩個。
    private func isHeld(_ lower: Int, _ upper: Int) -> Bool {
        let first = pair[lower]
        let last = pair[upper - 1]
        let left = lower > 0 && hit[lower - 1] && pair[lower - 1] == first - 1
        let right = upper < pair.count && hit[upper] && pair[upper] == last + 1
        if left && right { return true }
        if left, upper == pair.count || !isJoined[upper - 1] {
            return lower > 1 && hit[lower - 2] && pair[lower - 2] == first - 2
        }
        if right, lower == 0 || !isJoined[lower - 1] {
            return upper + 1 < pair.count && hit[upper + 1] && pair[upper + 1] == last + 2
        }
        return false
    }

    private func isBeside(_ text: [Character], _ index: Int, _ character: Character) -> Bool {
        (index > 0 && text[index - 1] == character) || (index + 1 < text.count && text[index + 1] == character)
    }

    /// 這個字在否定。「有沒有」「是不是」不算，結巴重複的也不算。
    static func isNegation(_ text: [Character], _ index: Int) -> Bool {
        let character = text[index]
        guard negations.contains(character) else { return false }
        let before: Character? = index > 0 ? text[index - 1] : nil
        let after: Character? = index + 1 < text.count ? text[index + 1] : nil
        if before == character || after == character { return false }
        if let before, before == after { return false }
        if isFiller(text, index) { return false }
        for word in notNegations {
            for (offset, letter) in word.enumerated() where letter == character {
                let start = index - offset
                guard start >= 0, start + word.count <= text.count else { continue }
                if Array(text[start..<(start + word.count)]) == word { return false }
            }
        }
        return true
    }

    /// 語氣用的「不、沒」，要看前後的字才知道。
    private static func isFiller(_ text: [Character], _ index: Int) -> Bool {
        func at(_ offset: Int) -> Character? {
            let place = index + offset
            return place >= 0 && place < text.count ? text[place] : nil
        }
        if text[index] == "不" {
            if at(1) == "就" {
                // 「再不就來不及」「要不就算了」的「不」不能少。
                let heads: [Character] = ["再", "要", "若", "還"]
                if let before = at(-1), heads.contains(before) { return false }
                guard let next = at(2) else { return true }
                return !afterNotJust.contains(next)
            }
            // 何不試試。如何不、為何不、任何不 是另一回事。
            if at(-1) == "何" {
                let heads: [Character] = ["如", "為", "任", "奈"]
                guard let before = at(-2) else { return true }
                return !heads.contains(before)
            }
        }
        if text[index] == "沒", at(-1) == "點", at(-2) == "差" || (at(-2) == "一" && at(-3) == "差"), let next = at(1) {
            return mishaps.contains(next)
        }
        return false
    }

    /// 少掉或多出來的這幾個字不改變意思。`left`、`right` 是稿子裡前後緊接著的音。
    private func isHarmless(_ words: [Character], before left: Int, after right: Int) -> Bool {
        // 稿子從這裡到下一個標點。
        var clause: [Character] = []
        for key in right..<scriptText.count {
            clause.append(scriptText[key])
            if !isJoined[key] { break }
        }
        let phrase: [Character] = words + clause
        if clause.count <= 14, clause.last == "嗎", Self.rhetorical.contains(where: { phrase.starts(with: $0) }) { return true }
        // 「還沒開始之前」就是「開始之前」。
        guard words.contains("沒") || words.contains("未") else { return false }
        let heads: [Character] = ["還", "尚", "在"]
        guard words.contains("還") || words.contains("尚") || heads.contains(scriptText[left]) else { return false }
        for index in clause.indices.prefix(6) where index + 1 < clause.count {
            guard clause[index] == "之" || clause[index] == "以", clause[index + 1] == "前" else { continue }
            // 「還沒去過之前那家店」的「之前」跟後面是一起的。
            let next: Character? = index + 2 < clause.count ? clause[index + 2] : nil
            return next != "的" && next != "那" && next != "這"
        }
        return false
    }

    /// 稿子的「不得不」兩個「不」都沒講。
    private func isDoubleDropped(_ key: Int) -> Bool {
        for other in [key - 2, key + 2] where other >= 0 && other < pair.count {
            let first = min(key, other)
            if pair[other] < 0, hit[first + 1], isJoined[first], isJoined[first + 1],
               Self.doubled.contains(scriptText[first + 1]), Self.isNegation(scriptText, other) { return true }
        }
        return false
    }

    /// 聽到的「不得不」比稿子多兩個「不」。`place` 是聽到的第幾個音。
    private func isDoubleAdded(_ place: Int) -> Bool {
        for other in [place - 2, place + 2] where other >= 0 && other < heardText.count {
            let middle = min(place, other) + 1
            if !isPaired[other], Self.doubled.contains(heardText[middle]), Self.isNegation(heardText, other) { return true }
        }
        return false
    }

    /// 稿子有「不」，前後的字緊接著對上，中間沒聽到。
    private func dropped(_ key: Int) -> Found? {
        guard pair[key] < 0, isJoined[key], Self.isNegation(scriptText, key), !isDoubleDropped(key) else { return nil }
        // 「沒有漲」漏成「漲」，一次少兩個字。
        let candidates: [Range<Int>] = [key..<(key + 1), key..<(key + 2), max(0, key - 1)..<(key + 1)]
        for gone in candidates {
            let left = gone.lowerBound - 1
            let right = gone.upperBound
            guard left >= 0, right < pair.count, gone.allSatisfy({ pair[$0] < 0 && isJoined[$0] }),
                  hit[left], hit[right], pair[right] == pair[left] + 1,
                  !fails(heardKeys[pair[left]].end, heardKeys[pair[right]].start) else { continue }
            if isHarmless(Array(scriptText[gone]), before: left, after: right) { return nil }
            return Found(kind: .word, script: String(scriptText[gone.lowerBound...right]),
                         heard: String(heardText[pair[right]]), time: heardKeys[pair[right]].start)
        }
        return nil
    }

    /// 同一個位置，一邊是「不」、另一邊是別的字。同音的不算，辨識常挑錯字。
    private func swapped(_ key: Int) -> Found? {
        let other = pair[key]
        guard other >= 0, !hit[key] else { return nil }
        // 「不行」和「沒行」都是否定。
        guard Self.negations.contains(scriptText[key]) != Self.negations.contains(heardText[other]),
              Self.isNegation(scriptText, key) || Self.isNegation(heardText, other) else { return nil }
        guard key > 0, key + 1 < pair.count, isJoined[key], hit[key - 1], hit[key + 1],
              pair[key - 1] == other - 1, pair[key + 1] == other + 1 else { return nil }
        return Found(kind: .word, script: String(scriptText[key...(key + 1)]),
                     heard: String(heardText[other...(other + 1)]), time: heardKeys[other].start)
    }

    /// 稿子緊連著的兩個字，聽到的中間多了「不」。
    private func added(_ key: Int) -> Found? {
        guard key + 1 < pair.count, isJoined[key], hit[key], hit[key + 1] else { return nil }
        let first = pair[key] + 1
        let next = pair[key + 1]
        guard next - first == 1 || next - first == 2,
              let place = (first..<next).first(where: { Self.isNegation(heardText, $0) }), !isDoubleAdded(place),
              !isHarmless(Array(heardText[first..<next]), before: key, after: key + 1) else { return nil }
        return Found(kind: .word, script: String(scriptText[key + 1]), heard: String(heardText[first...next]),
                     time: heardKeys[first].start)
    }
}
