import CoreImage
import CoreGraphics
import CoreVideo
import Foundation
import Metal

/// 畫面處理共用的 Metal 資源。錄影（videoQueue）和預覽（預覽佇列）用同一個 CIContext，
/// CIContext 本身可以跨執行緒使用。
enum CameraGPU {
    /// 影格是 709 的 SDR。工作色彩空間也用 709，等於直接在 gamma 編碼後的數值上運算：
    /// 1. 分析（LookAnalyzer）和濾鏡看到的是同一組數字。
    /// 2. 輸入、輸出不用來回換算，比較省電。
    /// 用 CoreMedia 的 709：原生預覽和播放器都照它的曲線顯示。標準的 709 曲線會把暗部顯示得比較亮。
    /// 有名字的那個 iOS 18 才有，舊系統改向 CoreVideo 要同一條曲線，要不到才退回標準的 709。
    static let colorSpace: CGColorSpace = {
        if !forcesLegacy709, #available(iOS 18.0, *), let space = CGColorSpace(name: CGColorSpace.coreMedia709) {
            return space
        }
        if let space = videoColorSpace() { return space }
        return CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
    }()

    /// 測試用：模擬器上設 debugForceLegacy709，就走 iOS 17 那條路，好比對兩條路的灰階。
    private static var forcesLegacy709: Bool {
        #if targetEnvironment(simulator)
        return UserDefaults.standard.bool(forKey: "debugForceLegacy709")
        #else
        return false
        #endif
    }

    /// 標著 709 的影格，CoreVideo 會用哪個色彩空間解讀它。
    private static func videoColorSpace() -> CGColorSpace? {
        let attachments: [String: Any] = [
            kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        ]
        let made = unwrapped(CVImageBufferCreateColorSpaceFromAttachments(attachments as CFDictionary))
        // Core Image 的工作色彩空間和輸出都要 RGB、而且能當輸出。
        guard let space = made, space.model == .rgb, space.supportsOutput else { return nil }
        return space
    }

    // 這個函式在不同版本的 SDK 可能標成 Unmanaged，也可能直接是 CGColorSpace，兩種都接。
    private static func unwrapped(_ space: Unmanaged<CGColorSpace>?) -> CGColorSpace? {
        space?.takeRetainedValue()
    }

    private static func unwrapped(_ space: CGColorSpace?) -> CGColorSpace? {
        space
    }

    /// 影格的數值原封不動拿進來算，不讓 Core Image 依標籤猜色彩空間。
    static func image(_ pixelBuffer: CVPixelBuffer) -> CIImage {
        CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: CameraGPU.colorSpace])
    }

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
