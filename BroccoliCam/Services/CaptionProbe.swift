import Foundation
import Speech

/// 第 0 期的檢測：這支手機有哪些中文辨識可以用。結果要能從除錯資訊複製回來。
enum CaptionProbe {
    private static let lock = NSLock()
    private static var stored = "字幕辨識檢測：還沒跑"

    /// 最近一次的結果，貼在除錯資訊的「複製」內容後面。
    static var lastReport: String {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// 跑一次檢測，一行一行印出來（主執行緒）。不會跳權限視窗，也不下載模型。
    static func report(log: @escaping (String) -> Void) {
        Task {
            let result = await lines()
            store(result.joined(separator: "\n"))
            await MainActor.run {
                for line in result { log(line) }
            }
        }
    }

    private static func store(_ text: String) {
        lock.lock()
        stored = text
        lock.unlock()
    }

    static func lines() async -> [String] {
        let wanted = SpeechFollower.locale
        var result = ["字幕辨識檢測：" + ProcessInfo.processInfo.operatingSystemVersionString]
        #if targetEnvironment(simulator)
        result.append("（模擬器，不準）")
        #endif

        if let recognizer = SFSpeechRecognizer(locale: wanted) {
            result.append("舊引擎 SFSpeech zh-TW：可用 \(mark(recognizer.isAvailable))"
                + "，裝置端 \(mark(recognizer.supportsOnDeviceRecognition))，實際語言 \(describe(recognizer.locale))")
        } else {
            result.append("舊引擎 SFSpeech zh-TW：沒有這個語言")
        }
        result.append("語音辨識權限：\(permission())")

        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            result.append(contentsOf: await newEngines(wanted))
        } else {
            result.append("新引擎：系統不到 iOS 26")
        }
        #else
        result.append("新引擎：這一版不是用 Xcode 26 編的，查不了")
        #endif
        return result
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private static func newEngines(_ wanted: Locale) async -> [String] {
        var result: [String] = []
        let speech = await SpeechTranscriber.supportedLocale(equivalentTo: wanted)
        result.append("SpeechTranscriber：這支手機可用 \(mark(SpeechTranscriber.isAvailable))，對應 zh-TW 的是 \(describe(speech))")
        let speechAll = await SpeechTranscriber.supportedLocales
        result.append("SpeechTranscriber 支援的中文：\(chinese(speechAll))")
        let speechInstalled = await SpeechTranscriber.installedLocales
        result.append("SpeechTranscriber 已下載的中文：\(chinese(speechInstalled))")

        // DictationTranscriber 沒有 isAvailable，用支援的語言數代替。
        let dictation = await DictationTranscriber.supportedLocale(equivalentTo: wanted)
        let dictationAll = await DictationTranscriber.supportedLocales
        result.append("DictationTranscriber：支援 \(dictationAll.count) 種語言，對應 zh-TW 的是 \(describe(dictation))")
        result.append("DictationTranscriber 支援的中文：\(chinese(dictationAll))")
        let dictationInstalled = await DictationTranscriber.installedLocales
        result.append("DictationTranscriber 已下載的中文：\(chinese(dictationInstalled))")
        return result
    }
    #endif

    private static func mark(_ value: Bool) -> String { value ? "是" : "否" }

    private static func permission() -> String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return "已允許"
        case .denied: return "不允許"
        case .restricted: return "受限制"
        case .notDetermined: return "還沒問"
        @unknown default: return "未知"
        }
    }

    /// 系統會給「差不多的語言」，要看回來的是不是繁體台灣，免得拿到簡體。
    private static func describe(_ locale: Locale?) -> String {
        guard let locale else { return "沒有" }
        let full = locale.language.maximalIdentifier
        let isTaiwan = full.contains("Hant") && full.contains("TW")
        return "\(locale.identifier(.bcp47))（\(full)，\(isTaiwan ? "是繁體台灣" : "不是繁體台灣")）"
    }

    private static func chinese(_ locales: [Locale]) -> String {
        let names = locales.map { $0.identifier(.bcp47) }
            .filter { $0.hasPrefix("zh") || $0.hasPrefix("yue") }
            .sorted()
        return names.isEmpty ? "沒有" : names.joined(separator: "、")
    }
}
