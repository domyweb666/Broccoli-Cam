import Foundation
import CoreGraphics

enum VideoResolution: String, CaseIterable, Identifiable {
    case hd1080
    case uhd4k

    var id: String { rawValue }
    var label: String { self == .uhd4k ? "4K" : "1080p" }
    var width: Int32 { self == .uhd4k ? 3840 : 1920 }
    var height: Int32 { self == .uhd4k ? 2160 : 1080 }
}

/// 陪伴模式裡聆聽者放在哪裡。每種都做，多米在真機上切著比。
/// 共同規則：自己的畫面一定是完整的 9:16，看到頭在哪，錄出來就在哪。
enum CompanionLayout: String, CaseIterable, Identifiable {
    /// 鏡頭下方一個小圓（原本的做法）
    case circle
    /// 鏡頭下方一張 9:16 小卡
    case topCard
    /// 聆聽者滿版，自己縮在角落（像視訊通話）
    case fullCall
    /// 鏡頭正下方一條她的眼睛，自己滿版
    case eyeStrip
    /// 她在上、自己完整的 9:16 畫面在下，互不遮擋
    case fullFrame
    /// 開錄前自己滿版對位，開錄後她滿版、自己縮成小窗
    case alignFirst

    var id: String { rawValue }

    var label: String {
        switch self {
        case .circle: return "圓形頭像"
        case .topCard: return "頂部小窗"
        case .fullCall: return "視訊通話"
        case .eyeStrip: return "眼神條"
        case .fullFrame: return "完整取景"
        case .alignFirst: return "對位再開講"
        }
    }
}

/// 錄的時候看多少字。和有沒有人聽分開選。
enum PromptAmount: String, CaseIterable, Identifiable {
    /// 整篇稿子照著唸
    case full
    /// 只看每一點的關鍵字，用自己的話講
    case outline
    /// 不看稿
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full: return "全稿"
        case .outline: return "提綱"
        case .none: return "不看"
        }
    }
}

/// 三位聆聽者。不取名字，畫面上只用頭像分辨。
enum CompanionPerson: String, CaseIterable, Identifiable {
    case a, b, c

    var id: String { rawValue }

    var accessibilityName: String {
        switch self {
        case .a: return "聆聽者 1"
        case .b: return "聆聽者 2"
        case .c: return "聆聽者 3"
        }
    }
}

/// 播放器和反應狀態機直接看 UserDefaults 的變化，主畫面不用在中間轉手。
/// 屬性名稱要和存的鍵一模一樣，KVO 才收得到。
extension UserDefaults {
    @objc dynamic var companionPerson: String? { string(forKey: "companionPerson") }
    @objc dynamic var instantReaction: Bool { (object(forKey: "instantReaction") as? Bool) ?? true }
}

/// 構圖輔助線。只畫在預覽上，不會錄進影片。
enum GuideStyle: String, CaseIterable, Identifiable {
    case off
    case head
    case grid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "關"
        case .head: return "頭像框"
        case .grid: return "九宮格"
        }
    }

    /// 主畫面按一下換下一種。
    var next: GuideStyle {
        switch self {
        case .off: return .head
        case .head: return .grid
        case .grid: return .off
        }
    }
}

/// 防抖強度。裝置不支援的不會列出來。
enum StabilizationLevel: String, CaseIterable, Identifiable {
    case off
    case standard
    case strong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "關"
        case .standard: return "標準"
        case .strong: return "加強"
        }
    }
}

/// 按了一鍵優化後，預覽從舊樣子換成新樣子的過場（QC-0012）。只畫在預覽上，不會錄進影片。
/// 三種都做，多米在真機上切著比。
enum LookTransition: String, CaseIterable, Identifiable {
    /// 一條亮線從上往下掃，掃過的地方變成新的樣子
    case scan
    /// 從臉（畫面中間偏上）往外一圈圈擴散
    case ripple
    /// 像百葉窗，一條條橫的由上往下翻成新的
    case blinds
    /// 不要過場，直接換
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scan: return "由上往下掃"
        case .ripple: return "從臉擴散"
        case .blinds: return "百葉窗"
        case .none: return "不要"
        }
    }
}

/// 跳轉一次跳多遠。
enum JumpMode: String, CaseIterable, Identifiable {
    case paragraph
    case line

    var id: String { rawValue }
    var label: String { self == .paragraph ? "逐段" : "逐行" }
}

/// 使用者偏好。全部存在 UserDefaults，改了就寫入。
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    /// 正在用的那篇稿子的內文。列表在 ScriptLibrary，這裡是它的鏡像，由 ScriptLibrary 寫入。
    @Published var script: String { didSet { defaults.set(script, forKey: "script") } }

    @Published var resolution: VideoResolution { didSet { defaults.set(resolution.rawValue, forKey: "resolution") } }
    @Published var fps: Int { didSet { defaults.set(fps, forKey: "fps") } }
    @Published var mirrorOutput: Bool { didSet { defaults.set(mirrorOutput, forKey: "mirrorOutput") } }

    /// 提詞字級（pt）
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    /// 提詞速度（pt／秒）
    @Published var speed: Double { didSet { defaults.set(speed, forKey: "speed") } }
    /// 提詞底色不透明度 0–0.9
    @Published var promptBackground: Double { didSet { defaults.set(promptBackground, forKey: "promptBackground") } }
    @Published var autoStartPrompter: Bool { didSet { defaults.set(autoStartPrompter, forKey: "autoStartPrompter") } }

    @Published var guideStyle: GuideStyle { didSet { defaults.set(guideStyle.rawValue, forKey: "guideStyle") } }
    /// 構圖線的濃淡 0.2–1，頭像框和九宮格共用
    @Published var guideOpacity: Double { didSet { defaults.set(guideOpacity, forKey: "guideOpacity") } }
    /// 頭像框大小倍率 0.7–1.4
    @Published var guideScale: Double { didSet { defaults.set(guideScale, forKey: "guideScale") } }

    /// 錄影倒數秒數：0／3／5／10
    @Published var countdown: Int { didSet { defaults.set(countdown, forKey: "countdown") } }

    /// 語速（字／分鐘），用來估算稿件時長
    @Published var speechRate: Double { didSet { defaults.set(speechRate, forKey: "speechRate") } }
    /// 錄影中停頓時，提詞自動暫停，開口再繼續
    @Published var waitOnPause: Bool { didSet { defaults.set(waitOnPause, forKey: "waitOnPause") } }
    /// 接片時裁掉每段頭尾沒有聲音的部分
    @Published var trimSilence: Bool { didSet { defaults.set(trimSilence, forKey: "trimSilence") } }

    /// 提詞跟著聲音走（語音辨識），唸過的字會變色。還沒在真機驗過。
    @Published var voiceFollow: Bool { didSet { defaults.set(voiceFollow, forKey: "voiceFollow") } }
    /// 字幕每行最多幾個字
    @Published var subtitleMaxChars: Double { didSet { defaults.set(subtitleMaxChars, forKey: "subtitleMaxChars") } }
    /// 燒進影片的字幕，直式一行最多幾個字
    @Published var captionCharsPortrait: Double {
        didSet { defaults.set(captionCharsPortrait, forKey: "captionCharsPortrait") }
    }
    /// 燒進影片的字幕，橫式一行最多幾個字
    @Published var captionCharsLandscape: Double {
        didSet { defaults.set(captionCharsLandscape, forKey: "captionCharsLandscape") }
    }
    /// 新的字幕專案用的樣式。已經建好的專案各自記各自的
    @Published var captionStyle: CaptionStyle {
        didSet {
            if let data = try? JSONEncoder().encode(captionStyle) { defaults.set(data, forKey: "captionStyle") }
        }
    }

    /// 看多少字
    @Published var promptAmount: PromptAmount { didSet { defaults.set(promptAmount.rawValue, forKey: "promptAmount") } }
    /// 畫面上有沒有一位聆聽者
    @Published var hasListener: Bool { didSet { defaults.set(hasListener, forKey: "hasListener") } }
    /// 聆聽者擺法
    @Published var companionLayout: CompanionLayout { didSet { defaults.set(companionLayout.rawValue, forKey: "companionLayout") } }
    /// 選哪一位聆聽者
    @Published var companionPerson: CompanionPerson { didSet { defaults.set(companionPerson.rawValue, forKey: "companionPerson") } }
    /// 聆聽者跟著講話的停頓和音量反應。關掉就是隨機點頭
    @Published var instantReaction: Bool { didSet { defaults.set(instantReaction, forKey: "instantReaction") } }
    /// 開錄後看不到自己，跑出框才淡回來
    @Published var hideSelf: Bool { didSet { defaults.set(hideSelf, forKey: "hideSelf") } }
    /// 用 AirPods 高品質收音（iOS 26 以上才有作用）
    @Published var airPodsMic: Bool { didSet { defaults.set(airPodsMic, forKey: "airPodsMic") } }
    /// 錄完一段自動檢查漏講和講錯的數字
    @Published var takeCheck: Bool { didSet { defaults.set(takeCheck, forKey: "takeCheck") } }
    /// 手機橫放時錄橫式 16:9
    @Published var autoLandscape: Bool { didSet { defaults.set(autoLandscape, forKey: "autoLandscape") } }

    /// 稿件編輯頁的字級倍率 0.8–1.8
    @Published var scriptTextScale: Double { didSet { defaults.set(scriptTextScale, forKey: "scriptTextScale") } }
    /// 用空行分段錄。關掉就整篇一鏡到底
    @Published var segmentedRecording: Bool { didSet { defaults.set(segmentedRecording, forKey: "segmentedRecording") } }
    /// 跳轉一次跳一段或一行
    @Published var jumpMode: JumpMode { didSet { defaults.set(jumpMode.rawValue, forKey: "jumpMode") } }
    @Published var stabilization: StabilizationLevel { didSet { defaults.set(stabilization.rawValue, forKey: "stabilization") } }
    /// 畫面優化的參數。lookEnabled 關著就不套
    @Published var look: LookParams {
        didSet {
            if let data = try? JSONEncoder().encode(look) { defaults.set(data, forKey: "look") }
        }
    }
    @Published var lookEnabled: Bool { didSet { defaults.set(lookEnabled, forKey: "lookEnabled") } }
    /// 一鍵優化套上去時的過場
    @Published var lookTransition: LookTransition {
        didSet { defaults.set(lookTransition.rawValue, forKey: "lookTransition") }
    }
    /// 主畫面側邊也放構圖線、防抖兩顆（QC-0012 起預設收進設定，只留語音跟隨和一鍵優化）
    @Published var showAllQuickToggles: Bool {
        didSet { defaults.set(showAllQuickToggles, forKey: "showAllQuickToggles") }
    }
    /// 藍牙踏板、翻頁器的按鍵對應
    @Published var remoteBindings: RemoteBindings {
        didSet {
            if let data = try? JSONEncoder().encode(remoteBindings) { defaults.set(data, forKey: "remoteBindings") }
        }
    }

    @Published var showDebug: Bool { didSet { defaults.set(showDebug, forKey: "showDebug") } }

    init() {
        let d = UserDefaults.standard
        script = d.string(forKey: "script") ?? ""
        resolution = VideoResolution(rawValue: d.string(forKey: "resolution") ?? "") ?? .hd1080
        fps = (d.object(forKey: "fps") as? Int) ?? 30
        mirrorOutput = (d.object(forKey: "mirrorOutput") as? Bool) ?? false
        fontSize = (d.object(forKey: "fontSize") as? Double) ?? 26
        speed = (d.object(forKey: "speed") as? Double) ?? 36
        promptBackground = (d.object(forKey: "promptBackground") as? Double) ?? 0.45
        autoStartPrompter = (d.object(forKey: "autoStartPrompter") as? Bool) ?? true
        if let raw = d.string(forKey: "guideStyle"), let style = GuideStyle(rawValue: raw) {
            guideStyle = style
        } else {
            // 舊版只有「顯示頭像框」一個開關。
            guideStyle = ((d.object(forKey: "showGuide") as? Bool) ?? true) ? .head : .off
        }
        guideOpacity = (d.object(forKey: "guideOpacity") as? Double) ?? 0.85
        guideScale = (d.object(forKey: "guideScale") as? Double) ?? 1.0
        countdown = (d.object(forKey: "countdown") as? Int) ?? 3
        speechRate = (d.object(forKey: "speechRate") as? Double) ?? 220
        waitOnPause = (d.object(forKey: "waitOnPause") as? Bool) ?? true
        trimSilence = (d.object(forKey: "trimSilence") as? Bool) ?? true
        voiceFollow = (d.object(forKey: "voiceFollow") as? Bool) ?? true
        subtitleMaxChars = (d.object(forKey: "subtitleMaxChars") as? Double) ?? 14
        captionCharsPortrait = (d.object(forKey: "captionCharsPortrait") as? Double) ?? 12
        captionCharsLandscape = (d.object(forKey: "captionCharsLandscape") as? Double) ?? 18
        captionStyle = d.data(forKey: "captionStyle")
            .flatMap { try? JSONDecoder().decode(CaptionStyle.self, from: $0) } ?? CaptionStyle()
        // 舊版只有「提詞／陪伴」一個開關：陪伴等於不看稿加有人聽。
        let wasCompanion = (d.object(forKey: "companionMode") as? Bool) ?? false
        promptAmount = PromptAmount(rawValue: d.string(forKey: "promptAmount") ?? "") ?? (wasCompanion ? .none : .full)
        hasListener = (d.object(forKey: "hasListener") as? Bool) ?? wasCompanion
        companionLayout = CompanionLayout(rawValue: d.string(forKey: "companionLayout") ?? "") ?? .fullCall
        companionPerson = CompanionPerson(rawValue: d.string(forKey: "companionPerson") ?? "") ?? .a
        instantReaction = (d.object(forKey: "instantReaction") as? Bool) ?? true
        hideSelf = (d.object(forKey: "hideSelf") as? Bool) ?? false
        airPodsMic = (d.object(forKey: "airPodsMic") as? Bool) ?? false
        takeCheck = (d.object(forKey: "takeCheck") as? Bool) ?? true
        autoLandscape = (d.object(forKey: "autoLandscape") as? Bool) ?? true
        scriptTextScale = (d.object(forKey: "scriptTextScale") as? Double) ?? 1.0
        segmentedRecording = (d.object(forKey: "segmentedRecording") as? Bool) ?? true
        jumpMode = JumpMode(rawValue: d.string(forKey: "jumpMode") ?? "") ?? .paragraph
        stabilization = StabilizationLevel(rawValue: d.string(forKey: "stabilization") ?? "") ?? .off
        look = d.data(forKey: "look").flatMap { try? JSONDecoder().decode(LookParams.self, from: $0) } ?? .neutral
        lookEnabled = (d.object(forKey: "lookEnabled") as? Bool) ?? false
        lookTransition = LookTransition(rawValue: d.string(forKey: "lookTransition") ?? "") ?? .scan
        showAllQuickToggles = (d.object(forKey: "showAllQuickToggles") as? Bool) ?? false
        remoteBindings = d.data(forKey: "remoteBindings")
            .flatMap { try? JSONDecoder().decode(RemoteBindings.self, from: $0) } ?? .standard
        showDebug = (d.object(forKey: "showDebug") as? Bool) ?? false
    }

    var hasScript: Bool {
        !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 現在要不要顯示提詞：有稿子，而且沒有選不看。
    var usesPrompter: Bool {
        hasScript && promptAmount != .none
    }

    /// 錄影流程實際要用的稿子。選不看就沒有。
    var activeScript: String {
        promptAmount == .none ? "" : script
    }
}
