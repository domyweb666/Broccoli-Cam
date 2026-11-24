import SwiftUI

/// 頭像／肩膀構圖輪廓。只是預覽上的 Overlay，不會進入影片。
/// 大小跟著人的遠近縮放，位置固定在「頭該放的地方」，所以坐近坐遠都對得準。
/// 位置大致正確時輪廓變色；偵測不到臉時保持中性，不跳警告。
struct FramingGuideView: View {
    @ObservedObject var faces: FaceDetectionService
    /// 使用者自己調的倍率，乘在推估的頭部大小上。
    let scale: CGFloat
    /// 橫放時這個 view 會被轉 90 度（±90）；直放是 0。
    var angle: Double = 0
    /// 上方被聆聽者佔掉的高度（佔畫面高度的比例），頭頂要在這之下。
    var topReserve: CGFloat = 0.06
    /// 線的濃淡 0.2–1。
    var strength: Double = 0.85

    /// 目前頭像框的寬（佔短邊的比例）。看不到臉時維持上一次的大小。
    @State private var fraction: CGFloat = 0.46

    private static let minFraction: CGFloat = 0.26
    private static let maxFraction: CGFloat = 0.68
    /// 頭的中心放在畫面高度的這個位置，眼睛會落在上方四成左右。
    private static let centerY: CGFloat = 0.40
    /// 為了避開聆聽者往下讓，頭的中心最低到這裡；再低構圖就不對了，改成縮小頭像框。
    private static let lowestCenterY: CGFloat = 0.56

    /// 頭部輪廓在預覽座標中的位置。臉部比對也用同一個矩形。
    static func headRect(in size: CGSize, fraction: CGFloat, scale: CGFloat, topReserve: CGFloat) -> CGRect {
        let aspect = FaceDetectionService.headAspect
        // 橫式畫面的高度短，再夾一次才不會超出去。
        let wanted = min(min(size.width, size.height) * fraction * scale, size.height * 0.62 / aspect)
        // 頭頂在 topReserve 之下、中心不低於 lowestCenterY，兩個都要成立時頭最高只能這麼高。
        let tallest = max(0, size.height * (lowestCenterY - topReserve) * 2)
        let width = min(wanted, tallest / aspect)
        let height = width * aspect
        let midY = max(size.height * centerY, size.height * topReserve + height / 2)
        return CGRect(x: (size.width - width) / 2, y: midY - height / 2, width: width, height: height)
    }

    var body: some View {
        GeometryReader { geo in
            outline(in: geo.size)
                .onChange(of: faces.faceRect) { _, _ in
                    follow(in: geo.size)
                }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private func outline(in size: CGSize) -> some View {
        let head = Self.headRect(in: size, fraction: fraction, scale: scale, topReserve: topReserve)
        let isGood = FaceDetectionService.status(face: turnedFace(in: size), guide: head) == .good
        // 變綠是回饋，比平常的線再清楚一點；預設濃淡 0.85 時綠線就是原本的不透明。
        let color: Color = isGood ? Theme.good.opacity(min(1, strength + 0.15)) : Color.white.opacity(strength)
        // 視訊通話的小窗也會畫頭像框，線要跟著變細。
        let line: CGFloat = max(0.5, min(1, min(size.width, size.height) / 300))
        let stroke = StrokeStyle(lineWidth: max(1, 2 * line), dash: [8 * line, 7 * line])

        return ZStack {
            Ellipse()
                .stroke(color, style: stroke)
                .frame(width: head.width, height: head.height)
                .position(x: head.midX, y: head.midY)

            ShoulderShape(headMidX: head.midX, headMaxY: head.maxY, headWidth: head.width)
                .stroke(color.opacity(0.7), style: stroke)
        }
        .animation(.easeInOut(duration: 0.25), value: isGood)
        .animation(.easeOut(duration: 0.35), value: fraction)
    }

    /// 把頭像框縮放到現在這顆頭的大小。差不到 6% 就不動，免得一直抖。
    private func follow(in size: CGSize) {
        guard let face = turnedFace(in: size) else { return }
        let side = min(size.width, size.height)
        guard side > 0 else { return }
        let wanted = FaceDetectionService.head(from: face).width / side
        let next = min(Self.maxFraction, max(Self.minFraction, wanted))
        if abs(next - fraction) / fraction > 0.06 {
            fraction = next
        }
    }

    /// 臉的位置是用「直放的螢幕」座標回報的。橫放時這個 view 被轉了 90 度，要換算成 view 自己的座標才能比。
    private func turnedFace(in size: CGSize) -> CGRect? {
        guard let face = faces.faceRect else { return nil }
        if angle > 0 {
            // 螢幕寬 = size.height
            return CGRect(x: face.minY, y: size.height - face.maxX, width: face.height, height: face.width)
        }
        if angle < 0 {
            // 螢幕高 = size.width
            return CGRect(x: size.width - face.maxY, y: face.minX, width: face.height, height: face.width)
        }
        return face
    }
}

/// 脖子和肩膀。尺寸全部從頭的大小推，比例才會像一個人：脖子約頭寬的一半，肩寬約頭寬的 2.4 倍。
private struct ShoulderShape: Shape {
    var headMidX: CGFloat
    var headMaxY: CGFloat
    var headWidth: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(headMidX, AnimatablePair(headMaxY, headWidth)) }
        set {
            headMidX = newValue.first
            headMaxY = newValue.second.first
            headWidth = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = headWidth
        let h = headWidth * FaceDetectionService.headAspect
        let neckTop = headMaxY - h * 0.07
        let neckBottom = headMaxY + h * 0.10
        let shoulderEnd = headMaxY + h * 0.48
        let sides: [CGFloat] = [-1, 1]
        for side in sides {
            path.move(to: CGPoint(x: headMidX + side * w * 0.27, y: neckTop))
            path.addLine(to: CGPoint(x: headMidX + side * w * 0.28, y: neckBottom))
            path.addCurve(
                to: CGPoint(x: headMidX + side * w * 1.2, y: shoulderEnd),
                control1: CGPoint(x: headMidX + side * w * 0.34, y: neckBottom + h * 0.14),
                control2: CGPoint(x: headMidX + side * w * 1.14, y: neckBottom + h * 0.08)
            )
        }
        return path
    }
}
