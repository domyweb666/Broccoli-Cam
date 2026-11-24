import Foundation

/// 一句字幕是怎麼來的，決定要不要使用者確認。
enum CaptionStatus: String, Codable {
    /// 稿子和聲音對得上。
    case matched
    /// 只對上一部分，要使用者選稿子寫的還是聽到的。
    case uncertain
    /// 稿子有、聲音裡沒有。預設不燒。
    case missing
    /// 聲音裡有、稿子沒有。
    case extra
    /// 沒有稿子，整句是聽出來的。
    case heard
    /// 這一段辨識失敗，時間是猜的。不可以當成漏講。
    case unrecognized

    /// 一開始就要使用者看過的。
    var needsReview: Bool { self != .matched }
}

/// 一個詞和它在整支影片裡的時間（秒）。拆句時用來算切點。
struct CaptionWord: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double
}

/// 一句字幕。時間是接好之後整支影片的秒數。
struct CaptionLine: Codable, Equatable, Identifiable {
    var id = UUID()
    /// 會燒上去的字。
    var text: String
    /// 稿子寫的。沒有稿子、或是多講的句子是 nil。
    var scriptText: String?
    /// 聽到的。漏講的句子是 nil。
    var heardText: String?
    var start: Double
    var end: Double
    var status: CaptionStatus
    /// 不燒這一句。
    var isHidden = false
    /// 使用者看過了。
    var isConfirmed = false
    var words: [CaptionWord] = []

    /// 還擋著燒錄：要看過的句子，沒確認也沒隱藏。漏講的預設隱藏，但仍要看過一次。
    var blocksBurning: Bool { status.needsReview && !isConfirmed }
}

struct CaptionStyle: Codable, Equatable {
    enum Look: String, Codable, CaseIterable, Identifiable {
        /// 白字黑邊
        case outline
        /// 白字半透明黑底
        case box
        /// 黃字黑邊
        case yellow
        var id: String { rawValue }
        var label: String {
            switch self {
            case .outline: return "白字黑邊"
            case .box: return "白字黑底"
            case .yellow: return "黃字黑邊"
            }
        }
    }

    enum Size: String, Codable, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var label: String {
            switch self {
            case .small: return "小"
            case .medium: return "中"
            case .large: return "大"
            }
        }
    }

    enum Position: String, Codable, CaseIterable, Identifiable {
        case top, middle, bottom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .top: return "上"
            case .middle: return "中"
            case .bottom: return "下"
            }
        }
    }

    var look: Look = .outline
    var size: Size = .medium
    var position: Position = .bottom
}

/// 組成影片的一段。單支影片就只有一段。
struct CaptionClip: Codable, Equatable {
    /// 專案資料夾裡的檔名。
    var file: String
    /// 這一段裡保留的範圍（秒）。nil 是整段。
    var start: Double?
    var end: Double?
    /// 照著唸的稿子，沒有就是空字串。
    var script: String
}

/// 辨識的經過，給畫面提醒和除錯用。
struct CaptionRecognition: Codable, Equatable {
    /// 例如「裝置端」「連網」「沒有辨識」。
    var engine: String
    var onDevice: Bool
    /// 辨識失敗的時間範圍（整支影片的秒數）。
    var failedRanges: [ClosedRange<Double>] = []
    /// 稿子有多少比例的字找到了時間。沒有稿子是 nil。
    var coverage: Double?
}

enum CaptionResolution: String, Codable, CaseIterable, Identifiable {
    case hd1080, uhd4K
    var id: String { rawValue }
    var label: String { self == .hd1080 ? "1080p" : "4K" }
}

/// 一個字幕專案。原片留著，字幕隨時可以重改、重燒。存成專案資料夾裡的 project.json。
struct CaptionProject: Codable, Equatable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    var updatedAt = Date()
    var isLandscape: Bool
    /// 接好之後的總長（秒）。
    var duration: Double
    var clips: [CaptionClip]
    var lines: [CaptionLine] = []
    var style = CaptionStyle()
    var recognition: CaptionRecognition?
    /// 最近一次燒好的檔名（在專案資料夾裡）。
    var burnedFile: String?
    var burnedResolution: CaptionResolution?
    /// 這次燒完之後又改過字幕或樣式。
    var isBurnStale = false

    var script: String { clips.map(\.script).filter { !$0.isEmpty }.joined(separator: "\n") }
    var pendingCount: Int { lines.filter(\.blocksBurning).count }
    var canBurn: Bool { pendingCount == 0 && lines.contains { !$0.isHidden && !$0.text.isEmpty } }
    /// 真的會燒上去的句子，照時間排。
    var burnLines: [CaptionLine] {
        lines.filter { !$0.isHidden && !$0.text.isEmpty && $0.end > $0.start }.sorted { $0.start < $1.start }
    }
}
