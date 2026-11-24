import CoreGraphics
import Foundation

/// 一張縮小的原始影格（還沒套任何處理）。
struct LookSample {
    /// RGB 交錯，一列接一列，第一列是畫面最上面。數值是 709 gamma 編碼。
    let pixels: [UInt8]
    let width: Int
    let height: Int
    /// 臉的位置，0…1，原點在左上。沒看到臉是 nil。
    let face: CGRect?
}

/// 從一張影格量到的東西。亮度都是 gamma 編碼後的 0…1。
struct LookReading {
    var p1: Double
    var p5: Double
    var p50: Double
    var p95: Double
    var p99: Double
    /// 過曝（快要全白）的面積比例
    var clipped: Double
    /// 平均顏色濃度（最大色減最小色）
    var saturation: Double
    /// 中間亮度、顏色淡的地方的平均色，沒有臉時拿來判斷偏色
    var gray: LookMath.RGB?

    var hasFace: Bool
    var faceLuma: Double
    var faceColor: LookMath.RGB
    /// 臉上過曝的比例
    var faceClipped: Double
}

/// 相機當時的狀態。
struct LookContext {
    /// 現在的曝光補償（EV）
    var exposure: Double
    var iso: Double
    var maxISO: Double
    /// 目前曝光離目標差多少 EV，負的代表拉不到該有的亮度
    var exposureOffset: Double
    /// 影格短邊的像素數，1080 或 2160
    var shortSide: Int
}

/// 一鍵優化的判斷。全是純函式，不碰相機也不碰 GPU，餵像素陣列和數值就能測。
enum LookAnalyzer {
    /// 臉的目標亮度與不用動的範圍
    static let faceTarget: Double = 0.60
    static let faceComfort: ClosedRange<Double> = 0.53...0.66
    static let exposureLimit: Double = 1.2
    static let colorLimit: Double = 45
    static let colorLimitWithoutFace: Double = 20

    // MARK: - 量測

    static func measure(_ sample: LookSample) -> LookReading? {
        let count = sample.width * sample.height
        guard count >= 64, sample.pixels.count >= count * 3 else { return nil }

        var histogram = [Int](repeating: 0, count: 256)
        var clipped = 0
        var saturationSum: Double = 0
        var graySum = SIMD3<Double>(0, 0, 0)
        var grayCount = 0

        sample.pixels.withUnsafeBufferPointer { pixels in
            for index in 0..<count {
                let base = index * 3
                let r = Double(pixels[base]) / 255
                let g = Double(pixels[base + 1]) / 255
                let b = Double(pixels[base + 2]) / 255
                let y: Double = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let high: Double = max(r, max(g, b))
                let low: Double = min(r, min(g, b))
                histogram[min(255, max(0, Int(y * 255 + 0.5)))] += 1
                if high >= 0.985 && y >= 0.90 { clipped += 1 }
                saturationSum += high - low
                if y > 0.18 && y < 0.82 && (high - low) < 0.22 * max(high, 0.05) + 0.04 {
                    graySum += SIMD3<Double>(r, g, b)
                    grayCount += 1
                }
            }
        }

        var gray: LookMath.RGB?
        if grayCount > count / 20 {
            let mean: SIMD3<Double> = graySum / Double(grayCount)
            gray = LookMath.RGB(Float(mean.x), Float(mean.y), Float(mean.z))
        }
        let face: FaceMeasure? = sample.face.flatMap { measureFace(sample, face: $0) }

        return LookReading(
            p1: percentile(histogram, total: count, 0.01),
            p5: percentile(histogram, total: count, 0.05),
            p50: percentile(histogram, total: count, 0.50),
            p95: percentile(histogram, total: count, 0.95),
            p99: percentile(histogram, total: count, 0.99),
            clipped: Double(clipped) / Double(count),
            saturation: saturationSum / Double(count),
            gray: gray,
            hasFace: face != nil,
            faceLuma: face?.luma ?? 0,
            faceColor: face?.color ?? LookMath.RGB(0, 0, 0),
            faceClipped: face?.clipped ?? 0
        )
    }

    static func percentile(_ histogram: [Int], total: Int, _ fraction: Double) -> Double {
        let goal = Int((Double(total) * fraction).rounded(.up))
        var sum = 0
        for (value, amount) in histogram.enumerated() {
            sum += amount
            if sum >= max(1, goal) { return Double(value) / 255 }
        }
        return 1
    }

    private struct FaceMeasure {
        let luma: Double
        let color: LookMath.RGB
        let clipped: Double
    }

    private struct FacePixel {
        let luma: Double
        let color: SIMD3<Double>
    }

    /// 取臉中間那一塊（臉頰、鼻子、額頭），丟掉太暗的（眉眼、鼻孔、頭髮）和最亮的反光，再平均。
    private static func measureFace(_ sample: LookSample, face: CGRect) -> FaceMeasure? {
        let width = Double(sample.width)
        let height = Double(sample.height)
        // 橫著拿的時候臉是側的，四邊縮一樣多就不用管方向。
        let left = Int((Double(face.minX) + Double(face.width) * 0.2) * width)
        let right = Int((Double(face.minX) + Double(face.width) * 0.8) * width)
        let top = Int((Double(face.minY) + Double(face.height) * 0.18) * height)
        let bottom = Int((Double(face.minY) + Double(face.height) * 0.8) * height)
        let x0 = max(0, left)
        let x1 = min(sample.width, right)
        let y0 = max(0, top)
        let y1 = min(sample.height, bottom)
        guard x1 - x0 >= 4, y1 - y0 >= 4 else { return nil }

        var kept: [FacePixel] = []
        kept.reserveCapacity((x1 - x0) * (y1 - y0))
        var total = 0
        var clipped = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let base = (y * sample.width + x) * 3
                let r = Double(sample.pixels[base]) / 255
                let g = Double(sample.pixels[base + 1]) / 255
                let b = Double(sample.pixels[base + 2]) / 255
                let luma: Double = 0.2126 * r + 0.7152 * g + 0.0722 * b
                total += 1
                if max(r, max(g, b)) >= 0.985 { clipped += 1 }
                if luma > 0.03 && luma < 0.985 {
                    kept.append(FacePixel(luma: luma, color: SIMD3<Double>(r, g, b)))
                }
            }
        }
        guard total > 0 else { return nil }
        let clippedRatio = Double(clipped) / Double(total)
        guard kept.count >= 20 else {
            // 整張臉都白掉了：照樣要回報，曝光才會往下修。
            if clippedRatio > 0.5 {
                return FaceMeasure(luma: 0.97, color: LookMath.RGB(0, 0, 0), clipped: clippedRatio)
            }
            return nil
        }
        kept.sort { $0.luma < $1.luma }
        let from = Int(Double(kept.count) * 0.30)
        let to = max(from + 1, Int(Double(kept.count) * 0.88))
        var lumaSum: Double = 0
        var colorSum = SIMD3<Double>(0, 0, 0)
        for pixel in kept[from..<to] {
            lumaSum += pixel.luma
            colorSum += pixel.color
        }
        let n = Double(to - from)
        let color: SIMD3<Double> = colorSum / n
        return FaceMeasure(luma: lumaSum / n,
                           color: LookMath.RGB(Float(color.x), Float(color.y), Float(color.z)),
                           clipped: clippedRatio)
    }

    // MARK: - 曝光

    /// 依這次量到的結果，曝光補償該設多少（絕對值，不是再加多少）。
    static func exposureBias(current: Double, reading: LookReading) -> Double {
        var change: Double = 0
        if reading.hasFace {
            if !faceComfort.contains(reading.faceLuma) {
                // gamma 數值差幾倍，換成 EV 大約乘 2.2。只走八成，分兩次逼近。
                let wanted: Double = faceTarget / max(reading.faceLuma, 0.05)
                change = 2.2 * log2(wanted) * 0.8
            }
            if reading.faceClipped > 0.05 {
                change = min(change, -0.3 - min(0.5, reading.faceClipped * 2))
            }
        } else if reading.p50 < 0.36 || reading.p50 > 0.58 {
            let goal: Double = reading.p50 < 0.36 ? 0.42 : 0.52
            change = 2.2 * log2(goal / max(reading.p50, 0.05)) * 0.5
            change = min(max(change, -0.7), 0.7)
        }

        // 已經有一片死白就不要再往上加：2% 開始收，12% 完全不加。
        if change > 0 {
            let room: Double = 1 - min(max((reading.clipped - 0.02) / 0.10, 0), 1)
            change *= room
        }
        let bias: Double = min(max(current + change, -exposureLimit), exposureLimit)
        return (bias * 20).rounded() / 20
    }

    /// 補償開到底、感光度也快到頂，臉還是暗。
    static func isStillTooDark(reading: LookReading, context: LookContext) -> Bool {
        guard reading.hasFace, reading.faceLuma < 0.42 else { return false }
        let biasAtLimit: Bool = context.exposure >= exposureLimit - 0.1
        let isoRatio: Double = context.maxISO > 0 ? context.iso / context.maxISO : 0
        // 自動曝光通常不會用到感光度的最上限，過六成、或已經補不到目標亮度，就當到頂。
        let gainAtLimit: Bool = isoRatio >= 0.6 || context.exposureOffset <= -0.7
        return biasAtLimit && gainAtLimit
    }

    // MARK: - 其他參數

    /// 曝光穩定之後量到的結果 → 整組參數。柔膚不動，由呼叫端補回。
    static func params(reading: LookReading, context: LookContext) -> LookParams {
        var params = LookParams()
        params.exposure = context.exposure

        let color = balance(reading)
        params.temperature = color.temperature
        params.tint = color.tint
        params.highlights = tidy(highlights(reading))

        let stops: Double = stopsBelowMaxISO(context)
        params.denoise = tidy(denoise(stops: stops))
        params.shadows = tidy(shadows(reading, stops: stops))
        params.contrast = tidy(contrast(reading))
        params.vibrance = tidy(vibrance(reading))
        params.sharpen = tidy(sharpen(context, denoise: params.denoise))
        return params
    }

    /// 取整數；動不到 3 就當作不用動。
    private static func tidy(_ value: Double) -> Double {
        let whole: Double = value.rounded()
        return abs(whole) < 3 ? 0 : whole
    }

    private static func ramp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max((value - low) / (high - low), 0), 1)
    }

    /// 亮部：死白 0.5% 開始壓，亮區太滿再多壓一點。最多 -45。
    static func highlights(_ reading: LookReading) -> Double {
        let byClip: Double = 32 * ramp(reading.clipped, 0.005, 0.06)
        let byBright: Double = 13 * ramp(reading.p95, 0.88, 0.98)
        return -min(45, byClip + byBright)
    }

    /// 暗部：最暗的 5% 低於 0.09 才提。感光度高的時候提少一點，不然雜訊會跑出來。最多 28。
    static func shadows(_ reading: LookReading, stops: Double) -> Double {
        let need: Double = 1 - ramp(reading.p5, 0.02, 0.09)
        let noisy: Double = 1 - ramp(stops, 0.5, 3.0)
        return 28 * need * (1 - 0.5 * noisy)
    }

    /// 對比：看亮暗的距離。太平拉開（最多 16），太硬放軟（最多 -12）。
    static func contrast(_ reading: LookReading) -> Double {
        let spread: Double = reading.p95 - reading.p5
        if spread < 0.60 { return min(16, (0.60 - spread) * 70) }
        if spread > 0.86 { return -min(12, (spread - 0.86) * 90) }
        return 0
    }

    /// 自然飽和度：太淡補（最多 22），太濃收（最多 -12）。
    static func vibrance(_ reading: LookReading) -> Double {
        if reading.saturation < 0.17 { return min(22, (0.17 - reading.saturation) * 180) }
        if reading.saturation > 0.36 { return -min(12, (reading.saturation - 0.36) * 80) }
        return 0
    }

    /// 現在的感光度離上限還有幾檔。
    static func stopsBelowMaxISO(_ context: LookContext) -> Double {
        guard context.iso > 0, context.maxISO > 0 else { return 10 }
        return max(0, log2(context.maxISO / context.iso))
    }

    /// 降噪：離感光度上限 3.5 檔以內才開，越近越多，最多 45。
    static func denoise(stops: Double) -> Double {
        45 * (1 - ramp(stops, 0.5, 3.5))
    }

    /// 銳利：輕微。4K 本來就細，少一點；降噪開多少就扣一些。
    static func sharpen(_ context: LookContext, denoise: Double) -> Double {
        let base: Double = context.shortSide > 1200 ? 8 : 14
        return max(0, base - denoise * 0.25)
    }

    // MARK: - 色溫、色調

    /// 把候選的色溫色調套到量到的顏色上再量一次，找代價最小的那組。
    /// 倍率是線性的，套在平均色上和套在每個像素再平均是同一個結果。
    static func balance(_ reading: LookReading) -> (temperature: Double, tint: Double) {
        if reading.hasFace, LookMath.luma(reading.faceColor) > 0.05 {
            let color = reading.faceColor
            return search(limit: colorLimit) { temperature, tint in
                skinCost(color, temperature: temperature, tint: tint)
            }
        }
        if !reading.hasFace, let gray = reading.gray {
            return search(limit: colorLimitWithoutFace) { temperature, tint in
                grayCost(gray, temperature: temperature, tint: tint)
            }
        }
        return (0, 0)
    }

    private static func search(limit: Double,
                               cost: (Double, Double) -> Double) -> (temperature: Double, tint: Double) {
        var best: (temperature: Double, tint: Double) = (0, 0)
        var bestCost: Double = cost(0, 0)
        let steps = Int(limit)
        for temperature in stride(from: -steps, through: steps, by: 1) {
            for tint in stride(from: -steps, through: steps, by: 1) {
                let value: Double = cost(Double(temperature), Double(tint))
                if value < bestCost {
                    bestCost = value
                    best = (Double(temperature), Double(tint))
                }
            }
        }
        if abs(best.temperature) < 3 { best.temperature = 0 }
        if abs(best.tint) < 3 { best.tint = 0 }
        return best
    }

    /// 膚色離膚色線多遠。沿著線的方向是濃淡，容許一段範圍；垂直方向是偏綠或偏紅，越小越好。
    /// 最後一項偏好不要動，數值不夠明顯就不會調。
    static func skinCost(_ color: LookMath.RGB, temperature: Double, tint: Double) -> Double {
        let changed: LookMath.RGB = color * LookMath.gains(temperature: temperature, tint: tint)
        let y: Float = max(LookMath.luma(changed), 0.02)
        let plane: SIMD2<Float> = LookMath.chroma(changed) / y
        let cosine: Float = cosf(LookMath.skinAngle)
        let sine: Float = sinf(LookMath.skinAngle)
        let along = Double(plane.x * cosine + plane.y * sine)
        let across = Double(plane.y * cosine - plane.x * sine)

        var cost: Double = pow(across / 0.03, 2)
        if along < 0.11 { cost += pow((0.11 - along) / 0.03, 2) }
        if along > 0.25 { cost += pow((along - 0.25) / 0.03, 2) }
        let effort: Double = pow(temperature / colorLimit, 2) + pow(tint / colorLimit, 2)
        return cost + 0.8 * effort
    }

    /// 沒有臉時的灰世界，不動的偏好放重一點。
    static func grayCost(_ color: LookMath.RGB, temperature: Double, tint: Double) -> Double {
        let changed: LookMath.RGB = color * LookMath.gains(temperature: temperature, tint: tint)
        let y: Float = max(LookMath.luma(changed), 0.02)
        let plane: SIMD2<Float> = LookMath.chroma(changed) / y
        let cast: Double = pow(Double(plane.x) / 0.05, 2) + pow(Double(plane.y) / 0.05, 2)
        let effort: Double = pow(temperature / colorLimitWithoutFace, 2) + pow(tint / colorLimitWithoutFace, 2)
        return cast + 2 * effort
    }
}
