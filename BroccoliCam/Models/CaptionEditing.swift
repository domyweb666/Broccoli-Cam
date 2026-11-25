import Foundation

/// 校對頁改句子的規則：拆、併、挪、平移、顯示、取代。只有資料，不碰畫面和檔案。
enum CaptionEditing {
    /// 一句最短留多久（秒）。
    static let shortest = 0.2
    /// 重新顯示一句沒有時間的字幕，給它這麼長。
    static let comfortable = 0.7

    /// 照時間排好。時間一樣就維持原本的先後。
    static func sorted(_ lines: [CaptionLine]) -> [CaptionLine] {
        let ordered = lines.enumerated().sorted { first, second in
            if first.element.start != second.element.start {
                return first.element.start < second.element.start
            }
            return first.offset < second.offset
        }
        return ordered.map(\.element)
    }

    /// 辨識結果先整理一次：時間不是數字的、跑出影片外的拉回來。
    static func cleaned(_ lines: [CaptionLine], duration: Double) -> [CaptionLine] {
        let limit = duration > 0 ? duration : Double.greatestFiniteMagnitude
        let fixed: [CaptionLine] = lines.map { line in
            var result = line
            result.start = min(max(0, line.start.isFinite ? line.start : 0), limit)
            result.end = min(max(result.start, line.end.isFinite ? line.end : result.start), limit)
            result.words = line.words.filter { $0.start.isFinite && $0.end.isFinite }
            if let time = line.doubtTime, !time.isFinite { result.doubtTime = nil }
            return result
        }
        return sorted(fixed)
    }

    /// 在第幾個字元（UTF-16 位置）拆成兩句。拆不開就回 nil。
    static func split(_ line: CaptionLine, atUTF16 cursor: Int) -> (CaptionLine, CaptionLine)? {
        let text = line.text as NSString
        guard cursor > 0, cursor < text.length else { return nil }
        // 不切在一個字（例如表情符號）的中間。
        let safe = text.rangeOfComposedCharacterSequence(at: cursor).location
        let head = text.substring(to: safe).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = text.substring(from: safe).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty, !tail.isEmpty else { return nil }

        let share = weight(of: head) / max(1, weight(of: head) + weight(of: tail))
        let cut = cutTime(of: line, share: share)

        var first = line
        first.text = head
        first.end = cut
        first.words = line.words.filter { ($0.start + $0.end) / 2 < cut }
        // 整句的「稿子寫的／聽到的」拆開之後對不起來，不再給選。
        first.scriptText = nil
        first.heardText = nil

        var second = line
        second.id = UUID()
        second.text = tail
        second.start = cut
        second.words = line.words.filter { ($0.start + $0.end) / 2 >= cut }
        second.scriptText = nil
        second.heardText = nil
        // 哪裡不一樣只跟著那個字所在的那半句。
        if let time = line.doubtTime, time < cut {
            second.clearDoubt()
        } else {
            first.clearDoubt()
        }
        return (first, second)
    }

    /// 有詞的時間就找最近的詞界，沒有就照字數比例。
    private static func cutTime(of line: CaptionLine, share: Double) -> Double {
        let length = max(0, line.end - line.start)
        let words = line.words.sorted { $0.start < $1.start }
        let total = words.reduce(0.0) { $0 + weight(of: $1.text) }
        var cut = line.start + length * share
        if words.count > 1, total > 0 {
            var passed = 0.0
            var best = Double.greatestFiniteMagnitude
            for index in 0..<(words.count - 1) {
                passed += weight(of: words[index].text)
                let distance = abs(passed / total - share)
                if distance < best {
                    best = distance
                    cut = (words[index].end + words[index + 1].start) / 2
                }
            }
        }
        let margin = min(shortest, length / 2)
        return min(max(cut, line.start + margin), line.end - margin)
    }

    /// 併成一句。任何一句還沒確認，併完就還要看。
    static func merged(_ first: CaptionLine, _ second: CaptionLine) -> CaptionLine {
        var result = first
        result.text = joined(first.text, second.text)
        result.start = min(first.start, second.start)
        result.end = max(first.end, second.end)
        result.words = (first.words + second.words).sorted { $0.start < $1.start }
        if let a = first.scriptText, let b = second.scriptText {
            result.scriptText = joined(a, b)
        } else {
            result.scriptText = nil
        }
        if let a = first.heardText, let b = second.heardText {
            result.heardText = joined(a, b)
        } else {
            result.heardText = nil
        }
        if first.blocksBurning {
            result.status = first.status
        } else if second.blocksBurning {
            result.status = second.status
        }
        result.isConfirmed = !(first.blocksBurning || second.blocksBurning)
        result.isHidden = false
        // 還沒看過的原因留著，看過的不用。
        if !(first.blocksBurning && first.doubt != nil) {
            result.clearDoubt()
            if second.blocksBurning {
                result.doubt = second.doubt
                result.doubtScript = second.doubtScript
                result.doubtHeard = second.doubtHeard
                result.doubtTime = second.doubtTime
            }
        }
        return result
    }

    private static func joined(_ first: String, _ second: String) -> String {
        guard let left = first.last, let right = second.first else { return first + second }
        // 英文字接英文字才需要空格。
        let needsSpace = left.isASCII && right.isASCII && (left.isLetter || left.isNumber)
            && (right.isLetter || right.isNumber)
        return needsSpace ? first + " " + second : first + second
    }

    /// 這一句下面那句（照時間、會燒的）。
    static func next(after id: UUID, in lines: [CaptionLine]) -> CaptionLine? {
        let ordered = sorted(lines)
        guard let index = ordered.firstIndex(where: { $0.id == id }), index + 1 < ordered.count else { return nil }
        return ordered[(index + 1)...].first { !$0.isHidden }
    }

    /// 整句挪早或挪晚。撞到旁邊那句就把旁邊那句縮短，縮到不能再短為止。
    /// 不燒的句子只移自己：它本來就可以和別句重疊，動到旁邊會把對好的時間弄歪。
    static func nudge(_ id: UUID, by delta: Double, in lines: [CaptionLine], duration: Double) -> [CaptionLine] {
        var result = sorted(lines)
        guard let index = result.firstIndex(where: { $0.id == id }) else { return lines }
        let length = result[index].end - result[index].start
        let limit = duration > 0 ? duration : Double.greatestFiniteMagnitude
        var start = min(max(0, result[index].start + delta), max(0, limit - length))

        let isHidden = result[index].isHidden
        if !isHidden, delta < 0, let before = result[..<index].lastIndex(where: { !$0.isHidden }) {
            let floor = result[before].start + shortest
            // 本來就疊得比這個還前面就不硬推回去。
            start = max(start, min(floor, result[index].start))
            if result[before].end > start { result[before].end = max(result[before].start, start) }
        }
        if !isHidden, delta > 0, let after = result[(index + 1)...].firstIndex(where: { !$0.isHidden }) {
            let ceiling = result[after].end - shortest - length
            start = min(start, max(ceiling, result[index].start))
            if result[after].start < start + length { result[after].start = min(result[after].end, start + length) }
        }
        let moved = start - result[index].start
        result[index].start = start
        result[index].end = start + length
        result[index].doubtTime = result[index].doubtTime.map { $0 + moved }
        result[index].words = result[index].words.map { word in
            CaptionWord(text: word.text, start: word.start + moved, end: word.end + moved)
        }
        return sorted(result)
    }

    /// 整支前後平移，跑出影片外的部分切掉。
    static func shifted(_ lines: [CaptionLine], by offset: Double, duration: Double) -> [CaptionLine] {
        let limit = duration > 0 ? duration : Double.greatestFiniteMagnitude
        return lines.map { line in
            var result = line
            result.start = min(max(0, line.start + offset), limit)
            result.end = min(max(0, line.end + offset), limit)
            result.doubtTime = line.doubtTime.map { $0 + offset }
            result.words = line.words.map { word in
                CaptionWord(text: word.text, start: word.start + offset, end: word.end + offset)
            }
            return result
        }
    }

    /// 顯示或隱藏。使用者動手選了就算看過。
    static func toggledHidden(_ id: UUID, in lines: [CaptionLine], duration: Double) -> [CaptionLine] {
        var result = sorted(lines)
        guard let index = result.firstIndex(where: { $0.id == id }) else { return lines }
        result[index].isHidden.toggle()
        result[index].isConfirmed = true
        // 藏著的句子時間是猜的，可以和別句重疊；要燒了就得有自己的位置，不然兩句只看得到一句。
        if !result[index].isHidden {
            settle(&result, index, duration: duration)
            keepOrder(&result)
        }
        return sorted(result)
    }

    /// 在前後兩句會燒的中間找位置，找不到就請下一句往後讓，再不行請上一句早點收。
    private static func settle(_ lines: inout [CaptionLine], _ index: Int, duration: Double) {
        let limit = duration > 0 ? duration : Double.greatestFiniteMagnitude
        let line = lines[index]
        let length = line.end - line.start
        let before = latestEnd(lines, before: index)
        let after = lines[(index + 1)...].firstIndex(where: { !$0.isHidden })
        var floor = 0.0
        if let before { floor = min(lines[before].end, limit) }
        var ceiling = limit
        if let after { ceiling = lines[after].start }
        // 沒有擋到誰、自己也看得到，就不動。
        if length >= shortest, line.start >= floor - 0.01, line.end <= ceiling + 0.01 { return }

        // 上一句講完之後補空隙的尾巴可以還出來，先用那裡，不動到講話的時間。
        if let before, ceiling - floor < comfortable {
            let previous = lines[before]
            let spoken = previous.words.map({ $0.end }).max() ?? previous.end
            let kept = previous.start + min(comfortable, max(0, previous.end - previous.start))
            floor = min(floor, max(kept, max(spoken, ceiling - comfortable)))
        }
        let gap = ceiling - floor
        if gap >= shortest {
            let room = min(max(comfortable, length), gap)
            let start = min(max(line.start, floor), ceiling - room)
            put(&lines, index, start, start + room)
            if let before { cut(&lines, before, at: start) }
            return
        }
        // 兩句平分，誰都不會短到看不見。
        if let after {
            let room = min(comfortable, (lines[after].end - floor) / 2)
            if room >= shortest {
                put(&lines, index, floor, floor + room)
                put(&lines, after, floor + room, lines[after].end)
                if let before { cut(&lines, before, at: floor) }
                return
            }
        }
        if let before {
            let room = min(comfortable, (ceiling - lines[before].start) / 2)
            if room >= shortest {
                put(&lines, index, ceiling - room, ceiling)
                cut(&lines, before, at: ceiling - room)
                return
            }
        }
        // 前後都短得讓不出來，只好一路往後推。
        put(&lines, index, floor, floor + shortest)
        var shown = lines.filter { !$0.isHidden }
        CaptionAligner.tidy(&shown, duration: limit, least: shortest, closesGaps: false)
        for moved in shown {
            if let place = lines.firstIndex(where: { $0.id == moved.id }) { lines[place] = moved }
        }
    }

    /// 前面會燒的句子裡，最晚結束的那一句。
    private static func latestEnd(_ lines: [CaptionLine], before index: Int) -> Int? {
        var found: Int?
        for position in 0..<index where !lines[position].isHidden {
            if let known = found, lines[known].end > lines[position].end { continue }
            found = position
        }
        return found
    }

    private static func put(_ lines: inout [CaptionLine], _ index: Int, _ start: Double, _ end: Double) {
        lines[index].start = start
        lines[index].end = end
        CaptionAligner.fitWords(&lines[index])
    }

    private static func cut(_ lines: inout [CaptionLine], _ index: Int, at time: Double) {
        guard lines[index].end > time else { return }
        put(&lines, index, lines[index].start, max(lines[index].start, time))
    }

    /// 挪完之後，還藏著的句子跟著收進前後兩句會燒的開頭中間。順序要留著，之後再叫出來才知道放哪。
    private static func keepOrder(_ lines: inout [CaptionLine]) {
        var floors: [Double] = []
        var floor = 0.0
        for line in lines {
            floors.append(floor)
            if !line.isHidden { floor = max(floor, line.start) }
        }
        var ceiling = Double.greatestFiniteMagnitude
        for index in lines.indices.reversed() {
            guard lines[index].isHidden else {
                ceiling = min(ceiling, lines[index].start)
                continue
            }
            let moved = max(floors[index], min(ceiling, lines[index].start)) - lines[index].start
            guard moved != 0 else { continue }
            lines[index].start += moved
            lines[index].end += moved
            lines[index].doubtTime = lines[index].doubtTime.map { $0 + moved }
            for word in lines[index].words.indices {
                lines[index].words[word].start += moved
                lines[index].words[word].end += moved
            }
        }
    }

    /// 全部取代，回傳換了幾處。
    static func replaceAll(_ find: String, with replacement: String,
                           in lines: [CaptionLine]) -> (lines: [CaptionLine], count: Int) {
        guard !find.isEmpty else { return (lines, 0) }
        var count = 0
        let result: [CaptionLine] = lines.map { line in
            let hits = line.text.components(separatedBy: find).count - 1
            guard hits > 0 else { return line }
            count += hits
            var changed = line
            changed.text = line.text.replacingOccurrences(of: find, with: replacement)
            changed.clearDoubt()
            return changed
        }
        return (result, count)
    }

    /// 字數，英數算半個。
    private static func weight(of text: String) -> Double {
        text.reduce(0.0) { total, character in
            if character.isWhitespace || character.isPunctuation { return total }
            return total + (character.isASCII ? 0.5 : 1)
        }
    }
}
