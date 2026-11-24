import Foundation

/// 稿件分段與時長估算。空行就是分段點；沒有空行就是一整段。
enum ScriptSegments {
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
