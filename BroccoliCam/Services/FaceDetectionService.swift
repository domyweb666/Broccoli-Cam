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
/// 開防抖時看到的畫面外圍被裁掉一圈，但這裡的座標還是沒裁的，會差幾個百分點，構圖判斷容得下。
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

    /// 整顆頭（頭髮到下巴）的高寬比。
    static let headAspect: CGFloat = 1.5

    /// 由臉部矩形推估整顆頭的範圍：下緣對齊下巴，往上補額頭和頭髮。
    /// 倍率是估的，真機上對不準就調這裡。
    static func head(from face: CGRect) -> CGRect {
        let width = face.width * 1.08
        let height = width * headAspect
        let bottom = face.maxY + face.height * 0.03
        return CGRect(x: face.midX - width / 2, y: bottom - height, width: width, height: height)
    }

    /// 寬容比較：看頭的位置，大小差太多（超出頭像框縮放範圍）才算沒對上。
    static func status(face: CGRect?, guide: CGRect) -> FramingStatus {
        guard let face, guide.width > 0, guide.height > 0 else { return .unknown }
        let head = Self.head(from: face)
        let dx = abs(head.midX - guide.midX) / guide.width
        let dy = abs(head.midY - guide.midY) / guide.height
        let ratio = head.width / guide.width
        if dx < 0.22 && dy < 0.18 && ratio > 0.65 && ratio < 1.5 {
            return .good
        }
        return .adjust
    }
}
