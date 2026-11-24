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

    @State private var dragStartOffset: CGFloat?

    var body: some View {
        GeometryReader { geo in
            PromptText(text: text, spoken: model.spokenOffset)
                .equatable()
                .font(.system(size: fontSize, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineSpacing(fontSize * 0.28)
                .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                .frame(width: max(0, geo.size.width - 28))
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { inner in
                        Color.clear.preference(key: ContentHeightKey.self, value: inner.size.height)
                    }
                )
                .padding(.top, 12)
                .offset(y: -model.offset)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
                .onPreferenceChange(ContentHeightKey.self) { height in
                    model.contentHeight = height + 12
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
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let start = dragStartOffset ?? model.offset
                    if dragStartOffset == nil { dragStartOffset = start }
                    model.setOffset(start - value.translation.height)
                }
                .onEnded { _ in
                    dragStartOffset = nil
                }
        )
    }
}

/// 稿子文字：唸過的字變綠，還沒唸的維持白色。
/// 提詞每一格都在捲動，獨立成 Equatable 的 view，唸到的位置沒變就不重新組字。
private struct PromptText: View, Equatable {
    let text: String
    let spoken: Int

    var body: some View {
        Text(styled)
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
