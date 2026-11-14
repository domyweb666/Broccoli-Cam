import SwiftUI

/// 固定的頭像／肩膀構圖輪廓。只是預覽上的 Overlay，不會進入影片。
/// 位置大致正確時輪廓變色；偵測不到臉時保持中性，不跳警告。
struct FramingGuideView: View {
    @ObservedObject var faces: FaceDetectionService
    let scale: CGFloat

    /// 頭部輪廓在預覽座標中的位置。臉部比對也用同一個矩形。
    static func headRect(in size: CGSize, scale: CGFloat) -> CGRect {
        let width = size.width * 0.40 * scale
        let height = width * 1.32
        let centerY = size.height * 0.36
        return CGRect(x: (size.width - width) / 2, y: centerY - height / 2, width: width, height: height)
    }

    var body: some View {
        GeometryReader { geo in
            let head = Self.headRect(in: geo.size, scale: scale)
            let status = FaceDetectionService.status(face: faces.faceRect, guide: head)
            let color: Color = status == .good ? Theme.good : Color.white.opacity(0.85)

            ZStack {
                Ellipse()
                    .stroke(color, style: StrokeStyle(lineWidth: 2, dash: [8, 7]))
                    .frame(width: head.width, height: head.height)
                    .position(x: head.midX, y: head.midY)

                ShoulderShape()
                    .stroke(color.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [8, 7]))
                    .frame(width: head.width * 2.2, height: head.height * 0.55)
                    .position(x: head.midX, y: head.maxY + head.height * 0.36)
            }
            .animation(.easeInOut(duration: 0.25), value: status == .good)
        }
        .allowsHitTesting(false)
    }
}

private struct ShoulderShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.25),
            control2: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX - rect.width * 0.25, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.25)
        )
        return path
    }
}
