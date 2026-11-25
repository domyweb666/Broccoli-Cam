import SwiftUI
import UIKit

/// 提詞區塊：固定在預覽頂端、緊鄰前鏡頭的窄區塊。
/// 只是預覽上的 Overlay，不會進入影片；可以蓋住預覽中的臉。
struct TeleprompterView: View {
    @ObservedObject var model: TeleprompterModel
    let text: String
    let fontSize: CGFloat
    let backgroundOpacity: Double
    /// 點了某一行，給那一行開頭的 UTF-16 位置。
    var onTapOffset: ((Int) -> Void)? = nil

    @State private var drag: DragState?

    /// 手指按著的這一次。
    private struct DragState {
        let origin: CGPoint
        /// 手指移動夠多、算是在滑動時的捲動位置；還沒算滑動是 nil。
        var startOffset: CGFloat?
        /// 算滑動那一刻手指已經走了多少，扣掉才不會跳一下。
        var slack: CGFloat = 0
    }

    /// 手指移動超過這麼多才算滑動，不到就是點一下。
    private static let dragThreshold: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let width = max(0, geo.size.width - 28)
            PromptLines(layout: model.layout(for: text, width: width, fontSize: fontSize),
                        offset: model.offset, spoken: model.spokenOffset)
                .frame(width: width, height: geo.size.height)
                .frame(width: geo.size.width, height: geo.size.height)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel(text)
                .onAppear {
                    model.viewportHeight = geo.size.height
                }
                .onChange(of: geo.size) { _, size in
                    model.viewportHeight = size.height
                }
        }
        .background(Color.black.opacity(backgroundOpacity))
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.78),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .contentShape(Rectangle())
        .gesture(touch)
    }

    /// 點一下和滑動用同一個手勢分：移動夠多就是滑動，放開時沒怎麼動就是點一下。
    private var touch: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                var state = drag ?? DragState(origin: value.startLocation)
                // 上一次被系統打斷、沒有收到放開，就當成新的一次。
                if state.origin != value.startLocation {
                    state = DragState(origin: value.startLocation)
                }
                let distance = hypot(value.translation.width, value.translation.height)
                if state.startOffset == nil && distance >= Self.dragThreshold {
                    state.startOffset = model.offset
                    state.slack = value.translation.height
                }
                if let start = state.startOffset {
                    model.setOffset(start - (value.translation.height - state.slack))
                }
                drag = state
            }
            .onEnded { value in
                let moved = drag?.origin == value.startLocation && drag?.startOffset != nil
                drag = nil
                let distance = hypot(value.translation.width, value.translation.height)
                guard !moved, distance < Self.dragThreshold, let onTapOffset else { return }
                if let utf16Offset = model.lineStart(atViewY: value.location.y, in: text) {
                    onTapOffset(utf16Offset)
                }
            }
    }
}

/// 提綱的重點：一張大字，靜止不動，貼著鏡頭。
/// 比提詞大一點，眼睛掃一下就知道要講什麼；放不下再縮。
struct PromptPointView: View {
    let text: String
    let fontSize: CGFloat
    let backgroundOpacity: Double

    var body: some View {
        Text(text)
            .font(.system(size: fontSize * 1.4, weight: .semibold))
            .lineSpacing(fontSize * 0.2)
            .minimumScaleFactor(0.25)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
            .padding(.horizontal, 14)
            .padding(.vertical, TeleprompterModel.topPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.black.opacity(backgroundOpacity))
            .allowsHitTesting(false)
    }
}

/// 畫提詞的文字。用的就是換算用的那一份排版，點到哪行、捲到哪行才不會差。
/// 整篇一鏡到底的稿子很長，只留看得到的那幾行，一行一個小圖層；捲動時只搬位置，不重畫。
private struct PromptLines: UIViewRepresentable {
    let layout: PromptLayout?
    let offset: CGFloat
    /// 唸到第幾個字（UTF-16），這之前的字變綠。
    let spoken: Int

    func makeUIView(context: Context) -> PromptLinesUIView {
        PromptLinesUIView(frame: .zero)
    }

    func updateUIView(_ view: PromptLinesUIView, context: Context) {
        view.show(layout, offset: offset, spoken: spoken)
    }
}

private final class PromptLinesUIView: UIView {
    private var layout: PromptLayout?
    private var offset: CGFloat = 0
    private var spoken = 0
    private let content = UIView()
    private var lineViews: [Int: PromptLineUIView] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        addSubview(content)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func show(_ next: PromptLayout?, offset nextOffset: CGFloat, spoken nextSpoken: Int) {
        if layout !== next {
            layout = next
            removeLines { _ in true }
        }
        offset = nextOffset
        spoken = nextSpoken
        refresh()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refresh()
    }

    private func refresh() {
        guard let layout, bounds.height > 0 else { return }
        let shift = TeleprompterModel.topPadding - offset
        content.frame = CGRect(x: 0, y: shift, width: layout.width, height: layout.height)
        let margin = PromptLineUIView.margin
        let lowest = -shift - margin
        let highest = bounds.height - shift + margin
        let visible: (Int) -> Bool = { index in
            let line = layout.lines[index]
            return line.top + line.height >= lowest && line.top <= highest
        }
        removeLines { !visible($0) }
        for index in layout.lines.indices where visible(index) {
            let line = layout.lines[index]
            guard !line.isBlank else { continue }
            if let existing = lineViews[index] {
                existing.setSpoken(spoken)
            } else {
                let view = PromptLineUIView(layout: layout, line: line, spoken: spoken)
                content.addSubview(view)
                lineViews[index] = view
            }
        }
    }

    private func removeLines(where gone: (Int) -> Bool) {
        for (index, view) in lineViews where gone(index) {
            view.removeFromSuperview()
            lineViews[index] = nil
        }
    }
}

/// 一行字。
private final class PromptLineUIView: UIView {
    /// 四周多留一點，陰影和超出行高的筆畫才不會被切掉。
    static let margin: CGFloat = 8

    private let layout: PromptLayout
    private let line: PromptLayout.Line
    private var spoken: Int

    init(layout: PromptLayout, line: PromptLayout.Line, spoken: Int) {
        self.layout = layout
        self.line = line
        self.spoken = Self.clamped(spoken, to: line)
        let frame = CGRect(x: 0, y: line.top, width: layout.width, height: line.height)
        super.init(frame: frame.insetBy(dx: -Self.margin, dy: -Self.margin))
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// 這一行裡唸到的位置沒變就不重畫。
    func setSpoken(_ next: Int) {
        let value = Self.clamped(next, to: line)
        guard value != spoken else { return }
        spoken = value
        setNeedsDisplay()
    }

    private static func clamped(_ spoken: Int, to line: PromptLayout.Line) -> Int {
        min(max(spoken, line.start), line.end)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        layout.draw(line, spoken: spoken, at: CGPoint(x: Self.margin, y: Self.margin - line.top),
                    in: context, bounds: bounds)
    }
}
