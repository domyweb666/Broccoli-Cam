import SwiftUI
import UIKit

/// 整篇稿子的排版。畫面就是用這一份畫的，換算也用這一份，所以看到的行和算出來的行一定是同一行。
///
/// 以前畫面由 SwiftUI 的 Text 一段一段排，換算另外用 TextKit 整篇排一次，再用「總高度的比例」對起來。
/// 兩邊中文行、英文行、空行的行高比例不一樣，折行規則也不一樣，有空行的長稿用一個比例對不齊，會差到別行去。
final class PromptLayout {
    struct Line {
        /// 這行開頭與結束（不含）的字元位置（UTF-16）。
        let start: Int
        let end: Int
        let glyphs: NSRange
        /// 這行頂端的 y 和高度（含行距）。
        let top: CGFloat
        let height: CGFloat
        /// 字的中線，判斷點在哪一行用。
        let center: CGFloat
        /// 空行，不拿來當跳轉的目的地。
        let isBlank: Bool
    }

    /// 每一行的基線都放在同樣的高度。不管的話，整行都是中文的會比夾了英文數字的低 3pt，行距看起來忽大忽小。
    private final class FixedBaseline: NSObject, NSLayoutManagerDelegate {
        let offset: CGFloat

        init(offset: CGFloat) {
            self.offset = offset
        }

        func layoutManager(_ layoutManager: NSLayoutManager,
                           shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
                           lineFragmentUsedRect: UnsafeMutablePointer<CGRect>,
                           baselineOffset: UnsafeMutablePointer<CGFloat>,
                           in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
            baselineOffset.pointee = offset
            return true
        }
    }

    /// 一套排版。NSLayoutManager 不會抓著 NSTextStorage 和 delegate，要自己留著。
    private struct Engine {
        let storage: NSTextStorage
        let manager: NSLayoutManager
        let container: NSTextContainer
        let baseline: FixedBaseline

        init(text: String, width: CGFloat, fontSize: CGFloat, color: UIColor) {
            let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineSpacing = fontSize * 0.28
            style.lineBreakStrategy = .standard
            // 中文、英文、空行用的字型不同，行高會不一樣，固定成一樣高。
            style.minimumLineHeight = font.lineHeight
            style.maximumLineHeight = font.lineHeight
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = CGSize(width: 0, height: 1)
            storage = NSTextStorage(string: text, attributes: [
                .font: font,
                .paragraphStyle: style,
                .foregroundColor: color,
                .shadow: shadow
            ])
            manager = NSLayoutManager()
            baseline = FixedBaseline(offset: font.ascender)
            manager.delegate = baseline
            container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
        }
    }

    let text: String
    let width: CGFloat
    let fontSize: CGFloat
    let lines: [Line]
    let height: CGFloat

    private let plain: Engine
    /// 唸過的字用的另一個顏色。排版和 plain 一樣，唸到才建。
    private lazy var spokenEngine = Engine(text: text, width: width, fontSize: fontSize, color: spokenColor)
    private let spokenColor: UIColor

    init(text: String, width: CGFloat, fontSize: CGFloat, spokenColor: UIColor) {
        self.text = text
        self.width = width
        self.fontSize = fontSize
        self.spokenColor = spokenColor
        let engine = Engine(text: text, width: width, fontSize: fontSize, color: .white)
        let manager = engine.manager
        let source = text as NSString
        var found: [Line] = []
        var bottom: CGFloat = 0
        let glyphs = NSRange(location: 0, length: manager.numberOfGlyphs)
        manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, glyphRange, _ in
            let characters = manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let content = source.substring(with: characters)
            let baseline = manager.location(forGlyphAt: glyphRange.location).y
            found.append(Line(
                start: characters.location,
                end: characters.location + characters.length,
                glyphs: glyphRange,
                top: rect.minY,
                height: rect.height,
                // 中文字大約從基線上方 0.88 到下方 0.12 個字高。
                center: rect.minY + baseline - fontSize * 0.38,
                isBlank: content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ))
            bottom = max(bottom, rect.maxY)
        }
        lines = found
        height = bottom
        plain = engine
    }

    /// 先把變色用的那一份排好。
    func prepareSpoken() {
        _ = spokenEngine
    }

    /// 畫一行，唸過的部分用另一個顏色。origin 是整篇左上角在目前畫布上的位置。
    func draw(_ line: Line, spoken: Int, at origin: CGPoint, in context: CGContext, bounds: CGRect) {
        if spoken <= line.start {
            plain.manager.drawGlyphs(forGlyphRange: line.glyphs, at: origin)
            return
        }
        if spoken >= line.end {
            spokenEngine.manager.drawGlyphs(forGlyphRange: line.glyphs, at: origin)
            return
        }
        let characters = NSRange(location: line.start, length: spoken - line.start)
        let done = plain.manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        let edge = origin.x + plain.manager.boundingRect(forGlyphRange: done, in: plain.container).maxX
        let cut = min(max(bounds.minX, edge), bounds.maxX)
        context.saveGState()
        context.clip(to: CGRect(x: bounds.minX, y: bounds.minY, width: cut - bounds.minX, height: bounds.height))
        spokenEngine.manager.drawGlyphs(forGlyphRange: line.glyphs, at: origin)
        context.restoreGState()
        context.saveGState()
        context.clip(to: CGRect(x: cut, y: bounds.minY, width: bounds.maxX - cut, height: bounds.height))
        plain.manager.drawGlyphs(forGlyphRange: line.glyphs, at: origin)
        context.restoreGState()
    }
}

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
    var viewportHeight: CGFloat = 0
    /// 文字排版的寬度與字級，由提詞 view 提供。
    private var layoutWidth: CGFloat = 0
    private var fontSize: CGFloat = 26
    private var contentHeight: CGFloat = 0
    private var cachedLayout: PromptLayout?
    /// 上一次整篇排版的時間，拉字級時用來節流。
    private var lastBuild: CFTimeInterval = 0
    private var rebuildQueued = false
    private let rebuildInterval: CFTimeInterval = 0.15

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
        guard let layout = layout(for: text), !layout.lines.isEmpty else { return 0 }
        // 一行捲出去超過一半，就算下一行。
        let y = offset + fontSize * 0.7
        let index = layout.lines.lastIndex { $0.top <= y } ?? 0
        return layout.lines[textLine(near: index, in: layout)].start
    }

    /// 下一行的開頭。已經在最後一行就是 nil。
    func nextLineStart(after utf16Offset: Int, in text: String) -> Int? {
        guard let layout = layout(for: text), !layout.lines.isEmpty else { return nil }
        let current = lineIndex(containing: utf16Offset, in: layout)
        return layout.lines[(current + 1)...].first { !$0.isBlank }?.start
    }

    /// 上一行的開頭。已經在第一行就是 nil。
    func previousLineStart(before utf16Offset: Int, in text: String) -> Int? {
        guard let layout = layout(for: text), !layout.lines.isEmpty else { return nil }
        let current = lineIndex(containing: utf16Offset, in: layout)
        return layout.lines[..<current].last { !$0.isBlank }?.start
    }

    /// 點在提詞區的 y（從提詞區上緣算），對應到那一行開頭的位置。
    /// 取字的中線離手指最近的那一行：行距全在字的下面，用行的上緣切會把字上方那半截算給上一行。
    func lineStart(atViewY y: CGFloat, in text: String) -> Int? {
        guard let layout = layout(for: text), !layout.lines.isEmpty else { return nil }
        let contentY = y - Self.topPadding + offset
        let nearest = layout.lines
            .filter { !$0.isBlank }
            .min { abs($0.center - contentY) < abs($1.center - contentY) }
        return nearest?.start ?? layout.lines[0].start
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

    // MARK: - 排版

    private func place(cursorAt utf16Offset: Int, in text: String) {
        cursor = utf16Offset
        guard let layout = layout(for: text), !layout.lines.isEmpty else {
            cursorTop = 0
            return
        }
        cursorTop = layout.lines[lineIndex(containing: utf16Offset, in: layout)].top
    }

    private func lineIndex(containing utf16Offset: Int, in layout: PromptLayout) -> Int {
        layout.lines.firstIndex { $0.end > utf16Offset } ?? layout.lines.count - 1
    }

    /// 空行就改成下一個有字的行，後面沒有了就往前找。
    private func textLine(near index: Int, in layout: PromptLayout) -> Int {
        guard layout.lines[index].isBlank else { return index }
        if let next = layout.lines.indices.first(where: { $0 > index && !layout.lines[$0].isBlank }) {
            return next
        }
        return layout.lines.indices.last(where: { $0 < index && !layout.lines[$0].isBlank }) ?? index
    }

    /// 畫面要畫的排版。寬度和字級由畫面決定，在這裡記下來，之後的換算都用同一份。
    func layout(for text: String, width: CGFloat, fontSize: CGFloat) -> PromptLayout? {
        layoutWidth = width
        // 拉字級時每一格都會來，長稿整篇重排會卡。太密就先用舊的，過一下再排一次。
        if fontSize != self.fontSize, let cached = cachedLayout, cached.text == text, cached.width == width,
           CACurrentMediaTime() - lastBuild < rebuildInterval {
            queueRebuild()
            return cached
        }
        self.fontSize = fontSize
        return layout(for: text)
    }

    private func queueRebuild() {
        guard !rebuildQueued else { return }
        rebuildQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + rebuildInterval) { [weak self] in
            guard let self else { return }
            self.rebuildQueued = false
            self.objectWillChange.send()
        }
    }

    /// 開錄前先把變色用的排版建好。
    func prepareSpoken(in text: String) {
        layout(for: text)?.prepareSpoken()
    }

    private func layout(for text: String) -> PromptLayout? {
        guard layoutWidth > 0 else { return nil }
        if let cached = cachedLayout, cached.width == layoutWidth, cached.fontSize == fontSize, cached.text == text {
            return cached
        }
        let built = PromptLayout(text: text, width: layoutWidth, fontSize: fontSize, spokenColor: UIColor(Theme.good))
        cachedLayout = built
        lastBuild = CACurrentMediaTime()
        contentHeight = built.height + Self.topPadding
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
