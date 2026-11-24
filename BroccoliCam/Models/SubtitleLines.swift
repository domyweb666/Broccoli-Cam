import Foundation

/// 一句字幕：開始、結束（秒）與文字。
struct SubtitleCue {
    var start: Double
    var end: Double
    var text: String
}

/// 字幕的寬度，以及輸出 SRT。斷句在 CaptionBreaker。
enum SubtitleLines {
    /// 字幕的寬度：中文字算 1，英數算半個。
    static func width(of text: String) -> Double {
        var total = 0.0
        for character in text {
            total += character.isASCII ? 0.5 : 1
        }
        return total
    }

    // MARK: - SRT

    /// 會燒上去的句子照時間排；藏起來的、沒有字的不寫。
    static func srt(_ lines: [CaptionLine]) -> String {
        let cues = lines
            .filter { !$0.isHidden && !$0.text.isEmpty && $0.end > $0.start }
            .sorted { $0.start < $1.start }
            .map { SubtitleCue(start: $0.start, end: $0.end, text: $0.text) }
        return srt(cues)
    }

    static func srt(_ cues: [SubtitleCue]) -> String {
        var output = ""
        for (index, cue) in cues.enumerated() {
            output += "\(index + 1)\n"
            output += "\(timestamp(cue.start)) --> \(timestamp(cue.end))\n"
            output += cue.text + "\n\n"
        }
        return output
    }

    private static func timestamp(_ seconds: Double) -> String {
        let millis = Int((max(0, seconds) * 1000).rounded())
        let h = millis / 3_600_000
        let m = (millis / 60_000) % 60
        let s = (millis / 1000) % 60
        let ms = millis % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
