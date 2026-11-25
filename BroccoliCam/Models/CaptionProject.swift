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

/// 對上了、但講的可能和稿子不一樣。只標出來給人聽。
enum CaptionDoubt: String, Codable {
    /// 數字不一樣，或數字沒講到。
    case number
    /// 一字之差：相反字，或多一個、少一個「不」。
    case word
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
    /// 為什麼標出來。沒有就是 nil。
    var doubt: CaptionDoubt?
    /// 稿子寫的那個字或數字，例如「30%」。
    var doubtScript: String?
    /// 聽到的，例如「13%」。沒聽到是 nil。
    var doubtHeard: String?
    /// 那個字在第幾秒，和 start 同一個時間基準。
    var doubtTime: Double?

    /// 給人看的原因。
    var doubtNote: String? {
        guard doubt != nil, let doubtScript else { return nil }
        guard let doubtHeard else { return "稿子 \(doubtScript)，沒聽到" }
        return "稿子 \(doubtScript)，聽到 \(doubtHeard)"
    }

    /// 字改過了，原因就不一定對。
    mutating func clearDoubt() {
        doubt = nil
        doubtScript = nil
        doubtHeard = nil
        doubtTime = nil
    }

    /// 還擋著燒錄：要看過的句子，沒確認也沒隱藏。漏講的預設隱藏，但仍要看過一次。
    var blocksBurning: Bool { status.needsReview && !isConfirmed }
    /// 燒了看得到：沒藏起來、真的有字、有時間。平移到片外的會剩零長度，燒了也沒有。
    var isBurnable: Bool {
        !isHidden && end > start && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
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

/// 一段影片聽到的字。時間是影片檔自己的秒數，不管接片怎麼裁都能換算。
/// 錄完檢查時聽一次就存著，加字幕直接拿來用。
struct TakeHearing: Codable, Equatable {
    var words: [CaptionWord]
    /// 辨識失敗的時間範圍。
    var failed: [ClosedRange<Double>]
    /// 例如「裝置端」「連網」。
    var engine: String
    var onDevice: Bool
    /// 影片檔畫面的結尾在第幾秒，用來認是不是同一個檔。0 是不知道。
    var fileLength: Double
    /// 聽的是檔案的哪一段。
    var from: Double
    var to: Double

    /// 從頭到尾都聽成了，才可以拿來用。
    var isComplete: Bool {
        failed.isEmpty && fileLength > 0 && to > from
    }

    init(words: [CaptionWord], failed: [ClosedRange<Double>], engine: String, onDevice: Bool,
         fileLength: Double, from: Double, to: Double) {
        // 錄影清單用一般的 JSON 存，混進一個無限大就整份存不進去，這裡先濾掉。取到毫秒，檔案也小一點。
        self.words = words.filter { $0.start.isFinite && $0.end.isFinite }.map { word in
            CaptionWord(text: word.text, start: Self.rounded(word.start), end: Self.rounded(word.end))
        }
        self.failed = failed.filter { $0.lowerBound.isFinite && $0.upperBound.isFinite }
        self.engine = engine
        self.onDevice = onDevice
        let known = fileLength.isFinite && from.isFinite && to.isFinite
        self.fileLength = known ? fileLength : 0
        self.from = known ? from : 0
        self.to = known ? to : 0
    }

    /// 讀壞了就當成沒聽過，不可以連累整份錄影清單讀不進來。
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let words = try? box.decode([CaptionWord].self, forKey: .words)
        let failed = try? box.decode([ClosedRange<Double>].self, forKey: .failed)
        let length = try? box.decode(Double.self, forKey: .fileLength)
        let lower = try? box.decode(Double.self, forKey: .from)
        let upper = try? box.decode(Double.self, forKey: .to)
        let isWhole = words != nil && failed != nil
        self.init(words: words ?? [], failed: failed ?? [],
                  engine: (try? box.decode(String.self, forKey: .engine)) ?? "",
                  onDevice: (try? box.decode(Bool.self, forKey: .onDevice)) ?? false,
                  fileLength: isWhole ? (length ?? 0) : 0, from: lower ?? 0, to: upper ?? 0)
    }

    private enum CodingKeys: String, CodingKey {
        case words, failed, engine, onDevice, fileLength, from, to
    }

    private static func rounded(_ seconds: Double) -> Double {
        (seconds * 1000).rounded() / 1000
    }
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
    /// 錄完檢查時聽到的字。沒有檢查過、舊的專案是 nil。
    var hearing: TakeHearing?
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
    /// 整支都沒辨識到的原因（CaptionProblem）。部分失敗不寫。存成字串，之後加新的原因舊版也讀得進來。
    var problem: String?
}

/// 整支都沒辨識到的原因。
enum CaptionProblem: String {
    case noNetwork, unavailable, timedOut, noSound, failed

    var label: String {
        switch self {
        case .noNetwork: return "沒有網路，這次沒辨識到聲音"
        case .unavailable: return "這支手機現在不能辨識中文，這次沒辨識到聲音"
        case .timedOut: return "語音辨識沒有回應，這次沒辨識到聲音"
        case .noSound: return "讀不到影片的聲音，這次沒辨識到"
        case .failed: return "語音辨識失敗，這次沒辨識到聲音"
        }
    }
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
    var canBurn: Bool { pendingCount == 0 && lines.contains(where: \.isBurnable) }
    /// 真的會燒上去的句子，照時間排。
    var burnLines: [CaptionLine] {
        lines.filter(\.isBurnable).sorted { $0.start < $1.start }
    }
}
