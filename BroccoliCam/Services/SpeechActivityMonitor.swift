import Foundation
import AVFoundation

/// 收音狀態與說話／停頓偵測。
/// 音量來源是相機音訊分流的 RMS（由 CameraService 提供），
/// 不另開 AVAudioEngine，避免兩套音訊管線搶麥克風。不做語意理解。
final class SpeechActivityMonitor: ObservableObject {
    enum MicStatus {
        case unknown
        case ok
        case noSignal
    }

    @Published private(set) var level: Float = -160
    @Published private(set) var micStatus: MicStatus = .unknown
    @Published private(set) var isSpeaking = false
    @Published private(set) var route = "—"

    /// 回傳目前平均音量（dBFS）；半秒沒收到音訊時回傳 nil。
    var levelProvider: (() -> Float?)?

    private var timer: Timer?
    private var startedAt = Date()
    private var lastSignalAt: Date?
    private var loudSince: Date?
    private var quietSince: Date?

    // 門檻（dBFS）。真機測試後可依回報調整。
    private let signalFloor: Float = -75
    private let speakOn: Float = -35
    private let speakOff: Float = -42

    func start() {
        guard timer == nil else { return }
        startedAt = Date()
        lastSignalAt = nil
        refreshRoute()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        micStatus = .unknown
        isSpeaking = false
    }

    func refreshRoute() {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        let text = inputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
        route = text.isEmpty ? "無輸入" : text
    }

    private func currentLevel() -> Float? {
        #if targetEnvironment(simulator)
        if let fake = fakeLevel() { return fake }
        #endif
        return levelProvider?()
    }

    #if targetEnvironment(simulator)
    /// 測試用：模擬器沒有聲音。debugFakeLevel 寫「音量x次數」，例如 20x30,70x10 是
    /// -20 dBFS 三秒、-70 一秒，一直重複；上下晃 4 dB，才不會被當成冷氣聲。
    private static let fakePattern: [Float] = {
        let text = UserDefaults.standard.string(forKey: "debugFakeLevel") ?? ""
        return text.split(separator: ",").flatMap { part -> [Float] in
            let pair = part.split(separator: "x")
            guard pair.count == 2, let level = Float(pair[0]), let count = Int(pair[1]) else { return [] }
            return Array(repeating: -level, count: count)
        }
    }()
    private var fakeIndex = 0

    private func fakeLevel() -> Float? {
        guard !Self.fakePattern.isEmpty else { return nil }
        fakeIndex += 1
        return Self.fakePattern[fakeIndex % Self.fakePattern.count] + (fakeIndex % 2 == 0 ? 4 : -4)
    }
    #endif

    private func tick() {
        let now = Date()
        guard let value = currentLevel() else {
            if level != -160 { level = -160 }
            if now.timeIntervalSince(startedAt) > 3, micStatus != .noSignal { micStatus = .noSignal }
            if isSpeaking { isSpeaking = false }
            return
        }
        level = value

        // 收音狀態
        if value > signalFloor {
            lastSignalAt = now
            if micStatus != .ok { micStatus = .ok }
        } else {
            let reference = lastSignalAt ?? startedAt
            if now.timeIntervalSince(reference) > 4, micStatus != .noSignal { micStatus = .noSignal }
        }

        // 說話／停頓（有延遲，避免抖動）
        if value > speakOn {
            quietSince = nil
            if loudSince == nil { loudSince = now }
            if !isSpeaking, let s = loudSince, now.timeIntervalSince(s) > 0.15 { isSpeaking = true }
        } else if value < speakOff {
            loudSince = nil
            if quietSince == nil { quietSince = now }
            if isSpeaking, let s = quietSince, now.timeIntervalSince(s) > 0.7 { isSpeaking = false }
        }
    }
}
