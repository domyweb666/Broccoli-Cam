import Foundation

/// 檢查出來、要給人聽一下的一處。
struct TakeIssue: Identifiable, Equatable {
    /// 數字小的先提。
    enum Kind: Int {
        case number
        case missing
        case word
    }

    let id = UUID()
    let kind: Kind
    /// 稿子寫的。
    var script: String
    /// 聽到的。沒聽到是 nil。
    let heard: String?
    /// 影片檔的第幾秒。
    let time: Double

    var text: String {
        switch kind {
        case .missing:
            return "漏講「\(script)」"
        case .number, .word:
            guard let heard else { return "稿子 \(script)，沒聽到" }
            return "稿子 \(script)，聽到 \(heard)"
        }
    }
}

/// 一段影片檢查完的結果。
struct TakeReport: Equatable {
    /// 照數字、漏講、一字之差排好。
    var issues: [TakeIssue] = []
    /// 有地方沒檢查到，不能說沒問題。
    var isIncomplete = false
    /// 只對上一部分、說不出哪裡不一樣的有幾句。
    var unclear = 0
    /// 幾乎沒聽到，這份聽寫不可以留著用。
    var heardLittle = false

    var isClean: Bool {
        issues.isEmpty && !isIncomplete && unclear == 0
    }

    /// 拿稿子對聽到的字。會花一點時間，不要在主執行緒做。
    /// maxChars 和字幕的一行一樣長，抓到的才會和校對頁一致。
    init(script: String, hearing: TakeHearing, maxChars: Int) {
        let from: Double = hearing.from
        let words: [CaptionWord] = hearing.words.map { word in
            CaptionWord(text: word.text, start: word.start - from, end: word.end - from)
        }
        let failed: [ClosedRange<Double>] = hearing.failed.map { range in
            (range.lowerBound - from)...(range.upperBound - from)
        }
        let duration: Double = max(0, hearing.to - from)
        let outcome = CaptionAligner.lines(script: script, words: words, failed: failed, duration: duration,
                                           maxChars: maxChars, boundaries: CaptionBreaker.wordBoundaries)
        heardLittle = outcome.heardLittle(words: words.count, duration: duration)
        var found: [TakeIssue] = []
        var wasMissing = false
        for line in outcome.lines {
            if line.status == .missing {
                let text: String = line.scriptText ?? line.text
                // 連著漏掉的幾行是同一處。
                if wasMissing, !found.isEmpty {
                    found[found.count - 1].script += text
                } else {
                    found.append(TakeIssue(kind: .missing, script: text, heard: nil, time: line.start + from))
                }
                wasMissing = true
                continue
            }
            wasMissing = false
            guard let doubt = line.doubt else {
                if line.status == .uncertain { unclear += 1 }
                continue
            }
            found.append(TakeIssue(kind: doubt == .number ? .number : .word, script: line.doubtScript ?? line.text,
                                   heard: line.doubtHeard, time: (line.doubtTime ?? line.start) + from))
        }
        issues = found.sorted { first, second in
            if first.kind != second.kind { return first.kind.rawValue < second.kind.rawValue }
            return first.time < second.time
        }
        isIncomplete = outcome.isSparse || !failed.isEmpty
            || outcome.lines.contains { $0.status == .unrecognized }
    }

    func count(_ kind: TakeIssue.Kind) -> Int {
        issues.filter { $0.kind == kind }.count
    }
}

/// 一段影片的檢查。結果跟著檔案走，不跟著第幾段走。
struct TakeCheck: Equatable {
    enum State: Equatable {
        /// 排隊中，或被錄影打斷、等著重來。
        case waiting
        case checking
        case done(TakeReport)
        /// 沒檢查成。
        case failed
    }

    let script: String
    /// 字幕一行幾個字。
    var maxChars: Int
    var state: State = .waiting
    var hearing: TakeHearing?
    /// 再試之前查出來的。還沒有新的結果就先看這份。
    var earlier: TakeReport?
    /// 沒檢查到之後再試過幾次。
    var retries = 0

    var report: TakeReport? {
        if case .done(let report) = state { return report }
        return earlier
    }

    var isFinished: Bool {
        switch state {
        case .waiting, .checking: return false
        case .done, .failed: return true
        }
    }

    /// 一部分或全部沒檢查到。
    var isUnchecked: Bool {
        switch state {
        // 再試還沒有結果之前，仍然是沒檢查到。
        case .waiting, .checking: return retries > 0
        case .done(let report): return report.isIncomplete
        case .failed: return true
        }
    }
}

/// 畫面上的一段影片和它的檢查。title 是「第 2 段」，只有一支的時候是 nil。
struct TakeCheckEntry: Identifiable {
    let title: String?
    let url: URL
    let check: TakeCheck

    var id: String { url.lastPathComponent }
    var issues: [TakeIssue] { check.report?.issues ?? [] }
}

/// 一段或好幾段的檢查，整理成要顯示的東西。
struct TakeCheckSummary {
    struct Row: Identifiable {
        let entry: TakeCheckEntry
        let issue: TakeIssue

        var id: UUID { issue.id }
        var text: String {
            guard let title = entry.title else { return issue.text }
            return title + " " + issue.text
        }
    }

    let rows: [Row]
    let isChecking: Bool
    /// 全部檢查完，沒有任何一處要看。
    let isClean: Bool
    /// 沒檢查到、沒聽清楚的說明。
    let note: String?
    /// 有幾段沒有稿子、沒得檢查。有的話不可以整支寫沒問題。
    let skipped: String?

    /// unscripted 是 entries 以外、沒有稿子的段數。
    init(_ entries: [TakeCheckEntry], unscripted: Int = 0) {
        var all: [Row] = []
        for entry in entries {
            for issue in entry.issues { all.append(Row(entry: entry, issue: issue)) }
        }
        // 同一種的照段落、時間的先後。
        let ordered = all.enumerated().sorted { first, second in
            let left: Int = first.element.issue.kind.rawValue
            let right: Int = second.element.issue.kind.rawValue
            return left == right ? first.offset < second.offset : left < right
        }
        rows = ordered.map { $0.element }
        isChecking = entries.contains { !$0.check.isFinished }
        let clean: Bool = !entries.isEmpty && entries.allSatisfy { $0.check.report?.isClean ?? false }
        isClean = clean

        var parts: [String] = []
        let unchecked: [TakeCheckEntry] = entries.filter { $0.check.isUnchecked }
        let titles: [String] = unchecked.compactMap { $0.title }
        if !titles.isEmpty {
            let names: String = titles.count <= 2 ? titles.joined(separator: "、") : "有 \(titles.count) 段"
            parts.append(names + "沒檢查到")
        } else if !unchecked.isEmpty {
            parts.append(all.isEmpty ? "這段沒檢查到" : "有一部分沒檢查到")
        }
        let unclear: Int = entries.reduce(0) { $0 + ($1.check.report?.unclear ?? 0) }
        if unclear > 0 { parts.append("有 \(unclear) 句沒聽清楚") }
        note = parts.isEmpty ? nil : parts.joined(separator: "，")

        if unscripted > 0 {
            let rest: String = "\(unscripted) 段沒有稿子，沒檢查"
            let checked: [String] = entries.compactMap { $0.title }
            let names: String = checked.count <= 2 ? checked.joined(separator: "、") : "\(checked.count) 段"
            skipped = clean ? "\(names)沒問題，\(rest)" : rest
        } else {
            skipped = nil
        }
    }
}

/// 分段列上的「第 2 段有 1 處」。
struct TakeCheckFlag: Identifiable {
    let index: Int
    let count: Int

    var id: Int { index }
    var text: String { "第 \(index + 1) 段有 \(count) 處" }
}

/// 要打開來聽的一段。
struct TakePlayback: Identifiable {
    let id = UUID()
    let url: URL
    let title: String?
    let issues: [TakeIssue]
    /// 那一處在第幾秒，會從前面一點點開始播。
    let time: Double

    var file: String { url.lastPathComponent }
}
