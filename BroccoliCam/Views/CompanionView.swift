import SwiftUI

/// 陪伴模式的聆聽者。放在預覽頂端、靠近前鏡頭的位置，看著它講話，視線就在鏡頭附近。
/// 只是預覽上的 Overlay，不會進入影片，也不會發出聲音。
/// 目前是畫出來的花椰菜；有真人聆聽短片之後，換掉這個 view 就好，時機沿用 CompanionModel。
struct CompanionView: View {
    @ObservedObject var model: CompanionModel

    private static let floret = Color(red: 0.38, green: 0.80, blue: 0.35)
    private static let floretDark = Color(red: 0.18, green: 0.54, blue: 0.22)
    private static let stem = Color(red: 0.75, green: 0.89, blue: 0.56)
    private static let ink = Color(red: 0.13, green: 0.22, blue: 0.14)

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .fill(.black.opacity(0.45))
                    .frame(width: side, height: side)

                broccoli(side: side * 0.78)
                    .phaseAnimator([0.0, 1.0, 0.0, 0.55, 0.0], trigger: model.nodCount) { view, phase in
                        view.offset(y: phase * side * 0.045)
                    } animation: { _ in
                        .easeInOut(duration: 0.2)
                    }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityLabel("聆聽者")
    }

    private func broccoli(side: CGFloat) -> some View {
        ZStack {
            // 花球：幾個深淺不同的圓。
            ForEach(0..<Self.blobs.count, id: \.self) { index in
                let blob = Self.blobs[index]
                Circle()
                    .fill(blob.dark ? Self.floretDark : Self.floret)
                    .frame(width: side * blob.size, height: side * blob.size)
                    .offset(x: side * blob.x, y: side * blob.y)
            }

            // 梗就是臉。
            RoundedRectangle(cornerRadius: side * 0.16, style: .continuous)
                .fill(Self.stem)
                .frame(width: side * 0.50, height: side * 0.46)
                .offset(y: side * 0.22)

            // 眼睛
            HStack(spacing: side * 0.15) {
                eye(side: side)
                eye(side: side)
            }
            .offset(y: side * 0.16)

            // 嘴：平常是淺淺的弧，微笑時彎多一點。
            MouthShape(curve: model.smiling ? 1 : 0.35)
                .stroke(Self.ink, style: StrokeStyle(lineWidth: max(1.5, side * 0.022), lineCap: .round))
                .frame(width: side * 0.17, height: side * 0.09)
                .offset(y: side * 0.31)
                .animation(.easeInOut(duration: 0.35), value: model.smiling)
        }
        .frame(width: side, height: side)
    }

    private func eye(side: CGFloat) -> some View {
        Capsule()
            .fill(Self.ink)
            .frame(width: side * 0.055, height: model.eyesClosed ? side * 0.012 : side * 0.075)
            .animation(.easeInOut(duration: 0.07), value: model.eyesClosed)
    }

    private struct Blob {
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let dark: Bool
    }

    private static let blobs: [Blob] = [
        Blob(x: -0.27, y: -0.10, size: 0.34, dark: true),
        Blob(x: 0.27, y: -0.10, size: 0.34, dark: true),
        Blob(x: 0.0, y: -0.30, size: 0.38, dark: true),
        Blob(x: -0.16, y: -0.22, size: 0.36, dark: false),
        Blob(x: 0.16, y: -0.22, size: 0.36, dark: false),
        Blob(x: 0.0, y: -0.12, size: 0.40, dark: false)
    ]
}

/// 嘴的弧線。curve 0 是平的，1 是明顯的微笑。
private struct MouthShape: Shape {
    var curve: CGFloat

    var animatableData: CGFloat {
        get { curve }
        set { curve = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.minY + rect.height * 2 * curve)
        )
        return path
    }
}
