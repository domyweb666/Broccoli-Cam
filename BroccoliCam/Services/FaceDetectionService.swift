import Foundation
import CoreGraphics

enum FramingStatus {
    /// 沒偵測到臉：保持中性，不警告。
    case unknown
    case good
    case adjust
}

/// 「錄的時候不看自己」：什麼時候看得到自己。純邏輯，只看時間和臉。
struct SelfViewGate {
    /// 臉不見、或頭出了畫面這麼久就淡回來。
    static let outLimit: Double = 2
    /// 回到畫面裡這麼久再淡掉。
    static let inLimit: Double = 1

    private(set) var isHidden = false
    private var outSince: Double?
    private var inSince: Double?
    /// 還沒離開過畫面：開錄時人就在框裡，馬上可以淡掉。
    private var steady = true

    mutating func reset() {
        self = SelfViewGate()
    }

    /// 一直沒有臉就一直看得到。回傳現在要不要藏起來。
    mutating func update(time: Double, isInside: Bool) -> Bool {
        if isInside {
            outSince = nil
            let since: Double = inSince ?? time
            inSince = since
            if !isHidden, steady || time - since >= Self.inLimit { isHidden = true }
        } else {
            inSince = nil
            let since: Double = outSince ?? time
            outSince = since
            if !isHidden {
                steady = false
            } else if time - since >= Self.outLimit {
                isHidden = false
                steady = false
            }
        }
        return isHidden
    }

    /// 頭有沒有在畫面裡。超出一點點不算，倍率是估的。
    /// upright 是手機直放；橫放時臉的矩形是轉過的，推不出頭頂在哪邊，直接看臉。
    static func isInside(face: CGRect?, frame: CGSize, upright: Bool) -> Bool {
        guard let face, frame.width > 0, frame.height > 0 else { return false }
        let head: CGRect = upright ? FaceDetectionService.head(from: face) : face
        let slackX: CGFloat = head.width * 0.15
        let slackY: CGFloat = head.height * 0.15
        return head.minX >= -slackX && head.maxX <= frame.width + slackX
            && head.minY >= -slackY && head.maxY <= frame.height + slackY
    }
}

/// 錄影中每 0.2 秒問一次 SelfViewGate。臉不見的時候沒有新的回報，要自己計時。
final class SelfViewModel: ObservableObject {
    @Published private(set) var isHidden = false

    /// 自己的畫面現在多大、手機是不是直放，由畫面更新。
    var frame: CGSize = .zero
    var upright = true

    private var gate = SelfViewGate()
    private var timer: Timer?

    func start(faces: FaceDetectionService) {
        guard timer == nil else { return }
        gate.reset()
        let next = Timer(timeInterval: 0.2, repeats: true) { [weak self, weak faces] _ in
            self?.tick(face: faces?.faceRect)
        }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        gate.reset()
        if isHidden { isHidden = false }
    }

    private func tick(face: CGRect?) {
        var seen: CGRect? = face
        #if targetEnvironment(simulator)
        // 測試用：模擬器沒有臉。debugFakeFace 寫 in、out 或 none。錄影中改這個值也會生效。
        let width: CGFloat = frame.width
        switch UserDefaults.standard.string(forKey: "debugFakeFace") ?? "" {
        case "in": seen = CGRect(x: width * 0.35, y: frame.height * 0.35, width: width * 0.3, height: width * 0.3)
        case "out": seen = CGRect(x: -width * 0.2, y: frame.height * 0.35, width: width * 0.3, height: width * 0.3)
        case "none": seen = nil
        default: break
        }
        #endif
        let inside: Bool = SelfViewGate.isInside(face: seen, frame: frame, upright: upright)
        let hidden: Bool = gate.update(time: ProcessInfo.processInfo.systemUptime, isInside: inside)
        if hidden != isHidden { isHidden = hidden }
    }
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
