import Foundation
import CoreGraphics

enum FramingStatus {
    /// 沒偵測到臉：保持中性，不警告。
    case unknown
    case good
    case adjust
}

/// 接收 AVCaptureMetadataOutput 回報的臉部矩形（已換算成預覽畫面座標）。
/// 只比較位置與大小，不辨識身份、不分析情緒、不處理影格。
final class FaceDetectionService: ObservableObject {
    @Published private(set) var faceRect: CGRect?

    private var clearWork: DispatchWorkItem?

    /// 必須在主執行緒呼叫。
    func update(_ rect: CGRect?) {
        clearWork?.cancel()
        faceRect = rect
        guard rect != nil else { return }
        // 一段時間沒有新回報就視為沒有臉。
        let work = DispatchWorkItem { [weak self] in
            self?.faceRect = nil
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// 寬容比較：臉部矩形只是近似，不等於完整頭部輪廓。
    static func status(face: CGRect?, guide: CGRect) -> FramingStatus {
        guard let face, guide.width > 0, guide.height > 0 else { return .unknown }
        let dx = abs(face.midX - guide.midX) / guide.width
        let dy = abs(face.midY - guide.midY) / guide.height
        let ratio = face.width / guide.width
        if dx < 0.28 && dy < 0.28 && ratio > 0.45 && ratio < 1.2 {
            return .good
        }
        return .adjust
    }
}
