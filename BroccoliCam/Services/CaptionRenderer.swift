import CoreGraphics
import CoreImage
import CoreText
import CoreVideo
import Foundation

/// 把一句字幕畫成圖。校對頁的預覽和燒錄用同一張，看到的就是會燒的。
enum CaptionRenderer {
    /// 已經放在畫布上該在的位置（Core Image 座標，原點左下），直接疊到影格上就好。沒有字就回 nil。
    static func image(text: String, style: CaptionStyle, canvas: CGSize) -> CIImage? {
        bitmap(text: text, style: style, canvas: canvas)?.image
    }

    /// 同一句字每一格都會要一次，畫好的留著。任何執行緒都能叫。
    static func bitmap(text: String, style: CaptionStyle, canvas: CGSize) -> CaptionBitmap? {
        let width = Int(canvas.width.rounded())
        let height = Int(canvas.height.rounded())
        guard width >= 16, height >= 16 else { return nil }
        let options = "\(style.look.rawValue)|\(style.size.rawValue)|\(style.position.rawValue)"
        let key = "\(width)x\(height)|\(options)|\(text)" as NSString
        if let kept = cache.object(forKey: key) { return kept }
        guard let made = draw(text: text, style: style, width: width, height: height) else { return nil }
        cache.setObject(made, forKey: key, cost: made.byteCount)
        return made
    }

    /// NSCache 本身可以跨執行緒。改字時每打一個字就是一張新的，所以要有上限。
    private static let cache: NSCache<NSString, CaptionBitmap> = {
        let cache = NSCache<NSString, CaptionBitmap>()
        cache.countLimit = 60
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    // MARK: - 尺寸（em 是字級，其他都是字級的倍數）

    private static let fontName = "PingFangTC-Semibold"
    /// 中文字的字框：基線上 0.88、下 0.12。不用字型自己的上下緣，英文、表情符號混進來位置才不會跳。
    private static let ascent: CGFloat = 0.88
    private static let lineStep: CGFloat = 1.3
    /// 描邊向外的寬度。
    private static let outline: CGFloat = 0.075
    private static let boxPadX: CGFloat = 0.4
    private static let boxPadY: CGFloat = 0.26
    private static let boxRadius: CGFloat = 0.28
    /// 圖的四周多留的空間，裝得下描邊和英文下緣。
    private static let margin: CGFloat = 0.4
    /// 一行最多縮到這個倍率，再小就改兩行。
    private static let minimumScale: CGFloat = 0.7

    /// 以畫布寬為準的比例。直式 12 字、最大級還放得進安全區。
    private static func fontRatio(_ size: CaptionStyle.Size, portrait: Bool) -> CGFloat {
        switch size {
        case .small: return portrait ? 0.046 : 0.027
        case .medium: return portrait ? 0.055 : 0.032
        case .large: return portrait ? 0.064 : 0.038
        }
    }

    /// 字幕塊的上緣（從畫面最上面往下算）。
    private static func blockTop(_ position: CaptionStyle.Position, portrait: Bool,
                                 canvasHeight: CGFloat, blockHeight: CGFloat) -> CGFloat {
        switch position {
        case .top:
            return canvasHeight * (portrait ? 0.14 : 0.08)
        case .middle:
            return (canvasHeight - blockHeight) / 2
        case .bottom:
            return canvasHeight * (portrait ? 0.65 : 0.92) - blockHeight
        }
    }

    // MARK: - 畫

    private struct Row {
        let line: CTLine
        let width: CGFloat
    }

    private static func draw(text: String, style: CaptionStyle, width: Int, height: Int) -> CaptionBitmap? {
        let texts: [String] = cleaned(text)
        guard !texts.isEmpty else { return nil }
        let canvasWidth = CGFloat(width)
        let canvasHeight = CGFloat(height)
        let portrait: Bool = height >= width
        let isBox: Bool = style.look == .box

        let baseSize: CGFloat = canvasWidth * fontRatio(style.size, portrait: portrait)
        let safeWidth: CGFloat = canvasWidth * (portrait ? 0.78 : 0.84)
        // 底框和描邊也要在安全區裡。
        let edge: CGFloat = isBox ? boxPadX : outline
        let available: CGFloat = safeWidth - 2 * edge * baseSize
        let fitted = fit(texts, baseSize: baseSize, available: available)
        guard !fitted.rows.isEmpty else { return nil }

        let em: CGFloat = fitted.size
        let padX: CGFloat = isBox ? boxPadX * em : 0
        let padY: CGFloat = isBox ? boxPadY * em : 0
        let textWidth: CGFloat = fitted.rows.map(\.width).max() ?? 0
        let textHeight: CGFloat = em + CGFloat(fitted.rows.count - 1) * lineStep * em
        guard textWidth > 0 else { return nil }

        let blockWidth: CGFloat = textWidth + 2 * padX
        let blockHeight: CGFloat = textHeight + 2 * padY
        let top: CGFloat = blockTop(style.position, portrait: portrait,
                                    canvasHeight: canvasHeight, blockHeight: blockHeight)
        let block = CGRect(x: (canvasWidth - blockWidth) / 2, y: top, width: blockWidth, height: blockHeight)

        // 影格的顏色是兩個像素一組，位置和大小都對齊偶數，直接疊上去才不會有色邊。
        let room: CGFloat = margin * em
        let left: Int = max(0, evenDown(block.minX - room))
        let upper: Int = max(0, evenDown(block.minY - room))
        let right: Int = min(width - width % 2, evenUp(block.maxX + room))
        let lower: Int = min(height - height % 2, evenUp(block.maxY + room))
        let imageWidth: Int = right - left
        let imageHeight: Int = lower - upper
        guard imageWidth >= 2, imageHeight >= 2 else { return nil }

        let rowBytes: Int = imageWidth * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * imageHeight)
        let drawn: Bool = pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: imageWidth, height: imageHeight,
                                          bitsPerComponent: 8, bytesPerRow: rowBytes,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            // 畫布座標（原點左上）換成這張圖的座標（原點左下）。
            let bottomUp: CGFloat = CGFloat(imageHeight) + CGFloat(upper)
            if isBox {
                let rect = CGRect(x: block.minX - CGFloat(left), y: bottomUp - block.maxY,
                                  width: block.width, height: block.height)
                drawBox(rect, radius: boxRadius * em, in: context)
            }
            for (index, row) in fitted.rows.enumerated() {
                let rowTop: CGFloat = block.minY + padY + CGFloat(index) * lineStep * em
                let baseline: CGFloat = rowTop + ascent * em
                let origin = CGPoint(x: (canvasWidth - row.width) / 2 - CGFloat(left), y: bottomUp - baseline)
                if !isBox {
                    strokeOutline(of: row.line, at: origin, width: outline * em * 2, in: context)
                }
                fill(row.line, at: origin, look: style.look, in: context)
            }
            return true
        }
        guard drawn else { return nil }
        return CaptionBitmap(pixels: pixels, x: left, y: upper, width: imageWidth, height: imageHeight,
                             canvasWidth: width, canvasHeight: height)
    }

    private static func evenDown(_ value: CGFloat) -> Int {
        Int((value / 2).rounded(.down)) * 2
    }

    private static func evenUp(_ value: CGFloat) -> Int {
        Int((value / 2).rounded(.up)) * 2
    }

    private static func drawBox(_ rect: CGRect, radius: CGFloat, in context: CGContext) {
        let corner: CGFloat = min(radius, rect.width / 2, rect.height / 2)
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.6)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
        context.fillPath()
    }

    /// 先把整行的外框描完再填字，隔壁字的描邊才不會蓋到前一個字。轉角用圓的，尖角不會裂出去。
    private static func strokeOutline(of line: CTLine, at origin: CGPoint, width: CGFloat, in context: CGContext) {
        let path = CGMutablePath()
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        for run in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName as String] else { continue }
            let font = value as! CTFont
            let count: Int = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for index in 0..<count {
                // 表情符號沒有外框，就不描。
                guard let glyph = CTFontCreatePathForGlyph(font, glyphs[index], nil) else { continue }
                let move = CGAffineTransform(translationX: origin.x + positions[index].x,
                                             y: origin.y + positions[index].y)
                path.addPath(glyph, transform: move)
            }
        }
        guard !path.isEmpty else { return }
        context.addPath(path)
        context.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.setLineWidth(width)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.strokePath()
    }

    private static func fill(_ line: CTLine, at origin: CGPoint, look: CaptionStyle.Look, in context: CGContext) {
        switch look {
        case .outline, .box:
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        case .yellow:
            context.setFillColor(red: 1, green: 0.86, blue: 0.16, alpha: 1)
        }
        context.setTextDrawingMode(.fill)
        context.textMatrix = .identity
        context.textPosition = origin
        CTLineDraw(line, context)
    }

    // MARK: - 排版

    /// 使用者自己換行就照他的，最多兩行，多的併到第二行。
    private static func cleaned(_ text: String) -> [String] {
        let parts: [String] = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count > 2 else { return parts }
        return [parts[0], parts.dropFirst().joined(separator: " ")]
    }

    /// 一行放得下就一行；放不下先縮，縮到底還不行才拆成兩行。
    private static func fit(_ texts: [String], baseSize: CGFloat, available: CGFloat) -> (rows: [Row], size: CGFloat) {
        var wanted: [String] = texts
        if texts.count == 1 {
            let whole: Row = row(texts[0], size: baseSize)
            if whole.width * minimumScale > available + 0.5 {
                wanted = split(texts[0], size: baseSize)
            }
        }
        let widest: CGFloat = wanted.map { row($0, size: baseSize).width }.max() ?? 0
        guard widest > 0 else { return ([], baseSize) }
        let scale: CGFloat = widest > available + 0.5 ? available / widest : 1
        let size: CGFloat = baseSize * scale
        return (wanted.map { row($0, size: size) }, size)
    }

    private static func row(_ text: String, size: CGFloat) -> Row {
        let line: CTLine = CTLineCreateWithAttributedString(attributed(text, size: size))
        return Row(line: line, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    /// 在中間偏後找一個可以斷的地方（不切英文，標點不放行首）。
    private static func split(_ text: String, size: CGFloat) -> [String] {
        let string = text as NSString
        guard string.length >= 2 else { return [text] }
        let typesetter: CTTypesetter = CTTypesetterCreateWithAttributedString(attributed(text, size: size))
        let width = Double(row(text, size: size).width)
        var cut: Int = CTTypesetterSuggestLineBreak(typesetter, 0, width * 0.56)
        if cut <= 0 || cut >= string.length {
            cut = string.rangeOfComposedCharacterSequence(at: string.length / 2).location
        }
        guard cut > 0, cut < string.length else { return [text] }
        let parts: [String] = [string.substring(to: cut), string.substring(from: cut)]
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func attributed(_ text: String, size: CGFloat) -> CFAttributedString {
        let font: CTFont = CTFontCreateWithName(fontName as CFString, size, nil)
        let attributes: [String: Any] = [
            kCTFontAttributeName as String: font,
            // 顏色由畫布決定。
            kCTForegroundColorFromContextAttributeName as String: true,
            // 缺字借別的字型時，要借繁體的字形。
            kCTLanguageAttributeName as String: "zh-Hant"
        ]
        return CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attributes as CFDictionary)
    }
}

/// 畫好的一句字幕。x、y 是在畫布上的位置（原點左上），連同寬高都是偶數。
final class CaptionBitmap: @unchecked Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let canvasWidth: Int
    let canvasHeight: Int
    /// 放在畫布位置上的圖，給 Core Image 用。
    let image: CIImage
    let byteCount: Int

    // 疊到 YCbCr 影格上用的：新值 = 原值 × keep ÷ 255 + add。先算好，每格只剩乘加。
    private let lumaKeep: [UInt8]
    private let lumaAdd: [UInt8]
    private let chromaKeep: [UInt8]
    private let chromaAdd: [UInt8]

    /// pixels 是 RGBA、已經乘過透明度、第一列在最上面。數值直接當成 709 的 RGB，和影格同一套。
    init(pixels: [UInt8], x: Int, y: Int, width: Int, height: Int, canvasWidth: Int, canvasHeight: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        byteCount = pixels.count * 2

        // 色彩空間和工作空間一樣，Core Image 不會再換算，黃就是這個黃。
        let flat = CIImage(bitmapData: Data(pixels), bytesPerRow: width * 4,
                           size: CGSize(width: width, height: height),
                           format: .RGBA8, colorSpace: CameraGPU.colorSpace)
        image = flat.transformed(by: CGAffineTransform(translationX: CGFloat(x),
                                                       y: CGFloat(canvasHeight - y - height)))

        let halfWidth: Int = width / 2
        let cells: Int = halfWidth * (height / 2)
        var keep = [UInt8](repeating: 255, count: width * height)
        var add = [UInt8](repeating: 0, count: width * height)
        // 2×2 像素一格，先加總再平均。
        var alphaSum = [Float](repeating: 0, count: cells)
        var cbSum = [Float](repeating: 0, count: cells)
        var crSum = [Float](repeating: 0, count: cells)

        pixels.withUnsafeBufferPointer { (source: UnsafeBufferPointer<UInt8>) in
            for row in 0..<height {
                for column in 0..<width {
                    let index: Int = row * width + column
                    let alphaByte: UInt8 = source[index * 4 + 3]
                    if alphaByte == 0 { continue }
                    let red = Float(source[index * 4])
                    let green = Float(source[index * 4 + 1])
                    let blue = Float(source[index * 4 + 2])
                    let alpha: Float = Float(alphaByte) / 255
                    let luma: Float = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                    let scaled: Float = 16 * alpha + luma * 219 / 255
                    keep[index] = 255 - alphaByte
                    add[index] = Self.byte(scaled)

                    let cell: Int = (row / 2) * halfWidth + column / 2
                    let cb: Float = (blue - luma) / 1.8556 * 224 / 255
                    let cr: Float = (red - luma) / 1.5748 * 224 / 255
                    alphaSum[cell] += alpha
                    cbSum[cell] += 128 * alpha + cb
                    crSum[cell] += 128 * alpha + cr
                }
            }
        }

        var colorKeep = [UInt8](repeating: 255, count: cells)
        var colorAdd = [UInt8](repeating: 0, count: cells * 2)
        for cell in 0..<cells where alphaSum[cell] > 0 {
            colorKeep[cell] = Self.byte(255 - alphaSum[cell] * 255 / 4)
            colorAdd[cell * 2] = Self.byte(cbSum[cell] / 4)
            colorAdd[cell * 2 + 1] = Self.byte(crSum[cell] / 4)
        }
        lumaKeep = keep
        lumaAdd = add
        chromaKeep = colorKeep
        chromaAdd = colorAdd
    }

    /// 直接疊到影格上：字以外的像素完全不動，也不用顯示晶片，所以在背景也能做。
    /// 影格要是 420v、大小和畫布一樣，不合就回 false。
    func blend(onto buffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetWidth(buffer) == canvasWidth,
              CVPixelBufferGetHeight(buffer) == canvasHeight,
              CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return false }
        blendLuma(lumaBase, rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
        blendChroma(chromaBase, rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
        return true
    }

    private func blendLuma(_ base: UnsafeMutableRawPointer, rowBytes: Int) {
        lumaKeep.withUnsafeBufferPointer { (keep: UnsafeBufferPointer<UInt8>) in
            lumaAdd.withUnsafeBufferPointer { (add: UnsafeBufferPointer<UInt8>) in
                for row in 0..<height {
                    let start: Int = (y + row) * rowBytes + x
                    let target = (base + start).assumingMemoryBound(to: UInt8.self)
                    for column in 0..<width {
                        let index: Int = row * width + column
                        let kept: UInt8 = keep[index]
                        if kept == 255 { continue }
                        target[column] = Self.mix(target[column], kept, add[index])
                    }
                }
            }
        }
    }

    private func blendChroma(_ base: UnsafeMutableRawPointer, rowBytes: Int) {
        let halfWidth: Int = width / 2
        let halfHeight: Int = height / 2
        chromaKeep.withUnsafeBufferPointer { (keep: UnsafeBufferPointer<UInt8>) in
            chromaAdd.withUnsafeBufferPointer { (add: UnsafeBufferPointer<UInt8>) in
                for row in 0..<halfHeight {
                    let start: Int = (y / 2 + row) * rowBytes + x
                    let target = (base + start).assumingMemoryBound(to: UInt8.self)
                    for column in 0..<halfWidth {
                        let index: Int = row * halfWidth + column
                        let kept: UInt8 = keep[index]
                        if kept == 255 { continue }
                        target[column * 2] = Self.mix(target[column * 2], kept, add[index * 2])
                        target[column * 2 + 1] = Self.mix(target[column * 2 + 1], kept, add[index * 2 + 1])
                    }
                }
            }
        }
    }

    private static func byte(_ value: Float) -> UInt8 {
        UInt8(max(0, min(255, value.rounded())))
    }

    @inline(__always)
    private static func mix(_ value: UInt8, _ keep: UInt8, _ add: UInt8) -> UInt8 {
        let product: UInt32 = UInt32(value) * UInt32(keep) + 128
        let scaled: UInt32 = (product + (product >> 8)) >> 8
        return UInt8(min(255, scaled + UInt32(add)))
    }
}
