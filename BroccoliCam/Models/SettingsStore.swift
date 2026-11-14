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
        showDebug = (d.object(forKey: "showDebug") as? Bool) ?? false
    }

    var hasScript: Bool {
        !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 稿件依空行切出的各段。
    var segments: [String] {
        ScriptSegments.split(script)
    }
}
