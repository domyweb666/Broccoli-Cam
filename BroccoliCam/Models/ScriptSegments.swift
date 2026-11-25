import Foundation

/// 錄影的一段：畫面上看的字，和對字幕、檢查用的稿子。
struct ScriptPiece: Equatable {
    /// 畫面上顯示的字。
    let text: String
    /// 照著唸的稿子。重點是用自己的話講，沒有稿子可以比，一律是空字串。
    let captionScript: String
    /// 只是提醒要講什麼的重點。
    let isPoint: Bool

    static func spoken(_ text: String) -> ScriptPiece {
        ScriptPiece(text: text, captionScript: text, isPoint: false)
    }

    static func point(_ text: String) -> ScriptPiece {
        ScriptPiece(text: text, captionScript: "", isPoint: true)
    }
}

/// 稿件分段與時長估算。空行就是分段點；沒有空行就是一整段。
enum ScriptSegments {
    /// 照看多少字切出要錄的各段。選不看、或空稿，回傳空陣列。
    static func pieces(of script: String, amount: PromptAmount, segmented: Bool) -> [ScriptPiece] {
        switch amount {
        case .full:
            return segments(of: script, segmented: segmented).map { ScriptPiece.spoken($0) }
        case .outline:
            return outline(of: script, segmented: segmented)
        case .none:
            return []
        }
    }

    // MARK: - 提綱

    /// 提綱：有列點符號的行一點一段，其餘照念；整篇都沒有符號，就每段只留第一句。
    /// 一鏡到底時全部併成一張，不分照念和重點。
    static func outline(of script: String, segmented: Bool) -> [ScriptPiece] {
        let lines: [String] = script
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let marked: Bool = lines.contains { point(in: $0) != nil }
        let result: [ScriptPiece] = marked ? markedPieces(lines) : firstSentences(of: script)
        guard !segmented else { return result }
        let whole: String = result.map(\.text).joined(separator: "\n")
        return whole.isEmpty ? [] : [ScriptPiece.point(whole)]
    }

    private static func markedPieces(_ lines: [String]) -> [ScriptPiece] {
        var result: [ScriptPiece] = []
        var spoken: [String] = []
        func flush() {
            guard !spoken.isEmpty else { return }
            result.append(ScriptPiece.spoken(spoken.joined(separator: "\n")))
            spoken = []
        }
        for line in lines {
            if let text = point(in: line) {
                flush()
                // 只打了符號、還沒寫字的不算一段。
                if !text.isEmpty { result.append(ScriptPiece.point(text)) }
            } else if line.isEmpty {
                flush()
            } else {
                spoken.append(line)
            }
        }
        flush()
        return result
    }

    /// 第一段照念，開場才講得穩；其他段只留第一句當提醒。
    private static func firstSentences(of script: String) -> [ScriptPiece] {
        var result: [ScriptPiece] = []
        for paragraph in split(script) {
            let text: String = firstSentence(of: paragraph)
            guard !text.isEmpty else { continue }
            result.append(result.isEmpty ? ScriptPiece.spoken(text) : ScriptPiece.point(text))
        }
        return result
    }

    /// 到第一個句號、驚嘆號、問號（連同後面的引號）或換行為止。
    private static func firstSentence(of paragraph: String) -> String {
        let text: String = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        let enders: Set<Character> = ["。", "！", "？", "!", "?"]
        let closers: Set<Character> = ["」", "』", "”", "）", ")"]
        var result = ""
        var ended = false
        for character in text {
            if character.isNewline { break }
            if ended && !enders.contains(character) && !closers.contains(character) { break }
            result.append(character)
            if enders.contains(character) { ended = true }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// 這一行是重點的話，回傳去掉符號的字。傳進來的行頭尾已經沒有空白。
    private static func point(in line: String) -> String? {
        guard let first = line.first else { return nil }
        let dots: Set<Character> = ["・", "•", "·", "‧", "●"]
        // 減號和星號後面要有空白才算，「-5 度」這種不能當成列點。只有一個符號的行尾端空白已經被修掉了。
        let isDash: Bool = line.hasPrefix("- ") || line.hasPrefix("* ") || line == "-" || line == "*"
        guard dots.contains(first) || isDash else { return nil }
        return line.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 全稿

    /// 錄影要用的各段。segmented 關著就是一整段（保留空行），空稿回傳空陣列。
    static func segments(of script: String, segmented: Bool) -> [String] {
        if segmented { return split(script) }
        let whole = script
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return whole.isEmpty ? [] : [whole]
    }

    /// 用空行（可含空白字元）切段，去掉每段前後空白與空段。
    static func split(_ script: String) -> [String] {
        let normalized = script
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var segments: [String] = []
        var current: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    segments.append(current.joined(separator: "\n"))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            segments.append(current.joined(separator: "\n"))
        }
        return segments
    }

    /// 會唸出來的字數：只算文字與數字，不算空白和標點。
    static func spokenCount(_ text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            count += 1
        }
        return count
    }

    /// 依語速（字／分鐘）估算秒數。
    static func estimatedSeconds(_ text: String, charsPerMinute: Double) -> TimeInterval {
        guard charsPerMinute > 0 else { return 0 }
        return Double(spokenCount(text)) / charsPerMinute * 60
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
