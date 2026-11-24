import Foundation
import AVFoundation

enum SubtitleError: LocalizedError {
    case notAuthorized
    case unavailable
    case noAudio
    case nothingToWrite
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "沒有語音辨識的權限。請到「設定 → 花椰菜相機」打開「語音辨識」。"
        case .unavailable:
            return "這支手機目前不能辨識中文。請確認有連上網路，或到「設定 → 一般 → 鍵盤」打開「啟用聽寫」。"
        case .noAudio:
            return "這支影片沒有聲音，沒辦法對字幕。"
        case .nothingToWrite:
            return "沒有稿子，也沒有辨識到任何內容，產生不了字幕。"
        case .failed(let reason):
            return "字幕沒有做成功：\(reason)"
        }
    }
}

/// 用稿子幫影片做字幕檔（SRT）。怎麼對時、怎麼斷句都在 CaptionBuilder，這裡只負責寫成檔案。
enum SubtitleMaker {
    struct Result {
        let url: URL
        let cueCount: Int
        /// 稿子裡有多少比例的字，在聲音裡找到了對應的時間。
        let coverage: Double
        /// 這次有沒有真的做語音辨識。沒有的話，時間是照字數平均排的。
        let recognized: Bool
        /// 有沒有一段沒辨識到。那一段的句子時間是猜的。
        let hasFailures: Bool
    }

    static func make(videoURL: URL, script: String, maxChars: Int,
                     log: @escaping (String) -> Void) async throws -> Result {
        let duration = try await AVURLAsset(url: videoURL).load(.duration).seconds
        guard duration > 0 else { throw SubtitleError.noAudio }
        let clip = CaptionClip(file: videoURL.lastPathComponent, start: nil, end: nil, script: script)
        let built = try await CaptionBuilder.build(
            clips: [(url: videoURL, clip: clip, offset: 0, duration: duration)],
            maxChars: maxChars, log: log, progress: { _ in }
        )
        let lines = writable(built.lines, duration: duration)
        guard !lines.isEmpty else { throw SubtitleError.nothingToWrite }
        let hasFailures = !built.recognition.failedRanges.isEmpty
            || built.lines.contains { $0.status == .unrecognized }
        // 沒有稿子就沒有對不對得上的問題。
        let coverage = built.recognition.coverage ?? 1
        log(String(format: "字幕 %d 句，對上 %.0f%%", lines.count, coverage * 100))

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "花椰菜相機字幕-\(formatter.string(from: Date())).srt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try SubtitleLines.srt(lines).write(to: url, atomically: true, encoding: .utf8)
        return Result(url: url, cueCount: lines.count, coverage: coverage,
                      recognized: built.recognition.engine != CaptionBuilder.noEngine,
                      hasFailures: hasFailures)
    }

    /// 漏講的不進字幕檔；多講的、要確認的都進，剪輯時看得到。
    /// 沒辨識到又塞不下的句子在校對頁先藏著等人看，字幕檔沒有人會看過，漏掉不會有人發現，所以照進。
    private static func writable(_ lines: [CaptionLine], duration: Double) -> [CaptionLine] {
        var result = lines.filter { !($0.isHidden && $0.status == .missing) }
        if result.contains(where: { $0.isHidden }) {
            for index in result.indices { result[index].isHidden = false }
            // 藏著的可以和別句重疊，這裡要排開。最短停留放短，才不會把前後對好的句子推太遠。
            CaptionAligner.tidy(&result, duration: duration, least: CaptionEditing.shortest)
        }
        return result.filter(\.isBurnable)
    }
}
