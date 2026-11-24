import CoreImage
import CoreGraphics
import Metal

/// 畫面處理共用的 Metal 資源。錄影（videoQueue）和預覽（預覽佇列）用同一個 CIContext，
/// CIContext 本身可以跨執行緒使用。
enum CameraGPU {
    /// 影格是 709 的 SDR。工作色彩空間也用 709，等於直接在 gamma 編碼後的數值上運算：
    /// 1. 分析（LookAnalyzer）和濾鏡看到的是同一組數字。
    /// 2. 輸入、輸出不用來回換算，比較省電。
    static let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    static let commandQueue: MTLCommandQueue? = CameraGPU.device?.makeCommandQueue()

    static let context: CIContext? = {
        guard let queue = CameraGPU.commandQueue else { return nil }
        let options: [CIContextOption: Any] = [
            // 影片每格都不一樣，快取中間結果只會吃記憶體。
            .cacheIntermediates: false,
            .workingColorSpace: CameraGPU.colorSpace
        ]
        return CIContext(mtlCommandQueue: queue, options: options)
    }()

    static var isAvailable: Bool { context != nil }
}
