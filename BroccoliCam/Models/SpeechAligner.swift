import Foundation

/// 語音跟隨的對位：給它「剛聽到的音」，它回答唸到稿子的第幾個音。
/// 不碰語音辨識、不碰畫面，只有字串比對。
struct SpeechAligner {
    enum Move {
        case none
        case forward
        case backward
    }

    /// 拿最後幾個音來比。
    private static let tailLength = 8
    /// 往前最多找多遠。
    private static let forwardReach = 35
    /// 往回最多找多遠。
    private static let backReach = 40
    /// 往回要對上幾個音，而且要比「還在原地或往前」多對上幾個音才算。
    private static let backNeeded = 6
    private static let backMargin = 2
    /// 退不到這麼多個音就不退，等他唸過來就好。
    private static let backMinimum = 4
    /// 指定過位置之後，往前唸了這麼多個音，才准退到那個位置之前。
    private static let anchorRelease = 20

    private let keys: [String]
    /// 下一個要唸的音在 keys 裡的位置，唸完時等於 keys.count。
    private(set) var position: Int
    /// 最近一次指定的位置（開始、跳轉）。剛跳過去時嘴巴可能還在唸舊的，不能馬上被拉回去。
    private var anchor: Int
    private var lastTail: [String] = []
    /// 上一次聽到的內容指向這裡要往回退，還在等第二次確認。
    private var pendingBack: Int?
    /// 從哪裡退回來的。退錯了要回得去。
    private var retreatedFrom: Int?

    init(keys: [String], position: Int = 0) {
        self.keys = keys
        let clamped = min(max(0, position), keys.count)
        self.position = clamped
        self.anchor = clamped
    }

    /// 直接指定下一個要唸的音，之前聽到的都不算。
    mutating func seek(to target: Int) {
        position = min(max(0, target), keys.count)
        anchor = position
        lastTail = []
        pendingBack = nil
        retreatedFrom = nil
    }

    /// spoken 是到目前為止聽到的音（只會用最後幾個）。
    mutating func hear(_ spoken: [String]) -> Move {
        let tail = Array(spoken.suffix(Self.tailLength))
        // 同一句結果常常連送兩次，重複的不算新的證據。
        guard tail.count >= 2, !keys.isEmpty, tail != lastTail else { return .none }
        lastTail = tail

        let ahead = bestAhead(tail)
        if let back = backTarget(tail, aheadScore: ahead.score) {
            guard let first = pendingBack, back >= first - 1, back <= first + Self.tailLength else {
                pendingBack = back
                return .none
            }
            pendingBack = nil
            retreatedFrom = max(retreatedFrom ?? 0, position)
            anchor = 0
            position = back
            return .backward
        }
        pendingBack = nil

        guard let next = forwardTarget(ahead, tailCount: tail.count) else { return .none }
        position = next
        if let origin = retreatedFrom, position >= origin {
            retreatedFrom = nil
        }
        return .forward
    }

    // MARK: - 往前

    private struct Match {
        /// 對上的最後一個音在 keys 裡的位置，沒有就是 -1。
        var end = -1
        var score = 0
        var distance = Int.max
    }

    private func bestAhead(_ tail: [String]) -> Match {
        var match = Match()
        let lower = max(0, position - 3)
        var reach = position + Self.forwardReach
        if let origin = retreatedFrom {
            // 剛退回來，也許退錯了：看得到退之前的位置，不然會卡在後面。
            reach = max(reach, min(origin + Self.tailLength, position + Self.backReach + Self.tailLength))
        }
        let upper = min(keys.count - 1, reach)
        guard lower <= upper else { return match }
        for end in lower...upper {
            let score = self.score(tail, endingAt: end)
            let distance = abs(end + 1 - position)
            if score > match.score || (score == match.score && distance < match.distance) {
                match = Match(end: end, score: score, distance: distance)
            }
        }
        return match
    }

    private func forwardTarget(_ match: Match, tailCount: Int) -> Int? {
        guard match.end >= 0 else { return nil }
        let next = match.end + 1
        guard next > position else { return nil }
        let jump = next - position
        // 跳得越遠，要對上越多字才算數，避免稿子裡重複的詞把位置帶走。
        let needed: Int
        if tailCount < 3 {
            needed = tailCount
            guard jump <= 4 else { return nil }
        } else if match.end > position + Self.forwardReach {
            needed = Self.backNeeded
        } else if jump > 15 {
            needed = 5
        } else {
            needed = 3
        }
        // 平常的距離，聽到的音比門檻少時全對就算；超出平常距離的沒得商量。
        if match.end > position + Self.forwardReach {
            guard match.score >= needed else { return nil }
        } else {
            guard match.score >= min(needed, tailCount) else { return nil }
        }
        return next
    }

    // MARK: - 往回

    /// 講錯退回去重唸：回傳要退到的位置，沒有就是 nil。
    private func backTarget(_ tail: [String], aheadScore: Int) -> Int? {
        guard tail.count >= Self.backNeeded else { return nil }
        let floor = position - anchor < Self.anchorRelease ? anchor : 0
        let lower = max(1, floor, position - Self.backReach)
        let upper = position - Self.backMinimum
        guard lower <= upper else { return nil }

        var best = -1
        var bestScore = 0
        for next in lower...upper {
            let score = self.score(tail, endingAt: next - 1)
            // 一樣像就選離現在近的。
            if score >= bestScore {
                bestScore = score
                best = next
            }
        }
        guard best > 0, bestScore >= Self.backNeeded, bestScore >= aheadScore + Self.backMargin else { return nil }
        return best
    }

    /// tail 的最後一個音對到 keys[end]，一路往回比，總共對上幾個。
    private func score(_ tail: [String], endingAt end: Int) -> Int {
        var score = 0
        for back in 0..<tail.count {
            let index = end - back
            if index < 0 { break }
            if keys[index] == tail[tail.count - 1 - back] {
                score += 1
            }
        }
        return score
    }
}
