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

/// 整篇稿子比對用的音和句子邊界。
/// 長稿第一次轉拼音、找句尾要一點時間，以前在開始跟讀那一刻（主執行緒）才算，按下錄影會頓一下。
/// 換稿時先在背景算好放這裡，開始跟讀時直接拿；還沒算好就當下算，結果和以前一模一樣。
/// 可以在任何執行緒呼叫。
final class SpokenScriptCache {
    static let shared = SpokenScriptCache()

    struct Entry {
        let keys: [SpokenKeys.Key]
        let stops: [SpeechLead.Stop]
    }

    private let lock = NSLock()
    /// 以稿子全文當 key。
    private var entries: [String: Entry] = [:]
    /// 最近一次換稿要的那幾段。背景算好時已經換掉的就不留。
    private var wanted: Set<String> = []
    private let queue = DispatchQueue(label: "org.domyweb.broccolicam.spoken-keys", qos: .utility)
    /// 當下算的也會留著，太多就只留最近一次換稿要的。
    private static let limit = 24

    private init() {}

    /// 換稿了：這幾段先在背景算好。不在這批裡的舊結果丟掉。
    func prepare(_ texts: [String]) {
        let next = Set(texts.filter { !$0.isEmpty })
        lock.lock()
        wanted = next
        entries = entries.filter { next.contains($0.key) }
        let missing = next.filter { entries[$0] == nil }
        lock.unlock()
        guard !missing.isEmpty else { return }
        queue.async {
            for text in missing {
                self.lock.lock()
                let needed = self.wanted.contains(text) && self.entries[text] == nil
                self.lock.unlock()
                guard needed else { continue }
                let entry = Self.compute(text)
                self.lock.lock()
                if self.wanted.contains(text) { self.entries[text] = entry }
                self.lock.unlock()
            }
        }
    }

    /// 這篇稿子的音和句子邊界。背景還沒算好就當下算。
    func entry(for text: String) -> Entry {
        lock.lock()
        let known = entries[text]
        lock.unlock()
        if let known { return known }
        let entry = Self.compute(text)
        lock.lock()
        if entries.count >= Self.limit {
            let keep = wanted
            entries = entries.filter { keep.contains($0.key) }
        }
        entries[text] = entry
        lock.unlock()
        return entry
    }

    func keys(for text: String) -> [SpokenKeys.Key] {
        entry(for: text).keys
    }

    private static func compute(_ text: String) -> Entry {
        let keys = SpokenKeys.keys(of: text)
        return Entry(keys: keys, stops: SpeechLead.sentenceStops(in: text, keys: keys))
    }
}
