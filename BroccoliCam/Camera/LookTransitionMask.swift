import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Metal

/// 一鍵優化後預覽的過場（QC-0012）：用遮罩把舊樣子一步步換成新樣子，交界再疊一點亮光。
/// 只給預覽用，錄影寫檔不會經過這裡。
///
/// 座標都是 Core Image 的：原點在左下，y 越大越上面。預覽之後只會左右翻（鏡像），
/// 上下不會變，所以「由上往下」就是從 maxY 往 minY。
/// 濾鏡每次現做，不留狀態；只在 videoQueue 呼叫。
enum LookTransitionMask {
    /// 每種過場多長（秒）。.none 不做過場，回 nil。
    static func duration(of style: LookTransition) -> CFTimeInterval? {
        switch style {
        case .scan: return 0.9
        case .ripple: return 0.9
        case .blinds: return 1.0
        case .none: return nil
        }
    }

    /// before、after：同一張影格套舊、新參數的結果，大小一樣、原點在 (0, 0)。
    /// progress：0…1，還沒套緩動。focus：從臉擴散的圓心（Core Image 座標）。
    static func compose(before: CIImage, after: CIImage, style: LookTransition,
                        progress: CGFloat, focus: CGPoint) -> CIImage {
        let extent: CGRect = after.extent
        guard !extent.isInfinite, extent.width >= 4, extent.height >= 4 else { return after }
        let p: CGFloat = min(max(progress, 0), 1)
        switch style {
        case .scan:
            return scan(before: before, after: after, extent: extent, progress: p)
        case .ripple:
            return ripple(before: before, after: after, extent: extent, progress: p, focus: focus)
        case .blinds:
            return blinds(before: before, after: after, extent: extent, progress: p)
        case .none:
            return after
        }
    }

    // MARK: - 預熱

    private static let prewarmLock = NSLock()
    private static var prewarmed = false

    /// 第一次開一鍵優化時呼叫（任何執行緒）：在背景用很小的圖把百葉窗過場從頭到尾畫一遍，
    /// 讓 Core Image 先把這些組合編好，第一次真的播的時候比較不會卡幾格。
    /// 只做一次；畫進一張不顯示的小貼圖，不碰預覽圖層，也不碰錄影。
    /// 用的是預覽那組 CIContext（MetalPreviewRenderer 畫過場用的就是它），編好的才用得上。
    static func prewarmOnce() {
        prewarmLock.lock()
        let first: Bool = !prewarmed
        prewarmed = true
        prewarmLock.unlock()
        guard first else { return }
        DispatchQueue.global(qos: .utility).async {
            prewarm()
        }
    }

    private static func prewarm() {
        guard let context = CameraGPU.previewContext ?? CameraGPU.context,
              let device = CameraGPU.device else { return }
        let width = 72
        let height = 128
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width * 2,
                                                                  height: height * 2, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let bounds = CGRect(x: 0, y: 0, width: width * 2, height: height * 2)
        let before: CIImage = CIImage(color: CIColor(red: 0.35, green: 0.32, blue: 0.30)).cropped(to: extent)
        let after: CIImage = CIImage(color: CIColor(red: 0.55, green: 0.48, blue: 0.42)).cropped(to: extent)
        let black: CIImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: bounds)
        let focus = CGPoint(x: extent.midX, y: extent.maxY * 0.62)
        // 每 0.025 一格，涵蓋每一條開始翻、翻完的每個階段（條數變了，Core Image 的組合就不一樣）。
        for step in 1..<40 {
            let progress = CGFloat(step) / 40
            let composed: CIImage = compose(before: before, after: after, style: .blinds,
                                            progress: progress, focus: focus)
            // 和 MetalPreviewRenderer 一樣：鏡像、放大到框、四周補黑。
            let mirrored: CIImage = composed.oriented(.upMirrored)
            let origin: CGPoint = mirrored.extent.origin
            let shown: CIImage = mirrored
                .transformed(by: CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: -origin.x * 2, ty: -origin.y * 2))
                .cropped(to: bounds)
                .composited(over: black)
            let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
            destination.colorSpace = CameraGPU.colorSpace
            do {
                let task: CIRenderTask = try context.startTask(toRender: shown, from: bounds, to: destination,
                                                               at: CGPoint.zero)
                _ = try task.waitUntilCompleted()
            } catch {
                return
            }
        }
    }

    // MARK: - 三種過場

    /// 一條亮線從上緣外面掃到下緣外面，線以上是新的、以下是舊的。開頭和結尾都看不到線。
    private static func scan(before: CIImage, after: CIImage, extent: CGRect, progress: CGFloat) -> CIImage {
        let line: CGFloat = max(2, extent.height * 0.03)
        let soft: CGFloat = line * 0.5
        // 起點和終點都在畫面外一個光暈寬，第一格和最後一格才看不到半截亮線。
        let outside: CGFloat = line * 1.2
        let travel: CGFloat = extent.height + outside * 2
        let lineY: CGFloat = extent.maxY + outside - eased(progress) * travel

        let mask: CIImage = ramp(darkAt: lineY - soft, lightAt: lineY + soft, extent: extent)
        var image: CIImage = mixed(after, over: before, mask: mask, extent: extent)
        let halo: CIImage = band(centerY: lineY, halfWidth: line * 1.2, extent: extent)
        let core: CIImage = band(centerY: lineY, halfWidth: line * 0.4, extent: extent)
        image = lit(image, by: halo, color: accent, amount: 0.5, extent: extent)
        image = lit(image, by: core, color: white, amount: 0.85, extent: extent)
        return image
    }

    /// 從臉（或畫面中間偏上）一個柔邊圓往外擴，圓內新、圓外舊，邊緣一圈淡淡的亮光。
    private static func ripple(before: CIImage, after: CIImage, extent: CGRect, progress: CGFloat,
                               focus: CGPoint) -> CIImage {
        let shortSide: CGFloat = min(extent.width, extent.height)
        let soft: CGFloat = shortSide * 0.08
        let corners: [CGPoint] = [
            CGPoint(x: extent.minX, y: extent.minY), CGPoint(x: extent.maxX, y: extent.minY),
            CGPoint(x: extent.minX, y: extent.maxY), CGPoint(x: extent.maxX, y: extent.maxY)
        ]
        var far: CGFloat = 0
        for corner in corners {
            let dx: CGFloat = corner.x - focus.x
            let dy: CGFloat = corner.y - focus.y
            far = max(far, (dx * dx + dy * dy).squareRoot())
        }
        // 結尾時連最遠的角都在柔邊裡面，才不會最後一下跳過去。
        let radius: CGFloat = eased(progress) * (far + soft * 2)

        let mask: CIImage = disc(center: focus, inner: radius - soft, outer: radius, extent: extent)
        var image: CIImage = mixed(after, over: before, mask: mask, extent: extent)
        // 亮圈剛出現時淡入，越擴越淡。
        let fade: CGFloat = min(1, progress * 6) * (1 - eased(progress))
        guard fade > 0.01 else { return image }
        let edge: CGFloat = max(0, radius - soft * 0.5)
        let halo: CIImage = ring(center: focus, radius: edge, halfWidth: shortSide * 0.035, extent: extent)
        let core: CIImage = ring(center: focus, radius: edge, halfWidth: shortSide * 0.01, extent: extent)
        image = lit(image, by: halo, color: accent, amount: 0.55 * fade, extent: extent)
        image = lit(image, by: core, color: white, amount: 0.6 * fade, extent: extent)
        return image
    }

    /// 8 條橫條，由上往下錯開時間，每條各自一道由上往下的小 wipe。
    /// 每條 0.3、間隔 0.1：0.1 × 7 + 0.3 = 1，最後一條剛好在結尾翻完。
    private static func blinds(before: CIImage, after: CIImage, extent: CGRect, progress: CGFloat) -> CIImage {
        let count = 8
        let stagger: CGFloat = 0.1
        let each: CGFloat = 0.3
        let stripHeight: CGFloat = extent.height / CGFloat(count)

        var mask: CIImage = solid(0).cropped(to: extent)
        var haloMask: CIImage = solid(0).cropped(to: extent)
        var coreMask: CIImage = solid(0).cropped(to: extent)
        var hasLight = false
        for index in 0..<count {
            let local: CGFloat = (progress - CGFloat(index) * stagger) / each
            // 後面的條開始得更晚，這一條還沒開始，後面的也還沒。
            if local <= 0 { break }
            let q: CGFloat = eased(min(local, 1))
            // 邊界取整數像素，相鄰兩條翻完之後中間才不會留一條細縫。
            let top: CGFloat = (extent.maxY - CGFloat(index) * stripHeight).rounded()
            let bottom: CGFloat = index == count - 1
                ? extent.minY
                : (extent.maxY - CGFloat(index + 1) * stripHeight).rounded()
            let edge: CGFloat = (top - q * (top - bottom)).rounded()
            if top - edge >= 1 {
                let covered = CGRect(x: extent.minX, y: edge, width: extent.width, height: top - edge)
                mask = solid(1).cropped(to: covered).composited(over: mask)
            }
            guard q < 1 else { continue }
            // 正在翻的那條，交界有一道亮線，只畫在自己這條裡面。
            let strip = CGRect(x: extent.minX, y: bottom, width: extent.width, height: top - bottom)
            let strength: CGFloat = CGFloat(sin(Double.pi * Double(q)))
            let halo: CIImage = weighted(band(centerY: edge, halfWidth: stripHeight * 0.14, extent: strip),
                                         by: strength)
            let core: CIImage = weighted(band(centerY: edge, halfWidth: stripHeight * 0.04, extent: strip),
                                         by: strength)
            haloMask = halo.composited(over: haloMask)
            coreMask = core.composited(over: coreMask)
            hasLight = true
        }

        var image: CIImage = mixed(after, over: before, mask: mask, extent: extent)
        guard hasLight else { return image }
        image = lit(image, by: haloMask, color: accent, amount: 0.5, extent: extent)
        image = lit(image, by: coreMask, color: white, amount: 0.7, extent: extent)
        return image
    }

    // MARK: - 遮罩

    private static let white: (r: CGFloat, g: CGFloat, b: CGFloat) = (1, 1, 1)
    /// Theme.accent（柔和藕荷色）。這裡沒有 SwiftUI，直接寫數值。
    private static let accent: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.83, 0.65, 0.72)

    /// 三次方的 easeInOut。
    private static func eased(_ value: CGFloat) -> CGFloat {
        let x: CGFloat = min(max(value, 0), 1)
        if x < 0.5 { return 4 * x * x * x }
        let y: CGFloat = -2 * x + 2
        return 1 - y * y * y / 2
    }

    /// 灰色的無限大圖，呼叫端要裁。
    private static func solid(_ value: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value))
    }

    /// 直的漸層：y 在 darkAt 以下全黑、lightAt 以上全白。darkAt 比 lightAt 大就是反過來（上黑下白）。
    private static func ramp(darkAt: CGFloat, lightAt: CGFloat, extent: CGRect) -> CIImage {
        let gradient = CIFilter.smoothLinearGradient()
        gradient.point0 = CGPoint(x: extent.midX, y: darkAt)
        gradient.point1 = CGPoint(x: extent.midX, y: lightAt)
        gradient.color0 = CIColor(red: 0, green: 0, blue: 0)
        gradient.color1 = CIColor(red: 1, green: 1, blue: 1)
        let output: CIImage = gradient.outputImage ?? solid(0)
        return output.cropped(to: extent)
    }

    /// 一條橫的亮帶：centerY 最亮，往上下 halfWidth 淡到黑。
    private static func band(centerY: CGFloat, halfWidth: CGFloat, extent: CGRect) -> CIImage {
        let width: CGFloat = max(halfWidth, 0.5)
        let rising: CIImage = ramp(darkAt: centerY - width, lightAt: centerY, extent: extent)
        let falling: CIImage = ramp(darkAt: centerY + width, lightAt: centerY, extent: extent)
        return multiplied(rising, falling, extent: extent)
    }

    /// 柔邊圓：inner 以內全白、outer 以外全黑。
    private static func disc(center: CGPoint, inner: CGFloat, outer: CGFloat, extent: CGRect) -> CIImage {
        let start: CGFloat = max(0, inner)
        let end: CGFloat = max(outer, start + 0.5)
        return radial(center: center, from: start, to: end, insideWhite: true, extent: extent)
    }

    /// 一圈亮環：半徑 radius 最亮，往內外 halfWidth 淡到黑。
    private static func ring(center: CGPoint, radius: CGFloat, halfWidth: CGFloat, extent: CGRect) -> CIImage {
        let width: CGFloat = max(halfWidth, 0.5)
        // 內側：radius - width 以內黑，到 radius 變白（再往外都是白）。
        let innerStart: CGFloat = max(0, radius - width)
        let innerEnd: CGFloat = max(radius, innerStart + 0.5)
        let inside: CIImage = radial(center: center, from: innerStart, to: innerEnd, insideWhite: false, extent: extent)
        // 外側：radius 以內白，到 radius + width 變黑。
        let outside: CIImage = radial(center: center, from: radius, to: radius + width, insideWhite: true, extent: extent)
        return multiplied(inside, outside, extent: extent)
    }

    private static func radial(center: CGPoint, from start: CGFloat, to end: CGFloat, insideWhite: Bool,
                               extent: CGRect) -> CIImage {
        let gradient = CIFilter.radialGradient()
        gradient.center = center
        gradient.radius0 = Float(start)
        gradient.radius1 = Float(max(end, start + 0.5))
        let light = CIColor(red: 1, green: 1, blue: 1)
        let dark = CIColor(red: 0, green: 0, blue: 0)
        gradient.color0 = insideWhite ? light : dark
        gradient.color1 = insideWhite ? dark : light
        let output: CIImage = gradient.outputImage ?? solid(0)
        return output.cropped(to: extent)
    }

    private static func multiplied(_ first: CIImage, _ second: CIImage, extent: CGRect) -> CIImage {
        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = first
        multiply.backgroundImage = second
        let output: CIImage = multiply.outputImage ?? first
        return output.cropped(to: extent)
    }

    /// 灰階遮罩整體乘一個倍率（0…1）。
    private static func weighted(_ mask: CIImage, by amount: CGFloat) -> CIImage {
        tinted(mask, color: (amount, amount, amount))
    }

    /// 灰階乘上顏色，alpha 維持 1。
    private static func tinted(_ mask: CIImage, color: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = mask
        matrix.rVector = CIVector(x: min(max(color.r, 0), 1), y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: min(max(color.g, 0), 1), z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: min(max(color.b, 0), 1), w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return matrix.outputImage ?? mask
    }

    /// 遮罩白的地方用 top、黑的地方用 bottom。
    private static func mixed(_ top: CIImage, over bottom: CIImage, mask: CIImage, extent: CGRect) -> CIImage {
        let blend = CIFilter.blendWithMask()
        blend.inputImage = top
        blend.backgroundImage = bottom
        blend.maskImage = mask
        let output: CIImage = blend.outputImage ?? top
        return output.cropped(to: extent)
    }

    /// 用「濾色」疊上亮光：遮罩黑的地方完全不變，亮的地方往白推，不會過曝成一片。
    private static func lit(_ image: CIImage, by mask: CIImage, color: (r: CGFloat, g: CGFloat, b: CGFloat),
                            amount: CGFloat, extent: CGRect) -> CIImage {
        guard amount > 0.001 else { return image }
        let light: CIImage = tinted(mask, color: (color.r * amount, color.g * amount, color.b * amount))
        let screen = CIFilter.screenBlendMode()
        screen.inputImage = light
        screen.backgroundImage = image
        let output: CIImage = screen.outputImage ?? image
        return output.cropped(to: extent)
    }
}
