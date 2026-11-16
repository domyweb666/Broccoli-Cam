import UIKit

/// 提詞捲動狀態。與錄影狀態互相獨立，可各自啟動／暫停。
/// 兩種捲法：固定速度往上捲，或跟著聲音（由語音辨識告訴它唸到哪個字）。
final class TeleprompterModel: ObservableObject {
    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var isPlaying = false
    /// 目前是不是跟著聲音走。
    @Published private(set) var isFollowing = false

    /// 捲動速度（pt／秒）
    var speed: CGFloat = 36
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    /// 文字實際排版的寬度與字級，由提詞 view 提供，用來算「第幾個字在第幾行」。
    var layoutWidth: CGFloat = 0
    var fontSize: CGFloat = 26

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var followTarget: CGFloat = 0

    private struct LineTable {
        let text: String
        let width: CGFloat
        let fontSize: CGFloat
        /// 每一行：這行結束的字元位置（UTF-16，不含）與這行頂端的 y。
        let lines: [(end: Int, top: CGFloat)]
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
        if isAtEnd && !isFollowing { offset = 0 }
        isPlaying = true
        lastTimestamp = 0
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func pause() {
        displayLink?.invalidate()
        displayLink = nil
        if isPlaying { isPlaying = false }
    }

    func toggle() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func reset() {
        pause()
        offset = 0
        followTarget = 0
    }

    /// 手動滑動時直接指定位置。
    func setOffset(_ value: CGFloat) {
        offset = min(maxOffset, max(0, value))
        followTarget = offset
    }

    // MARK: - 跟著聲音

    func setFollowing(_ on: Bool) {
        guard on != isFollowing else { return }
        followTarget = offset
        isFollowing = on
    }

    /// 唸到 text 的第 utf16Offset 個字了：把那一行捲到閱讀區最上面。
    func follow(utf16Offset: Int, in text: String) {
        guard isFollowing, let table = table(for: text), !table.lines.isEmpty else { return }
        let line = table.lines.first { $0.end > utf16Offset } ?? table.lines[table.lines.count - 1]
        // SwiftUI 實際排出來的高度和這裡算的可能差一點，按比例換算。
        let actual = max(1, contentHeight - 12)
        let scale = table.totalHeight > 0 ? actual / table.totalHeight : 1
        followTarget = min(maxOffset, max(0, line.top * scale))
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

        var lines: [(end: Int, top: CGFloat)] = []
        var total: CGFloat = 0
        let glyphs = NSRange(location: 0, length: manager.numberOfGlyphs)
        manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, glyphRange, _ in
            let characters = manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            lines.append((end: characters.location + characters.length, top: rect.minY))
            total = max(total, rect.maxY)
        }
        let built = LineTable(text: text, width: layoutWidth, fontSize: fontSize, lines: lines, totalHeight: total)
        lineTable = built
        return built
    }

    // MARK: - 每一幀

    @objc private func step(_ link: CADisplayLink) {
        if lastTimestamp == 0 {
            lastTimestamp = link.timestamp
            return
        }
        let dt = link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp

        if isFollowing {
            // 往目標位置靠過去，不直接跳，眼睛才跟得上。
            let diff = followTarget - offset
            if abs(diff) < 0.5 {
                if diff != 0 { offset = followTarget }
            } else {
                offset += diff * min(1, CGFloat(dt) * 5)
            }
            return
        }

        let next = offset + speed * CGFloat(dt)
        if next >= maxOffset {
            offset = maxOffset
            pause()
        } else {
            offset = next
        }
    }
}
