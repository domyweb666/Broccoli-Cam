import Foundation

/// 一句字幕：開始、結束（秒）與文字。
struct SubtitleCue {
    var start: Double
    var end: Double
    var text: String
}

/// 把稿子切成一行一行的字幕，以及輸出 SRT。
enum SubtitleLines {
    private static let strongBreaks: Set<Character> = ["。", "！", "？", "；", "!", "?", ";", "…", "\n"]
    private static let weakBreaks: Set<Character> = ["，", "、", "：", ",", ":"]

    /// 字幕的寬度：中文字算 1，英數算半個。
    static func width(of text: String) -> Double {
        var total = 0.0
        for character in text {
            if character == " " {
                total += 0.5
            } else if character.isASCII {
                total += 0.5
            } else {
                total += 1
            }
        }
        return total
    }

    /// 依標點切句；短句在同一行用空白接起來，太長的句子平均拆開。行尾不留標點。
    static func split(_ script: String, maxChars: Int) -> [String] {
        let limit = Double(max(4, maxChars))
        let normalized = script
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // 先切成子句，記下每個子句後面是不是「強」斷點。
        var clauses: [(text: String, strong: Bool)] = []
        var current = ""
        func flush(strong: Bool) {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                clauses.append((trimmed, strong))
            } else if strong, !clauses.isEmpty {
                clauses[clauses.count - 1].strong = true
            }
            current = ""
        }
        let characters = Array(normalized)
        for (index, character) in characters.enumerated() {
            if strongBreaks.contains(character) {
                flush(strong: true)
            } else if weakBreaks.contains(character) {
                // 數字裡的逗號和小數點前後不切（1,000）。
                let previous = index > 0 ? characters[index - 1] : " "
                let next = index + 1 < characters.count ? characters[index + 1] : " "
                if character.isASCII && previous.isNumber && next.isNumber {
                    current.append(character)
                } else {
                    flush(strong: false)
                }
            } else {
                current.append(character)
            }
        }
        flush(strong: true)

        // 短的子句併成一行，遇到強斷點就換行。
        var lines: [String] = []
        var line = ""
        for clause in clauses {
            let pieces = width(of: clause.text) > limit ? breakLong(clause.text, limit: limit) : [clause.text]
            for (index, piece) in pieces.enumerated() {
                let isLastPiece = index == pieces.count - 1
                if line.isEmpty {
                    line = piece
                } else if pieces.count == 1 && width(of: line) + 0.5 + width(of: piece) <= limit {
                    line += " " + piece
                } else {
                    lines.append(line)
                    line = piece
                }
                if !isLastPiece || (isLastPiece && clause.strong) {
                    lines.append(line)
                    line = ""
                }
            }
        }
        if !line.isEmpty {
            lines.append(line)
        }
        return lines
    }

    /// 太長的句子平均拆成幾行，不從英文單字或數字中間切。
    private static func breakLong(_ text: String, limit: Double) -> [String] {
        let characters = Array(text)
        let total = width(of: text)
        let count = Int((total / limit).rounded(.up))
        guard count > 1 else { return [text] }
        let target = total / Double(count)

        var pieces: [String] = []
        var current = ""
        var currentWidth = 0.0
        for (index, character) in characters.enumerated() {
            current.append(character)
            currentWidth += width(of: String(character))
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            guard let next, pieces.count < count - 1, currentWidth >= target else { continue }
            let insideWord = character.isASCII && next.isASCII
                && (character.isLetter || character.isNumber)
                && (next.isLetter || next.isNumber)
            if insideWord { continue }
            pieces.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
            currentWidth = 0
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty {
            pieces.append(rest)
        }
        return pieces.filter { !$0.isEmpty }
    }

    // MARK: - SRT

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
