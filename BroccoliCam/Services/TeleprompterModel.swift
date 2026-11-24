import UIKit

/// 提詞捲動狀態。與錄影狀態互相獨立，可各自啟動／暫停。
/// 兩種捲法：固定速度往上捲，或跟著聲音（由語音辨識告訴它唸到哪個字）。
/// 兩種捲法都可以隨時跳到某一行。
final class TeleprompterModel: ObservableObject {
    /// 文字上緣留的空白，畫面和這裡的換算要一致。
    static let topPadding: CGFloat = 12

    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var isPlaying = false
    /// 目前是不是跟著聲音走。
    @Published private(set) var isFollowing = false
    /// 語音跟隨已經唸到稿子的第幾個字（UTF-16），這之前的字會變色。沒在跟隨時是 0。
    @Published private(set) var spokenOffset = 0

    /// 捲動速度（pt／秒）
    var speed: CGFloat = 36
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    /// 文字實際排版的寬度與字級，由提詞 view 提供，用來算「第幾個字在第幾行」。
    var layoutWidth: CGFloat = 0
    var fontSize: CGFloat = 26

    /// 固定速度自己捲到底而停下來的，不是人按的暫停。
    private(set) var stoppedAtEnd = false
    /// 回開頭時通知，語音跟隨要一起回去。
    var onReset: (() -> Void)?

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var followTarget: CGFloat = 0
    /// 跳轉正在滑過去的目的地。暫停中也會滑，滑完就清掉。
    private var glideTarget: CGFloat?
    /// 跳轉或跟讀指定的閱讀位置（UTF-16）。最後幾行捲不到最上面，只看 offset 會認錯行，所以要記著。
    /// 手動滑動、或自動捲過這一行之後就清掉，改由 offset 反推。
    private var cursor: Int?
    /// 那一行不受捲動上限影響時應該在的位置。
    private var cursorTop: CGFloat = 0
    /// 跳到最後幾行了：已經沒得捲，但不要因此停掉播放。
    private var restsAtEnd = false

    private struct Line {
        /// 這行開頭與結束（不含）的字元位置（UTF-16）。
        let start: Int
        let end: Int
        /// 這行頂端的 y。
        let top: CGFloat
        /// 空行，不拿來當跳轉的目的地。
        let isBlank: Bool
    }

    private struct LineTable {
        let text: String
        let width: CGFloat
        let fontSize: CGFloat
        let lines: [Line]
        let totalHeight: CGFloat
    }
    private var lineTable: LineTable?

    /// 捲到最後一行停在閱讀區上緣附近為止。
    private var maxOffset: CGFloat {
        max(0, contentHeight - viewportHeight * 0.35)
    }

    var isAtEnd: Bool {
        maxOffset > 0 && offset >= maxOffset
    }

    func play() {
        guard !isPlaying else { return }
        // 捲完了再按就從頭。自己跳到最後幾行的不算捲完。
        if isAtEnd && !isFollowing && glideTarget == nil && (cursor == nil || stoppedAtEnd) {
            offset = 0
            cursor = nil
            restsAtEnd = false
        }
        stoppedAtEnd = false
        isPlaying = true
        startLink()
    }

    func pause() {
        stoppedAtEnd = false
        if isPlaying { isPlaying = false }
        // 還在滑就讓它滑完。
        if glideTarget == nil { stopLink() }
    }

    func toggle() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func reset() {
        glideTarget = nil
        pause()
        offset = 0
        followTarget = 0
        spokenOffset = 0
        cursor = nil
        restsAtEnd = false
        onReset?()
    }

    /// 手動滑動時直接指定位置。
    func setOffset(_ value: CGFloat) {
        glideTarget = nil
        cursor = nil
        restsAtEnd = false
        stoppedAtEnd = false
        offset = min(maxOffset, max(0, value))
        followTarget = offset
        if !isPlaying { stopLink() }
    }

    // MARK: - 跟著聲音

    /// 從 text 的 utf16Offset 開始跟著聲音走，之前的字當作唸過。
    func startFollowing(from utf16Offset: Int, in text: String) {
        isFollowing = true
        followTarget = offset
        jump(toUTF16: utf16Offset, in: text)
    }

    /// 改回固定速度。播放狀態不變，從現在的位置接著捲。
    func stopFollowing() {
        guard isFollowing else { return }
        isFollowing = false
        spokenOffset = 0
        followTarget = offset
    }

    /// 唸到 text 的第 utf16Offset 個字了（也可能是退回去重唸）：把那一行捲到閱讀區最上面。
    func follow(utf16Offset: Int, in text: String) {
        guard isFollowing else { return }
        spokenOffset = utf16Offset
        place(cursorAt: utf16Offset, in: text)
        followTarget = min(maxOffset, cursorTop)
        if isPlaying { glideTarget = nil }
    }

    // MARK: - 跳轉

    /// 把第 utf16Offset 個字所在的那一行捲到閱讀區最上面。播放中、暫停中都可以。
    func jump(toUTF16 utf16Offset: Int, in text: String) {
        let target = min(max(0, utf16Offset), text.utf16.count)
        if isFollowing { spokenOffset = target }
        stoppedAtEnd = false
        place(cursorAt: target, in: text)
        let y = min(maxOffset, cursorTop)
        restsAtEnd = y >= maxOffset - 0.5
        followTarget = y
        if abs(y - offset) < 0.5 {
            glideTarget = nil
            if !isPlaying { stopLink() }
        } else {
            glideTarget = y
            startLink()
        }
    }

    /// 現在讀到的位置（UTF-16）：跳轉或跟讀指定過就是那裡，否則是閱讀區最上面那一行的開頭。
    func readingOffset(in text: String) -> Int {
        if let cursor {
            return min(max(0, cursor), text.utf16.count)
        }
        guard let table = table(for: text), !table.lines.isEmpty else { return 0 }
        // 一行捲出去超過一半，就算下一行。
        let y = offset + fontSize * 0.7
        let scale = heightScale(of: table)
        let index = table.lines.lastIndex { $0.top * scale <= y } ?? 0
        return table.lines[textLine(near: index, in: table)].start
    }

    /// 下一行的開頭。已經在最後一行就是 nil。
    func nextLineStart(after utf16Offset: Int, in text: String) -> Int? {
        guard let table = table(for: text), !table.lines.isEmpty else { return nil }
        let current = lineIndex(containing: utf16Offset, in: table)
        return table.lines[(current + 1)...].first { !$0.isBlank }?.start
    }

    /// 上一行的開頭。已經在第一行就是 nil。
    func previousLineStart(before utf16Offset: Int, in text: String) -> Int? {
        guard let table = table(for: text), !table.lines.isEmpty else { return nil }
        let current = lineIndex(containing: utf16Offset, in: table)
        return table.lines[..<current].last { !$0.isBlank }?.start
    }

    /// 點在提詞區的 y（從提詞區上緣算），對應到那一行開頭的位置。
    func lineStart(atViewY y: CGFloat, in text: String) -> Int? {
        guard let table = table(for: text), !table.lines.isEmpty else { return nil }
        let contentY = y - Self.topPadding + offset
        let scale = heightScale(of: table)
        let index = table.lines.lastIndex { $0.top * scale <= contentY } ?? 0
        return table.lines[textLine(near: index, in: table)].start
    }

    /// 各段開頭的位置（UTF-16）。用空行分段；整篇沒有空行就用換行分段。
    static func paragraphStarts(of text: String) -> [Int] {
        var lines: [(start: Int, isBlank: Bool)] = []
        var position = 0
        for line in text.components(separatedBy: "\n") {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            lines.append((start: position, isBlank: isBlank))
            position += line.utf16.count + 1
        }
        // 頭尾的空行不算分段。
        guard let first = lines.firstIndex(where: { !$0.isBlank }),
              let last = lines.lastIndex(where: { !$0.isBlank }) else { return [] }
        let body = lines[first...last]
        let hasBlank = body.contains { $0.isBlank }
        var starts: [Int] = []
        var previousBlank = true
        for line in body {
            if !line.isBlank && (previousBlank || !hasBlank) {
                starts.append(line.start)
            }
            previousBlank = line.isBlank
        }
        return starts
    }

    // MARK: - 行表

    private func place(cursorAt utf16Offset: Int, in text: String) {
        cursor = utf16Offset
        guard let table = table(for: text), !table.lines.isEmpty else {
            cursorTop = 0
            return
        }
        let line = table.lines[lineIndex(containing: utf16Offset, in: table)]
        cursorTop = max(0, line.top * heightScale(of: table))
    }

    /// SwiftUI 實際排出來的高度和這裡算的可能差一點，按比例換算。
    private func heightScale(of table: LineTable) -> CGFloat {
        let actual = max(1, contentHeight - Self.topPadding)
        return table.totalHeight > 0 ? actual / table.totalHeight : 1
    }

    private func lineIndex(containing utf16Offset: Int, in table: LineTable) -> Int {
        table.lines.firstIndex { $0.end > utf16Offset } ?? table.lines.count - 1
    }

    /// 空行就改成下一個有字的行，後面沒有了就往前找。
    private func textLine(near index: Int, in table: LineTable) -> Int {
        guard table.lines[index].isBlank else { return index }
        if let next = table.lines.indices.first(where: { $0 > index && !table.lines[$0].isBlank }) {
            return next
        }
        return table.lines.indices.last(where: { $0 < index && !table.lines[$0].isBlank }) ?? index
    }

    private func table(for text: String) -> LineTable? {
        guard layoutWidth > 0 else { return nil }
        if let cached = lineTable, cached.text == text, cached.width == layoutWidth, cached.fontSize == fontSize {
            return cached
        }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = fontSize * 0.28
        style.alignment = .center
        let storage = NSTextStorage(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .paragraphStyle: style
        ])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: layoutWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        let source = text as NSString
        var lines: [Line] = []
        var total: CGFloat = 0
        let glyphs = NSRange(location: 0, length: manager.numberOfGlyphs)
        manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, glyphRange, _ in
            let characters = manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let content = source.substring(with: characters)
            lines.append(Line(
                start: characters.location,
                end: characters.location + characters.length,
                top: rect.minY,
                isBlank: content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ))
            total = max(total, rect.maxY)
        }
        let built = LineTable(text: text, width: layoutWidth, fontSize: fontSize, lines: lines, totalHeight: total)
        lineTable = built
        return built
    }

    // MARK: - 每一幀

    private func startLink() {
        guard displayLink == nil else { return }
        lastTimestamp = 0
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// 往目標靠過去，不直接跳，眼睛才跟得上。到了回傳 true。
    private func ease(to target: CGFloat, dt: CGFloat, rate: CGFloat) -> Bool {
        let diff = target - offset
        if abs(diff) < 0.5 {
            if diff != 0 { offset = target }
            return true
        }
        offset += diff * min(1, dt * rate)
        return false
    }

    @objc private func step(_ link: CADisplayLink) {
        if lastTimestamp == 0 {
            lastTimestamp = link.timestamp
            return
        }
        let dt = CGFloat(link.timestamp - lastTimestamp)
        lastTimestamp = link.timestamp

        if let target = glideTarget {
            if ease(to: target, dt: dt, rate: 10) {
                glideTarget = nil
                if !isPlaying { stopLink() }
            }
            return
        }
        guard isPlaying else {
            stopLink()
            return
        }
        if isFollowing {
            _ = ease(to: followTarget, dt: dt, rate: 5)
            return
        }
        if restsAtEnd {
            if offset >= maxOffset - 0.5 { return }
            // 字級或版面變了、或退回去了，又有得捲了。
            restsAtEnd = false
        }

        let next = offset + speed * dt
        if next >= maxOffset {
            if offset != maxOffset { offset = maxOffset }
            pause()
            stoppedAtEnd = true
        } else {
            offset = next
            // 指定的那一行已經捲過去了，之後由 offset 反推。
            if cursor != nil && offset > cursorTop + fontSize * 0.7 {
                cursor = nil
            }
        }
    }
}
