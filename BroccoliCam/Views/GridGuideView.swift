import SwiftUI

/// 九宮格構圖線：三等分，兩橫兩直。只是預覽上的 Overlay，不會進入影片。
/// 三等分轉 90 度還是三等分，橫放時不用另外處理。
struct GridGuideView: View {
    /// 濃淡 0.2–1；提詞開始後外面會傳一半進來。
    let strength: Double

    var body: some View {
        GeometryReader { geo in
            lines(in: geo.size)
        }
        .opacity(strength)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func lines(in size: CGSize) -> some View {
        // 視訊通話的小窗也會畫，線要跟著變細。
        let line: CGFloat = max(0.5, min(1, min(size.width, size.height) / 300))
        let shape = GridShape()
        return ZStack {
            // 白線在亮背景上看不到，底下墊一條淡黑邊。
            shape.stroke(Color.black.opacity(0.35), lineWidth: line * 3)
            shape.stroke(Color.white, lineWidth: line)
        }
    }
}

private struct GridShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps: [CGFloat] = [1, 2]
        for step in steps {
            let x = rect.minX + rect.width * step / 3
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            let y = rect.minY + rect.height * step / 3
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}
