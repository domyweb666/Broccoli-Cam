import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import simd

/// 逐點的色彩運算。全部在 gamma 編碼（709）後的 0…1 數值上算，
/// 分析（LookAnalyzer）和濾鏡（LookFilter 的 color cube）用的是同一份公式。
enum LookMath {
    typealias RGB = SIMD3<Float>

    static func luma(_ c: RGB) -> Float {
        let weights = RGB(0.2126, 0.7152, 0.0722)
        return simd_dot(c, weights)
    }

    static func clamp(_ value: Float, _ low: Float, _ high: Float) -> Float {
        min(max(value, low), high)
    }

    static func smoothstep(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let t: Float = clamp((value - low) / (high - low), 0, 1)
        return t * t * (3 - 2 * t)
    }

    /// 色溫、色調換成 RGB 倍率，亮度不變（灰色調完的亮度一樣）。
    /// 在 gamma 數值上乘一個倍率，約等於在線性光上乘它的 2.2 次方，所以和一般白平衡同一回事。
    static func gains(temperature: Double, tint: Double) -> RGB {
        let t = Float(temperature / 100)
        let n = Float(tint / 100)
        let redPower: Float = 0.16 * t + 0.05 * n
        let greenPower: Float = -0.10 * n
        let bluePower: Float = -0.18 * t + 0.05 * n
        let raw = RGB(expf(redPower), expf(greenPower), expf(bluePower))
        return raw / luma(raw)
    }

    /// 709 的色差。膚色不分深淺，在這個平面上都落在約 123° 那條線附近。
    static func chroma(_ c: RGB) -> SIMD2<Float> {
        let y: Float = luma(c)
        let cb: Float = (c.z - y) / 1.8556
        let cr: Float = (c.x - y) / 1.5748
        return SIMD2<Float>(cb, cr)
    }

    static let skinAngle: Float = 123 * Float.pi / 180

    /// 這個顏色有多像皮膚，0…1，邊緣是柔的。
    static func skinWeight(_ c: RGB) -> Float {
        let y: Float = luma(c)
        guard y > 0.08 else { return 0 }
        let plane: SIMD2<Float> = chroma(c)
        let amount: Float = simd_length(plane) / y
        guard amount > 0.02 else { return 0 }
        var difference: Float = abs(atan2f(plane.y, plane.x) - skinAngle)
        if difference > Float.pi { difference = 2 * Float.pi - difference }
        let degrees: Float = difference * 180 / Float.pi
        let hue: Float = 1 - smoothstep(14, 36, degrees)
        let enough: Float = smoothstep(0.03, 0.08, amount)
        let notTooMuch: Float = 1 - smoothstep(0.34, 0.48, amount)
        let bright: Float = smoothstep(0.10, 0.24, y)
        return hue * enough * notTooMuch * bright
    }

    /// 一組參數裡「逐點」的部分，先換算好再套。
    struct Recipe {
        private let gains: RGB
        private let hasGains: Bool
        private let highlights: Float
        private let shadows: Float
        private let contrast: Float
        private let vibrance: Float

        init(_ params: LookParams) {
            hasGains = params.temperature != 0 || params.tint != 0
            gains = hasGains ? LookMath.gains(temperature: params.temperature, tint: params.tint) : RGB(1, 1, 1)
            highlights = Float(params.highlights / 100)
            shadows = Float(params.shadows / 100)
            contrast = Float(params.contrast / 100)
            vibrance = Float(params.vibrance / 100)
        }

        var isIdentity: Bool {
            !hasGains && highlights == 0 && shadows == 0 && contrast == 0 && vibrance == 0
        }

        /// 亮度曲線。各段的係數都算過，拉到底也不會反轉（保持遞增）。
        func tone(_ y: Float) -> Float {
            var value: Float = y
            if highlights != 0 {
                // 亮部：0.4 以上才動，純白只動一半，白的地方才不會變灰。
                let rise: Float = LookMath.smoothstep(0.40, 0.85, y)
                let ease: Float = 1 - 0.45 * LookMath.smoothstep(0.85, 1.0, y)
                let strength: Float = highlights < 0 ? 0.16 : 0.10
                value += highlights * strength * rise * ease
            }
            if shadows != 0 {
                // 暗部：純黑不動，0.18 附近最多，0.6 以上不動。
                let rise: Float = LookMath.smoothstep(0, 0.18, y)
                let fall: Float = 1 - LookMath.smoothstep(0.18, 0.60, y)
                let strength: Float = shadows > 0 ? 0.16 : 0.10
                value += shadows * strength * rise * fall
            }
            value = LookMath.clamp(value, 0, 1)
            if contrast != 0 {
                // 對比：頭尾固定、中間變陡或變緩。
                let bend: Float = value * (1 - value) * (2 * value - 1)
                value += contrast * 0.6 * bend
            }
            return LookMath.clamp(value, 0, 1)
        }

        func apply(_ input: RGB) -> RGB {
            var c: RGB = input
            if hasGains {
                c = c * gains
            }
            if highlights != 0 || shadows != 0 || contrast != 0 {
                let y: Float = LookMath.luma(c)
                let target: Float = tone(LookMath.clamp(y, 0, 1))
                // 七成用倍率（保住顏色濃度），三成用加的（暗部提亮時雜訊顏色不會跟著放大）。
                let ratio: Float = target / max(y, 0.02)
                let scaled: RGB = c * ratio
                let shift: Float = target - y
                let moved: RGB = c + RGB(shift, shift, shift)
                c = scaled * Float(0.7) + moved * Float(0.3)
            }
            if vibrance != 0 {
                let high: Float = max(c.x, max(c.y, c.z))
                let low: Float = min(c.x, min(c.y, c.z))
                let saturation: Float = high > 0.001 ? (high - low) / high : 0
                let skin: Float = LookMath.skinWeight(c)
                var amount: Float
                if vibrance > 0 {
                    // 淡的顏色補多一點，已經很濃的少補，膚色只補四成。
                    amount = vibrance * 0.55 * (1 - LookMath.clamp(saturation, 0, 1)) * (1 - 0.6 * skin)
                } else {
                    amount = vibrance * 0.7 * (1 - 0.4 * skin)
                }
                amount = max(amount, -1)
                let y: Float = LookMath.luma(c)
                let gray = RGB(y, y, y)
                c = gray + (c - gray) * (1 + amount)
            }
            return c
        }
    }

    /// 把一個顏色函式做成 CIColorCube 的資料（紅變最快，再綠、再藍）。
    static func cubeData(size: Int, _ transform: (RGB) -> RGB) -> Data {
        var values = [Float](repeating: 1, count: size * size * size * 4)
        let step: Float = 1 / Float(size - 1)
        var index = 0
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let input = RGB(Float(red) * step, Float(green) * step, Float(blue) * step)
                    let output: RGB = transform(input)
                    values[index] = clamp(output.x, 0, 1)
                    values[index + 1] = clamp(output.y, 0, 1)
                    values[index + 2] = clamp(output.z, 0, 1)
                    index += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// 柔膚要用的臉的位置。
struct LookFace {
    /// Core Image 座標（原點在左下），和要處理的影像同一個尺度。
    var rect: CGRect
    /// 0…1。臉剛出現或剛消失時慢慢變化，柔膚才不會一閃一閃。
    var strength: CGFloat
}

/// 把 LookParams 套到一格影像上。參數是 0 的項目完全不進濾鏡鏈。
/// 濾鏡物件重複使用，所以只能在同一條佇列上用（videoQueue）。
///
/// 色溫、色調、亮部、暗部、對比、自然飽和度都是逐點運算，合成一張 color cube 一次查完。
/// 不用內建的 temperatureAndTint、highlightShadowAdjust：分析要在 CPU 上算出「套了會變怎樣」，
/// 內建濾鏡的公式沒有公開，自己定義公式兩邊才會一致，也只要一道 GPU 處理。
final class LookFilter {
    private static let cubeSize = 32

    /// 像皮膚的程度。只算一次。
    private static let skinCubeData: Data = LookMath.cubeData(size: cubeSize) { color in
        let weight: Float = LookMath.skinWeight(color)
        return LookMath.RGB(weight, weight, weight)
    }

    /// 兩張圖的差值 → 可以換掉的程度。差很多的是輪廓（眼睛、頭髮），保留原樣。
    private static let flatCubeData: Data = LookMath.cubeData(size: cubeSize) { difference in
        let most: Float = max(difference.x, max(difference.y, difference.z))
        let weight: Float = 1 - LookMath.smoothstep(0.05, 0.18, most)
        return LookMath.RGB(weight, weight, weight)
    }

    private let colorCube = CIFilter.colorCube()
    private var colorCubeKey: LookParams?
    private let skinCube = CIFilter.colorCube()
    private let flatCube = CIFilter.colorCube()
    private let noise = CIFilter.noiseReduction()
    private let sharpen = CIFilter.sharpenLuminance()
    private let blur = CIFilter.gaussianBlur()
    private let difference = CIFilter.differenceBlendMode()
    private let gradient = CIFilter.radialGradient()
    private let multiply = CIFilter.multiplyCompositing()
    private let maskAmount = CIFilter.colorMatrix()
    private let blend = CIFilter.blendWithMask()

    init() {
        skinCube.cubeDimension = Float(Self.cubeSize)
        skinCube.cubeData = Self.skinCubeData
        flatCube.cubeDimension = Float(Self.cubeSize)
        flatCube.cubeData = Self.flatCubeData
    }

    /// 這組參數在目前狀況下要不要做事。skipHeavy：過熱，降噪和柔膚先不做。
    static func hasWork(_ params: LookParams, skipHeavy: Bool) -> Bool {
        if params.sharpen > 0 { return true }
        if !LookMath.Recipe(params).isIdentity { return true }
        return !skipHeavy && usesHeavy(params)
    }

    static func usesHeavy(_ params: LookParams) -> Bool {
        params.denoise > 0 || params.smooth > 0
    }

    /// source：原點在 (0, 0) 的影格。scale：短邊是 1080 的幾倍，半徑類的參數跟著縮放，
    /// 4K、1080p、縮小的預覽看起來才會一樣。
    /// forPreview：只有預覽傳 true。預覽已經先縮到短邊 720，降噪照錄影的規則算，看到的強度才和錄出來的一樣。
    func apply(_ params: LookParams, to source: CIImage, face: LookFace?, scale: CGFloat,
               skipHeavy: Bool, forPreview: Bool) -> CIImage {
        let extent: CGRect = source.extent
        guard !extent.isInfinite, extent.width >= 4, extent.height >= 4 else { return source }
        var image: CIImage = source
        if params.denoise > 0, !skipHeavy {
            image = denoised(image, amount: Float(params.denoise / 100), extent: extent, scale: scale,
                             halved: forPreview)
        }
        image = colored(image, params: params)
        if params.smooth > 0, !skipHeavy, let face, face.strength > 0.01 {
            image = smoothed(image, amount: Float(params.smooth / 100), face: face, extent: extent)
        }
        if params.sharpen > 0 {
            image = sharpened(image, amount: Float(params.sharpen / 100), scale: scale)
        }
        return image.cropped(to: extent)
    }

    // MARK: - 色彩

    private func colored(_ image: CIImage, params: LookParams) -> CIImage {
        var key: LookParams = params
        key.exposure = 0
        key.denoise = 0
        key.sharpen = 0
        key.smooth = 0
        guard key != LookParams.neutral else { return image }
        if colorCubeKey != key {
            let recipe = LookMath.Recipe(key)
            colorCube.cubeDimension = Float(Self.cubeSize)
            colorCube.cubeData = LookMath.cubeData(size: Self.cubeSize) { recipe.apply($0) }
            colorCubeKey = key
        }
        colorCube.inputImage = image
        let output: CIImage? = colorCube.outputImage
        // 濾鏡會一直留著，放掉影格才不會佔住相機的緩衝區。
        colorCube.inputImage = nil
        return output ?? image
    }

    // MARK: - 降噪

    /// halved：目前沒用到，留著給之後真機量過再決定預覽要不要再省。
    private func denoised(_ image: CIImage, amount: Float, extent: CGRect, scale: CGFloat,
                          halved: Bool) -> CIImage {
        noise.noiseLevel = 0.01 + 0.06 * amount
        noise.sharpness = 0.3
        // 4K 直接做太重：縮一半算，平的地方換成降噪過的，輪廓留原圖。
        // 預覽不走這條：縮一半算出來比錄的更滑，看到的就和錄到的不一樣了。
        if scale > 1.3 {
            let factor: CGFloat = 0.5
            let smallExtent = CGRect(x: 0, y: 0, width: ceil(extent.width * factor), height: ceil(extent.height * factor))
            let small: CIImage = scaled(image, by: factor).cropped(to: smallExtent)
            noise.inputImage = small.clampedToExtent()
            let cleaned: CIImage? = noise.outputImage
            noise.inputImage = nil
            guard let result = cleaned?.cropped(to: smallExtent) else { return image }
            let restored: CIImage = scaled(result, by: 1 / factor).cropped(to: extent)
            // 和原圖比：縮小丟掉的細節（頭髮、衣服紋路）差值大，會留原圖。
            let mask: CIImage = weighted(flatMask(restored, image), by: 0.35 + 0.5 * amount)
            return mixed(restored, over: image, mask: mask)
        }
        noise.inputImage = image.clampedToExtent()
        let output: CIImage? = noise.outputImage
        noise.inputImage = nil
        return output?.cropped(to: extent) ?? image
    }

    // MARK: - 柔膚

    /// 在縮小圖上模糊，只換掉「像皮膚、在臉附近、又不是輪廓」的地方，而且不換滿，留一部分原本的紋理。
    private func smoothed(_ image: CIImage, amount: Float, face: LookFace, extent: CGRect) -> CIImage {
        let shortSide: CGFloat = min(extent.width, extent.height)
        let factor: CGFloat = min(1, 540 / shortSide)
        let smallExtent = CGRect(x: 0, y: 0, width: ceil(extent.width * factor), height: ceil(extent.height * factor))
        let small: CIImage = scaled(image, by: factor).cropped(to: smallExtent)

        let faceWidth: CGFloat = face.rect.width * factor
        blur.radius = Float(min(max(faceWidth * 0.022, 1.5), 9))
        blur.inputImage = small.clampedToExtent()
        let blurred: CIImage? = blur.outputImage
        blur.inputImage = nil
        guard let soft = blurred?.cropped(to: smallExtent) else { return image }

        skinCube.inputImage = soft
        let skin: CIImage? = skinCube.outputImage
        skinCube.inputImage = nil
        guard let skinMask = skin else { return image }

        let flat: CIImage = flatMask(soft, small)
        let ellipse: CIImage = faceMask(face.rect, factor: factor).cropped(to: smallExtent)
        let combined: CIImage = multiplied(multiplied(skinMask, flat), ellipse)
        let strength: Float = 0.85 * amount * Float(min(max(face.strength, 0), 1))
        let mask: CIImage = weighted(combined, by: strength).cropped(to: smallExtent)

        return mixed(scaled(soft, by: 1 / factor).cropped(to: extent), over: image,
                     mask: scaled(mask, by: 1 / factor).cropped(to: extent))
    }

    /// 臉附近的柔邊橢圓。臉部矩形大約是眉毛到下巴，往外放大到包住額頭和耳朵。
    private func faceMask(_ rect: CGRect, factor: CGFloat) -> CIImage {
        gradient.center = CGPoint.zero
        gradient.radius0 = 70
        gradient.radius1 = 100
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1)
        gradient.color1 = CIColor(red: 0, green: 0, blue: 0)
        let circle: CIImage = gradient.outputImage ?? CIImage(color: CIColor(red: 0, green: 0, blue: 0))
        let radiusX: CGFloat = max(rect.width * factor * 0.85, 1)
        let radiusY: CGFloat = max(rect.height * factor * 1.0, 1)
        let transform = CGAffineTransform(a: radiusX / 100, b: 0, c: 0, d: radiusY / 100,
                                          tx: rect.midX * factor, ty: rect.midY * factor)
        return circle.transformed(by: transform)
    }

    // MARK: - 銳利

    private func sharpened(_ image: CIImage, amount: Float, scale: CGFloat) -> CIImage {
        sharpen.sharpness = 0.9 * amount
        sharpen.radius = Float(max(0.8, 1.6 * scale))
        sharpen.inputImage = image.clampedToExtent()
        let output: CIImage? = sharpen.outputImage
        sharpen.inputImage = nil
        return output ?? image
    }

    // MARK: - 共用

    /// 縮放，邊緣往外延伸（結果是無限大，呼叫端要裁）。
    private func scaled(_ image: CIImage, by factor: CGFloat) -> CIImage {
        guard factor != 1 else { return image.clampedToExtent() }
        return image.clampedToExtent().transformed(by: CGAffineTransform(scaleX: factor, y: factor))
    }

    private func flatMask(_ first: CIImage, _ second: CIImage) -> CIImage {
        difference.inputImage = first
        difference.backgroundImage = second
        let gap: CIImage? = difference.outputImage
        difference.inputImage = nil
        difference.backgroundImage = nil
        flatCube.inputImage = gap
        let mask: CIImage? = flatCube.outputImage
        flatCube.inputImage = nil
        return mask ?? first
    }

    private func multiplied(_ first: CIImage, _ second: CIImage) -> CIImage {
        multiply.inputImage = first
        multiply.backgroundImage = second
        let output: CIImage? = multiply.outputImage
        multiply.inputImage = nil
        multiply.backgroundImage = nil
        return output ?? first
    }

    private func weighted(_ mask: CIImage, by amount: Float) -> CIImage {
        let value = CGFloat(min(max(amount, 0), 1))
        maskAmount.rVector = CIVector(x: value, y: 0, z: 0, w: 0)
        maskAmount.gVector = CIVector(x: 0, y: value, z: 0, w: 0)
        maskAmount.bVector = CIVector(x: 0, y: 0, z: value, w: 0)
        maskAmount.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        maskAmount.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        maskAmount.inputImage = mask
        let output: CIImage? = maskAmount.outputImage
        maskAmount.inputImage = nil
        return output ?? mask
    }

    private func mixed(_ top: CIImage, over bottom: CIImage, mask: CIImage) -> CIImage {
        blend.inputImage = top
        blend.backgroundImage = bottom
        blend.maskImage = mask
        let output: CIImage? = blend.outputImage
        blend.inputImage = nil
        blend.backgroundImage = nil
        blend.maskImage = nil
        return output ?? bottom
    }
}
