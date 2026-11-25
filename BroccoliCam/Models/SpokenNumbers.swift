import Foundation

/// 一段文字裡的一個數字。值用分子／分母存，30%、百分之三十、三成才能直接比，也不會有小數誤差。
struct SpokenNumber: Equatable {
    enum Kind: Equatable {
        case plain
        /// 30%、百分之三十。
        case percent
        /// 三成、三分之一。
        case ratio
        /// 幾折。八折是剩下八成，跟 80% 不是同一件事，只和折數比。
        case discount
    }

    let kind: Kind
    let numerator: Decimal
    let denominator: Decimal
    /// 分母裡有多少是「%、成、折」來的。拿掉就是寫出來的那個數：30% 是 30。
    let scale: Decimal
    /// 原文寫的樣子。
    let text: String
    /// 在原文裡的位置（UTF-16）。
    let range: Range<Int>
    /// 只留數字和單位的字，統一寫成中文。斷點不同（二零二五／三月、二零二五三月）的時候拿來接起來比。
    let spelling: String
    /// 單獨一個「一」或「零」。多半只是詞的一部分，要位置剛好對上才拿來比，也不算漏講。
    let isWeak: Bool

    func matches(_ other: SpokenNumber) -> Bool {
        if (kind == .discount) == (other.kind == .discount),
           numerator * other.denominator == other.numerator * denominator { return true }
        // 一邊沒有「%、成、折」，數字一樣就不算不同：「10 到 15%」和「百分之十到十五」的百分號記在不同的數字上，
        // 「前三，成為」聽寫沒有標點會讀成三成，辨識也可能漏掉 %。
        guard (kind == .plain) != (other.kind == .plain) else { return false }
        return numerator * scale * other.denominator == other.numerator * other.scale * denominator
    }
}

/// 從一段話裡把數字抽出來。分不清楚的寧可不抽：沒抽到就不比，不會誤報。
enum SpokenNumbers {
    static func values(in text: String) -> [SpokenNumber] {
        Reader(text).read()
    }

    /// 只留數字和單位的字，阿拉伯數字換成中文。
    static func spelling<Text: Sequence>(_ characters: Text) -> String where Text.Element == Character {
        var result = ""
        for character in characters {
            let here = folded[character] ?? character
            if let digit = single(here) {
                result.append(spelled[digit])
            } else if here == "廿" || here == "卅" {
                result += here == "廿" ? "二十" : "三十"
            } else if smallUnits[here] != nil || bigUnits[here] != nil {
                result.append(here)
            }
        }
        return result
    }

    /// 一個數字字的值。
    fileprivate static func single(_ character: Character) -> Int? {
        if character.isASCII, character.isNumber { return character.wholeNumberValue }
        return digits[character]
    }

    fileprivate static let digits: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "兩": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
    ]
    fileprivate static let spelled: [Character] = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
    /// 十的幾次方。
    fileprivate static let smallUnits: [Character: Int] = ["十": 1, "百": 2, "千": 3]
    fileprivate static let bigUnits: [Character: Int] = ["萬": 4, "億": 8, "兆": 12]
    /// 全形和簡體先換成同一種寫法。
    fileprivate static let folded: [Character: Character] = [
        "０": "0", "１": "1", "２": "2", "３": "3", "４": "4", "５": "5", "６": "6", "７": "7", "８": "8", "９": "9",
        "％": "%", "﹪": "%", "．": ".", "／": "/", "：": ":", "两": "兩", "万": "萬", "亿": "億", "点": "點"
    ]

    /// 單獨的「一」後面接這些字才當數字（一個、一天）。
    fileprivate static let measures: Set<Character> = [
        "個", "次", "天", "年", "月", "日", "號", "週", "周", "元", "塊", "人", "位", "件", "張", "本", "支", "隻", "條",
        "台", "臺", "輛", "間", "家", "種", "項", "倍", "歲", "秒", "分", "小", "公", "克", "斤", "杯", "瓶", "頁", "句",
        "步", "層", "樓", "名", "顆", "份", "包", "集", "堂", "檔"
    ]

    /// 裡面的字不是數字。「十分」另外看前後。
    /// 「一點、一度、一時、一代、一路」不能放：十一點、二十一度會被拆掉。
    private static let fixedWords: [String] = [
        "一起", "一樣", "一定", "一直", "一下", "一些", "一般", "一旦", "一向", "一再", "一致", "一切", "一律", "一共",
        "一同", "一半", "一會", "一開始", "一輩子", "一味", "一貫", "一概", "一心一意", "一模一樣", "一點一滴", "一字一句",
        "一五一十", "一清二楚", "一乾二淨", "一石二鳥", "一舉兩得", "一箭雙鵰", "一刀兩斷", "一不做二不休", "一成不變",
        "獨一無二", "數一數二", "說一不二", "略知一二", "舉一反三", "千篇一律", "萬無一失", "九牛一毛", "九死一生",
        "三心二意", "三三兩兩", "三番兩次", "三番五次", "三言兩語", "三長兩短", "三不五時", "三更半夜", "三生有幸",
        "三教九流", "三姑六婆", "三思", "三明治", "三溫暖", "接二連三", "說三道四", "朝三暮四", "不三不四", "低三下四",
        "丟三落四", "顛三倒四", "隔三差五", "兩面三刀", "三七二十一", "張三", "李四", "王五", "小三", "二話不說",
        "四面八方", "四通八達", "四捨五入", "四不像", "四分五裂", "四平八穩", "五花八門", "五顏六色", "五味雜陳",
        "五體投地", "五十步笑百步", "六神無主", "七上八下", "七嘴八舌", "七七八八", "亂七八糟", "雜七雜八", "橫七豎八",
        "八九不離十", "半斤八兩", "八卦", "九霄", "九成九", "十之八九", "十有八九", "十全十美", "十萬火急", "十八般武藝",
        "十惡不赦", "十拿九穩", "十足", "十字", "兩全其美", "進退兩難", "百分百", "百發百中", "千言萬語", "千方百計",
        "千變萬化", "千真萬確", "萬不得已"
    ]
    fileprivate static let fixedByHead: [Character: [[Character]]] = {
        var result: [Character: [[Character]]] = [:]
        for word in SpokenNumbers.fixedWords {
            let characters = Array(word)
            guard let head = characters.first else { continue }
            result[head, default: []].append(characters)
        }
        return result
    }()

    fileprivate static func power(_ exponent: Int) -> Decimal {
        var result = Decimal(1)
        for _ in 0..<max(0, exponent) { result *= 10 }
        return result
    }
}

// MARK: - 讀

private struct Reader {
    private enum Part {
        /// 一串阿拉伯數字，千分位已經拿掉。
        case figures(String)
        case digit(Int)
        /// 十百千。
        case small(Int)
        /// 萬億兆。
        case big(Int)
        /// 小數點後面的字，例如「14」。
        case fraction(String)
    }

    private struct Piece {
        let part: Part
        /// 在字元裡的位置。
        let from: Int
        let to: Int

        var isDigit: Bool {
            if case .digit = part { return true }
            return false
        }
        var isFraction: Bool {
            if case .fraction = part { return true }
            return false
        }
        /// 單位是十的幾次方，不是單位就是 nil。
        var unit: Int? {
            switch part {
            case .small(let power), .big(let power): return power
            case .figures, .digit, .fraction: return nil
            }
        }
    }

    /// 連在一起的一串數字字。
    private struct Run {
        var pieces: [Piece] = []
        var end: Int
        /// 版本號、日期、分不清是時間還是小數的，整串不抽。
        var isUnclear = false
    }

    private struct Amount {
        var top: Decimal
        var bottom: Decimal = 1
        /// 在字元裡的位置。
        var from: Int
        var to: Int
    }

    private let source: [Character]
    private let plain: [Character]
    private let offsets: [Int]
    private let masked: [Bool]

    init(_ text: String) {
        let source = Array(text)
        let plain = source.map { SpokenNumbers.folded[$0] ?? $0 }
        var offsets = [0]
        offsets.reserveCapacity(source.count + 1)
        for character in source {
            offsets.append(offsets[offsets.count - 1] + character.utf16.count)
        }
        self.source = source
        self.plain = plain
        self.offsets = offsets
        masked = Self.mask(plain)
    }

    private static func mask(_ plain: [Character]) -> [Bool] {
        var result = [Bool](repeating: false, count: plain.count)
        for index in plain.indices {
            if let words = SpokenNumbers.fixedByHead[plain[index]] {
                for word in words where index + word.count <= plain.count
                    && Array(plain[index..<(index + word.count)]) == word {
                    for position in index..<(index + word.count) { result[position] = true }
                }
            }
            // 「十分開心」不是數字；十分鐘、十分之一、三十分、五點十分是。
            if plain[index] == "十", index + 1 < plain.count, plain[index + 1] == "分" {
                let next: Character? = index + 2 < plain.count ? plain[index + 2] : nil
                var isNumber = next == "鐘" || next == "之"
                if index > 0 {
                    let before = plain[index - 1]
                    if before == "點" || SpokenNumbers.digits[before] != nil || isFigure(before) { isNumber = true }
                }
                if !isNumber { result[index] = true }
            }
        }
        return result
    }

    private static func isFigure(_ character: Character) -> Bool {
        character >= "0" && character <= "9" && character.isASCII
    }

    private func character(_ index: Int) -> Character? {
        index >= 0 && index < plain.count ? plain[index] : nil
    }

    /// 這個位置是不是數字字（沒被固定詞蓋掉）。
    private func isNumeric(_ index: Int) -> Bool {
        guard let here = character(index), !masked[index] else { return false }
        return Self.isFigure(here) || SpokenNumbers.digits[here] != nil || SpokenNumbers.smallUnits[here] != nil
            || SpokenNumbers.bigUnits[here] != nil || here == "廿" || here == "卅"
    }

    private func skippingSpaces(_ index: Int) -> Int {
        var index = index
        while let here = character(index), here == " " || here == "\u{00A0}" { index += 1 }
        return index
    }

    func read() -> [SpokenNumber] {
        var result: [SpokenNumber] = []
        var index = 0
        while index < plain.count {
            guard isNumeric(index) else {
                index += 1
                continue
            }
            if let percent = hundredths(at: index) {
                if let number = percent.number { result.append(number) }
                index = max(index + 1, percent.end)
                continue
            }
            let run = readRun(from: index)
            let step = numbers(run, start: index)
            result.append(contentsOf: step.numbers)
            index = max(index + 1, step.end)
        }
        return result
    }

    // MARK: 一串數字字

    private func readRun(from start: Int) -> Run {
        var run = Run(end: start)
        while isNumeric(run.end) || character(run.end) == "點" {
            let index = run.end
            guard let here = character(index), !masked[index] else { break }
            if Self.isFigure(here) {
                // 「三3」「2025三月」中間沒有單位，是兩個數字。
                if let last = run.pieces.last, last.unit == nil { break }
                readFigures(&run)
                if run.isUnclear { break }
                // 「100 萬」中間可能有空白。
                let next = skippingSpaces(run.end)
                if next > run.end, isNumeric(next), let unit = character(next),
                   SpokenNumbers.smallUnits[unit] != nil || SpokenNumbers.bigUnits[unit] != nil {
                    run.end = next
                }
            } else if let value = SpokenNumbers.digits[here] {
                if let last = run.pieces.last, last.unit == nil, !last.isDigit { break }
                run.pieces.append(Piece(part: .digit(value), from: index, to: index + 1))
                run.end = index + 1
            } else if here == "廿" || here == "卅" {
                if let last = run.pieces.last, last.unit == nil { break }
                run.pieces.append(Piece(part: .digit(here == "廿" ? 2 : 3), from: index, to: index + 1))
                run.pieces.append(Piece(part: .small(1), from: index, to: index + 1))
                run.end = index + 1
            } else if let power = SpokenNumbers.smallUnits[here] {
                run.pieces.append(Piece(part: .small(power), from: index, to: index + 1))
                run.end = index + 1
            } else if let power = SpokenNumbers.bigUnits[here] {
                run.pieces.append(Piece(part: .big(power), from: index, to: index + 1))
                run.end = index + 1
            } else {
                // 點：要繼續讀（小數）才往下，其他情況到這裡為止。
                if !readPoint(&run) { break }
            }
        }
        return run
    }

    /// 1,000、3.5。3.5.2 和 11/25 讀完但不抽。
    private func readFigures(_ run: inout Run) {
        let start = run.end
        var end = start
        var whole = ""
        func take() {
            while let here = character(end), Self.isFigure(here) {
                whole.append(here)
                end += 1
            }
        }
        take()
        if whole.count <= 3 {
            while character(end) == ",", isFigures(end + 1, count: 3) {
                end += 1
                take()
            }
        }
        run.pieces.append(Piece(part: .figures(whole), from: start, to: end))
        if character(end) == ".", let next = character(end + 1), Self.isFigure(next) {
            let dot = end
            end += 1
            let before = whole.count
            take()
            let decimals = String(whole.dropFirst(before))
            run.pieces.append(Piece(part: .fraction(decimals), from: dot, to: end))
        }
        while let here = character(end), here == "." || here == "/", let next = character(end + 1), Self.isFigure(next) {
            run.isUnclear = true
            end += 1
            take()
        }
        run.end = end
    }

    /// 從這裡開始剛好這麼多個阿拉伯數字。
    private func isFigures(_ index: Int, count: Int) -> Bool {
        for offset in 0..<count {
            guard let here = character(index + offset), Self.isFigure(here) else { return false }
        }
        if let after = character(index + count), Self.isFigure(after) { return false }
        return true
    }

    /// 現在在「點」上。讀成小數就回 true，繼續往下讀；是幾點鐘、第幾點就停。
    private func readPoint(_ run: inout Run) -> Bool {
        guard !run.pieces.isEmpty, !run.pieces.contains(where: { $0.isFraction }) else { return false }
        let point = run.end
        var end = point + 1
        var decimals = ""
        if let first = character(end), Self.isFigure(first) {
            decimals.append(first)
            end += 1
            // 「3點15」是幾點幾分，拆成兩個數字。
            if let second = character(end), Self.isFigure(second) { return false }
        } else {
            while isNumeric(end), let here = character(end), let value = SpokenNumbers.digits[here] {
                decimals.append(String(value))
                end += 1
            }
        }
        guard !decimals.isEmpty else { return false }
        if let next = character(end) {
            // 三點十五、三點五十。
            if next == "十" || next == "廿" || next == "卅" { return false }
            if next == "刻" {
                run.end = end
                return false
            }
            // 「三點五分」可能是三點零五分，也可能是三點五分鐘、三點五分的成績。
            if next == "分", character(end + 1) != "之", decimals.count == 1 {
                run.isUnclear = true
                run.end = end
                return false
            }
            // 十七點四點一。
            if next == "點", isNumeric(end + 1) {
                run.isUnclear = true
                while character(end) == "點" || isNumeric(end) { end += 1 }
                run.end = end
                return false
            }
        }
        run.pieces.append(Piece(part: .fraction(decimals), from: point, to: end))
        run.end = end
        return true
    }

    // MARK: 算值

    /// 讀不通的（五六十、十五六）回空的。連著兩個數字（三百五百）拆開。
    private func amounts(_ pieces: [Piece]) -> [Amount] {
        guard let first = pieces.first, let ending = pieces.last else { return [] }
        let point = pieces.firstIndex(where: { $0.isFraction }) ?? pieces.count
        var result: [Amount] = []
        var next = 0
        while next < point {
            guard let step = integer(Array(pieces[next..<point])) else { return [] }
            result.append(step.amount)
            next += step.used
        }
        guard var last = result.popLast() else { return [] }
        if point < pieces.count, case .fraction(let decimals) = pieces[point].part {
            guard decimals.count <= 8 else { return [] }
            for character in decimals {
                last.top = last.top * 10 + Decimal(character.wholeNumberValue ?? 0)
                last.bottom *= 10
            }
            for piece in pieces[(point + 1)...] {
                guard let unit = piece.unit else { return [] }
                last.top *= SpokenNumbers.power(unit)
            }
            last.to = ending.to
        }
        if result.isEmpty { last.from = first.from }
        result.append(last)
        return result
    }

    /// 從頭讀一個整數，回傳值和用掉幾塊。
    private func integer(_ pieces: [Piece]) -> (amount: Amount, used: Int)? {
        guard let first = pieces.first, let ending = pieces.last else { return nil }
        // 二零二六、零九一二：一個一個唸的。
        if pieces.allSatisfy({ $0.isDigit }) {
            guard pieces.count <= 16 else { return nil }
            var value = Decimal(0)
            for piece in pieces {
                if case .digit(let digit) = piece.part { value = value * 10 + Decimal(digit) }
            }
            return (Amount(top: value, from: first.from, to: ending.to), pieces.count)
        }

        var total = Decimal(0)
        var section = Decimal(0)
        var current: Decimal?
        var currentAt = 0
        var isSingle = false
        var sawZero = false
        var lastUnit = 0
        var sectionUnit = 4
        var bigUnit = Int.max
        var sectionFrom = 0
        func stop(_ value: Decimal, before index: Int) -> (amount: Amount, used: Int)? {
            guard index > 0 else { return nil }
            return (Amount(top: value, from: first.from, to: pieces[index - 1].to), index)
        }

        for (index, piece) in pieces.enumerated() {
            switch piece.part {
            case .digit(let digit):
                guard current == nil else { return nil }
                if digit == 0 {
                    guard index > 0 else { return nil }
                    sawZero = true
                } else {
                    current = Decimal(digit)
                    currentAt = index
                    isSingle = true
                }
            case .figures(let text):
                guard current == nil, text.count <= 16 else { return nil }
                var value = Decimal(0)
                for character in text { value = value * 10 + Decimal(character.wholeNumberValue ?? 0) }
                // 「一千3000」是兩個數字。
                if lastUnit > 0, value >= SpokenNumbers.power(lastUnit) { return stop(total + section, before: index) }
                current = value
                currentAt = index
                isSingle = text.count == 1
            case .small(let power):
                if current == nil {
                    guard power == 1, index == 0 || sawZero else { return nil }
                    current = 1
                    currentAt = index
                    isSingle = true
                }
                // 單位沒有愈來愈小：三百五百是兩個數字。
                if power >= sectionUnit { return stop(total + section, before: currentAt) }
                section += (current ?? 0) * SpokenNumbers.power(power)
                current = nil
                sectionUnit = power
                lastUnit = power
                sawZero = false
            case .big(let power):
                if current == nil, section == 0 {
                    // 三萬億。
                    guard total > 0 else { return nil }
                    total *= SpokenNumbers.power(power)
                } else {
                    if power >= bigUnit { return stop(total, before: sectionFrom) }
                    total += (section + (current ?? 0)) * SpokenNumbers.power(power)
                }
                section = 0
                current = nil
                sectionUnit = 4
                bigUnit = power
                lastUnit = power
                sawZero = false
                sectionFrom = index + 1
            case .fraction:
                return nil
            }
        }
        if let tail = current {
            // 兩萬五、三千二、一百一：最後一個數字省掉了單位。
            let short = isSingle && !sawZero && lastUnit >= 2
            section += short ? tail * SpokenNumbers.power(lastUnit - 1) : tail
        }
        return (Amount(top: total + section, from: first.from, to: ending.to), pieces.count)
    }

    // MARK: 收成數字

    /// 百分之三十、千分之三、萬分之一：開頭的單位前面沒有數字。
    private func hundredths(at index: Int) -> (number: SpokenNumber?, end: Int)? {
        guard let here = character(index), here == "百" || here == "千" || here == "萬",
              character(index + 1) == "分", character(index + 2) == "之", !masked[index + 1] else { return nil }
        let power = SpokenNumbers.smallUnits[here] ?? 4
        let base = Amount(top: SpokenNumbers.power(power), from: index, to: index + 1)
        return over(base, after: index + 1, isPercent: here == "百")
    }

    /// 「分之」後面的分子。讀不出來就整個不抽。
    private func over(_ base: Amount, after index: Int, isPercent: Bool) -> (number: SpokenNumber?, end: Int) {
        let start = skippingSpaces(index + 2)
        guard isNumeric(start) else { return (nil, index + 2) }
        let run = readRun(from: start)
        guard !run.isUnclear, character(run.end) != "幾" else { return (nil, run.end) }
        var list = amounts(run.pieces)
        // 百分之百。
        if list.isEmpty, run.pieces.count == 1, let unit = run.pieces[0].unit {
            list = [Amount(top: SpokenNumbers.power(unit), from: start, to: run.end)]
        }
        guard list.count == 1, let top = list.first, base.top > 0, base.bottom == 1 else { return (nil, run.end) }
        let number = make(isPercent ? .percent : .ratio, top: top.top, bottom: top.bottom, scale: base.top,
                          from: base.from, to: top.to,
                          spelling: isPercent ? spell(top) : spell(base) + "/" + spell(top))
        return (number, max(top.to, run.end))
    }

    private func numbers(_ run: Run, start: Int) -> (numbers: [SpokenNumber], end: Int) {
        guard !run.isUnclear else { return ([], run.end) }
        let list = amounts(run.pieces)
        guard let last = list.last, !isVague(run, start: start) else { return ([], run.end) }
        var result: [SpokenNumber] = []
        for amount in list.dropLast() {
            result.append(make(.plain, top: amount.top, bottom: amount.bottom, scale: 1, from: amount.from, to: amount.to,
                               spelling: spell(amount)))
        }
        if character(run.end) == "分", character(run.end + 1) == "之" {
            let fraction = over(last, after: run.end, isPercent: last.top == 100 && last.bottom == 1)
            if let number = fraction.number { result.append(number) }
            return (result, fraction.end)
        }
        if let end = percentEnd(run.end) {
            result.append(make(.percent, top: last.top, bottom: last.bottom, scale: 100, from: last.from, to: end,
                               spelling: spell(last)))
            return (result, end)
        }
        if let share = tenths(last, run) {
            result.append(share.number)
            return (result, share.end)
        }
        if let price = discount(last, run) {
            result.append(price)
            return (result, run.end + 1)
        }
        guard !isListMark(run, start: start) else { return ([], run.end) }
        let lone = loneKind(run, start: start)
        if lone != .word {
            result.append(make(.plain, top: last.top, bottom: last.bottom, scale: 1, from: last.from, to: last.to,
                               spelling: spell(last), isWeak: lone == .weak))
        }
        return (result, run.end)
    }

    /// 幾十、十幾、數百：沒有確定的值。「五十一起」分不出是五十一還是五十，也不抽。
    private func isVague(_ run: Run, start: Int) -> Bool {
        if character(run.end) == "幾" { return true }
        if run.end < plain.count, masked[run.end], plain[run.end] == "一" { return true }
        guard let before = character(start - 1) else { return false }
        if before == "幾" { return true }
        return before == "數" && run.pieces.first?.unit != nil
    }

    private enum Lone {
        case word, weak, number
    }

    /// 只有一個「一」或「零」的時候，是不是真的數字。
    private func loneKind(_ run: Run, start: Int) -> Lone {
        // 「一一說明」。
        if run.pieces.count == 2, run.pieces.allSatisfy({ plain[$0.from] == "一" }) { return .word }
        guard run.pieces.count == 1, case .digit(let digit) = run.pieces[0].part, digit <= 1 else { return .number }
        if digit == 0 { return .weak }
        if let before = character(start - 1) {
            if before == "第" || before == "週" || before == "周" { return .number }
            if before == "期", character(start - 2) == "星" { return .number }
            if before == "拜", character(start - 2) == "禮" { return .number }
        }
        guard let next = character(run.end), SpokenNumbers.measures.contains(next) else { return .word }
        return .weak
    }

    /// 一行開頭的「1.」「2、」「(3)」是編號，多半不會唸。
    private func isListMark(_ run: Run, start: Int) -> Bool {
        guard run.end - start <= 2, let next = character(run.end), [".", "、", ")", "）"].contains(next) else { return false }
        if let after = character(run.end + 1), Self.isFigure(after) { return false }
        var index = start - 1
        while let here = character(index), here == " " || here == "(" || here == "（" || here == "\u{3000}" { index -= 1 }
        guard let here = character(index) else { return true }
        return here.isNewline
    }

    private func percentEnd(_ index: Int) -> Int? {
        if character(index) == "趴" { return index + 1 }
        let start = skippingSpaces(index)
        if character(start) == "%" { return start + 1 }
        let word: [Character] = ["p", "e", "r", "c", "e", "n", "t"]
        guard start + word.count <= plain.count else { return nil }
        for (offset, letter) in word.enumerated() {
            let here = plain[start + offset]
            guard here.isASCII, here == letter || here == Character(letter.uppercased()) else { return nil }
        }
        return start + word.count
    }

    /// 三成、三成五。
    private func tenths(_ amount: Amount, _ run: Run) -> (number: SpokenNumber, end: Int)? {
        guard character(run.end) == "成", !masked[run.end], amount.top > 0,
              amount.top <= amount.bottom * 10 else { return nil }
        var top = amount.top
        var scale: Decimal = 10
        var end = run.end + 1
        var spelling = spell(amount) + "成"
        if amount.bottom == 1, isNumeric(end), !isNumeric(end + 1), let here = character(end), let extra = SpokenNumbers.single(here) {
            top = top * 10 + Decimal(extra)
            scale = 100
            spelling.append(SpokenNumbers.spelled[extra])
            end += 1
        }
        let number = make(.ratio, top: top, bottom: amount.bottom, scale: scale, from: amount.from, to: end,
                          spelling: spelling)
        return (number, end)
    }

    /// 八折、85 折、八五折。
    private func discount(_ amount: Amount, _ run: Run) -> SpokenNumber? {
        guard character(run.end) == "折", !masked[run.end], amount.top > 0 else { return nil }
        let scale: Decimal = amount.top >= amount.bottom * 10 ? 100 : 10
        return make(.discount, top: amount.top, bottom: amount.bottom, scale: scale, from: amount.from,
                    to: run.end + 1, spelling: spell(amount) + "折")
    }

    private func make(_ kind: SpokenNumber.Kind, top: Decimal, bottom: Decimal, scale: Decimal, from: Int, to: Int,
                      spelling: String, isWeak: Bool = false) -> SpokenNumber {
        SpokenNumber(kind: kind, numerator: top, denominator: bottom * scale, scale: scale,
                     text: String(source[from..<to]), range: offsets[from]..<offsets[to], spelling: spelling,
                     isWeak: isWeak)
    }

    private func spell(_ amount: Amount) -> String {
        SpokenNumbers.spelling(plain[amount.from..<amount.to])
    }
}
