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

/// 使用者偏好。全部存在 UserDefaults，改了就寫入。
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

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

    @Published var showGuide: Bool { didSet { defaults.set(showGuide, forKey: "showGuide") } }
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

    /// 陪伴模式：不看稿，畫面上有一位聆聽者。關閉就是提詞模式。
    @Published var companionMode: Bool { didSet { defaults.set(companionMode, forKey: "companionMode") } }
    /// 陪伴模式的聆聽者擺法
    @Published var companionLayout: CompanionLayout { didSet { defaults.set(companionLayout.rawValue, forKey: "companionLayout") } }
    /// 手機橫放時錄橫式 16:9
    @Published var autoLandscape: Bool { didSet { defaults.set(autoLandscape, forKey: "autoLandscape") } }

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
        showGuide = (d.object(forKey: "showGuide") as? Bool) ?? true
        guideScale = (d.object(forKey: "guideScale") as? Double) ?? 1.0
        countdown = (d.object(forKey: "countdown") as? Int) ?? 3
        speechRate = (d.object(forKey: "speechRate") as? Double) ?? 220
        waitOnPause = (d.object(forKey: "waitOnPause") as? Bool) ?? true
        trimSilence = (d.object(forKey: "trimSilence") as? Bool) ?? true
        voiceFollow = (d.object(forKey: "voiceFollow") as? Bool) ?? true
        subtitleMaxChars = (d.object(forKey: "subtitleMaxChars") as? Double) ?? 14
        companionMode = (d.object(forKey: "companionMode") as? Bool) ?? false
        companionLayout = CompanionLayout(rawValue: d.string(forKey: "companionLayout") ?? "") ?? .fullCall
        autoLandscape = (d.object(forKey: "autoLandscape") as? Bool) ?? true
        showDebug = (d.object(forKey: "showDebug") as? Bool) ?? false
    }

    var hasScript: Bool {
        !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 現在要不要顯示提詞：有稿子，而且不是陪伴模式。
    var usesPrompter: Bool {
        hasScript && !companionMode
    }

    /// 錄影流程實際要用的稿子。陪伴模式不看稿。
    var activeScript: String {
        companionMode ? "" : script
    }

    /// 稿件依空行切出的各段。
    var segments: [String] {
        ScriptSegments.split(script)
    }
}
