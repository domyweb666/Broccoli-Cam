import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import QuartzCore

/// 把處理過的影格畫到預覽上的 CAMetalLayer。
/// 在自己的佇列上畫，正在畫就丟掉新的一格，絕不讓錄影那條佇列等它。
final class MetalPreviewRenderer {
    private let queue = DispatchQueue(label: "org.domyweb.broccolicam.preview", qos: .userInteractive,
                                      autoreleaseFrequency: .workItem)
    private let lock = NSLock()
    private var layer: CAMetalLayer?
    private var size: CGSize = .zero
    private var busy = false
    private var drawnCount = 0
    private var skippedCount = 0

    /// 掛上（或拿掉）要畫的圖層。size 是 drawable 的像素大小。
    func setLayer(_ next: CAMetalLayer?, size nextSize: CGSize) {
        lock.lock()
        layer = next
        size = next == nil ? .zero : nextSize
        lock.unlock()
    }

    /// 預覽框大小變了。
    func noteSize(_ nextSize: CGSize) {
        lock.lock()
        if layer != nil { size = nextSize }
        lock.unlock()
    }

    /// 現在能不能畫。能畫就回傳 drawable 的大小，呼叫端拿來決定要算多大張；不能畫回 nil。
    func availableSize() -> CGSize? {
        lock.lock()
        defer { lock.unlock() }
        guard layer != nil, size.width >= 2, size.height >= 2 else { return nil }
        guard !busy else {
            skippedCount += 1
            return nil
        }
        return size
    }

    var counts: (drawn: Int, skipped: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (drawnCount, skippedCount)
    }

    /// image：直立、原點在 (0, 0) 的影格。mirrored：畫之前要不要左右翻。
    func submit(_ image: CIImage, mirrored: Bool) {
        lock.lock()
        guard let target = layer, !busy else {
            lock.unlock()
            return
        }
        busy = true
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            if !self.draw(image, mirrored: mirrored, on: target) {
                self.finish(success: false)
            }
        }
    }

    /// 回傳 false 代表這一格沒有送出去（拿不到 drawable 等等），由呼叫端解除忙碌。
    private func draw(_ image: CIImage, mirrored: Bool, on target: CAMetalLayer) -> Bool {
        guard let context = CameraGPU.context,
              let commandBuffer = CameraGPU.commandQueue?.makeCommandBuffer(),
              let drawable = target.nextDrawable() else { return false }
        let texture: MTLTexture = drawable.texture
        let width: Int = texture.width
        let height: Int = texture.height
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        let upright: CIImage = mirrored ? image.oriented(.upMirrored) : image
        let black: CIImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: bounds)
        let composed: CIImage = Self.fit(upright, in: bounds).composited(over: black)

        let destination = CIRenderDestination(width: width, height: height,
                                              pixelFormat: target.pixelFormat,
                                              commandBuffer: commandBuffer,
                                              mtlTextureProvider: { texture })
        destination.colorSpace = CameraGPU.colorSpace
        do {
            _ = try context.startTask(toRender: composed, from: bounds, to: destination, at: CGPoint.zero)
        } catch {
            return false
        }
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.finish(success: true)
        }
        commandBuffer.commit()
        return true
    }

    private func finish(success: Bool) {
        lock.lock()
        busy = false
        if success {
            drawnCount += 1
        } else {
            skippedCount += 1
        }
        lock.unlock()
    }

    /// 等比例放進框裡（和原生預覽的 resizeAspect 一樣）。
    /// 比例只差一點點（框的尺寸四捨五入）就填滿，邊上才不會有一條黑線。
    private static func fit(_ image: CIImage, in bounds: CGRect) -> CIImage {
        let extent: CGRect = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scaleX: CGFloat = bounds.width / extent.width
        let scaleY: CGFloat = bounds.height / extent.height
        let larger: CGFloat = max(scaleX, scaleY)
        let smaller: CGFloat = min(scaleX, scaleY)
        let nearlySame: Bool = (larger - smaller) / larger < 0.02
        let scale: CGFloat = nearlySame ? larger : smaller
        let moveX: CGFloat = (bounds.width - extent.width * scale) / 2 - extent.minX * scale
        let moveY: CGFloat = (bounds.height - extent.height * scale) / 2 - extent.minY * scale
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: moveX, ty: moveY)
        return image.transformed(by: transform).cropped(to: bounds)
    }
}
