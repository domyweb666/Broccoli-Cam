import Foundation

/// 把文字轉成「比對用的音」序列：只留會唸出來的字，中文字轉成不帶聲調的拼音。
/// 語音辨識常把字認成同音字（的／得、在／再），用音比對才對得上稿子。
enum SpokenKeys {
    struct Key {
        /// 比對用的值：中文和數字是拼音，英文是小寫字母。
        let value: String
        /// 這個字在原文裡的位置（UTF-16）。
        let utf16Offset: Int
    }

    private static var cache: [Character: String] = [:]
    /// 稿子寫 3、聽到三（或反過來）是同一個音。
    private static let digits: [Character: String] = [
        "0": "ling", "1": "yi", "2": "er", "3": "san", "4": "si",
        "5": "wu", "6": "liu", "7": "qi", "8": "ba", "9": "jiu"
    ]
    private static let lock = NSLock()

    static func keys(of text: String) -> [Key] {
        var result: [Key] = []
        var offset = 0
        for character in text {
            if let value = key(for: character) {
                result.append(Key(value: value, utf16Offset: offset))
            }
            offset += character.utf16.count
        }
        return result
    }

    /// 標點和空白回傳 nil。
    static func key(for character: Character) -> String? {
        guard character.isLetter || character.isNumber else { return nil }
        if let digit = digits[character] { return digit }
        if character.isASCII {
            return String(character).lowercased()
        }
        lock.lock()
        let cached = cache[character]
        lock.unlock()
        if let cached { return cached }

        let source = String(character)
        let latin = source.applyingTransform(.mandarinToLatin, reverse: false) ?? source
        let plain = (latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        let value = plain.isEmpty ? source : plain

        lock.lock()
        cache[character] = value
        lock.unlock()
        return value
    }
}
