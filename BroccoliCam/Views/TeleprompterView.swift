import SwiftUI

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

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
            PromptBody(text: text, spoken: model.spokenOffset, spacing: fontSize * 0.28)
                .equatable()
                .font(.system(size: fontSize, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineSpacing(fontSize * 0.28)
                .frame(width: max(0, geo.size.width - 28))
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { inner in
                        Color.clear.preference(key: ContentHeightKey.self, value: inner.size.height)
                    }
                )
                .padding(.top, TeleprompterModel.topPadding)
                .offset(y: -model.offset)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
                .onPreferenceChange(ContentHeightKey.self) { height in
                    model.contentHeight = height + TeleprompterModel.topPadding
                }
                .onAppear {
                    model.viewportHeight = geo.size.height
                    model.layoutWidth = max(0, geo.size.width - 28)
                    model.fontSize = fontSize
                }
                .onChange(of: geo.size) { _, size in
                    model.viewportHeight = size.height
                    model.layoutWidth = max(0, size.width - 28)
                }
                .onChange(of: fontSize) { _, value in
                    model.fontSize = value
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

/// 整篇提詞文字，一個換行一塊。
/// 整篇一鏡到底的稿子很長，全部塞在一個 Text 會變成一張很高的圖，分開畫才不會爆。
/// 提詞每一格都在捲動，獨立成 Equatable 的 view，唸到的位置沒變就不重新組。
private struct PromptBody: View, Equatable {
    let text: String
    let spoken: Int
    let spacing: CGFloat

    private struct Block: Identifiable {
        let id: Int
        let text: String
        /// 這一塊裡已經唸過幾個字（UTF-16）。
        let spoken: Int
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var start = 0
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let length = line.utf16.count
            result.append(Block(id: index, text: line, spoken: min(max(0, spoken - start), length)))
            start += length + 1
        }
        return result
    }

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(blocks) { block in
                PromptText(text: block.text, spoken: block.spoken)
                    .equatable()
                    .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// 稿子文字：唸過的字變綠，還沒唸的維持白色。
private struct PromptText: View, Equatable {
    let text: String
    let spoken: Int

    var body: some View {
        // 空行也要佔一行的高度。
        if text.isEmpty {
            Text(" ")
        } else {
            Text(styled)
        }
    }

    private var styled: AttributedString {
        let cut = String.Index(utf16Offset: min(max(0, spoken), text.utf16.count), in: text)
        var done = AttributedString(String(text[..<cut]))
        done.foregroundColor = Theme.good
        var rest = AttributedString(String(text[cut...]))
        rest.foregroundColor = Color.white
        return done + rest
    }
}
