import Foundation

/// 語音跟隨的「先走一步」：辨識結果平常晚 0.5–1 秒才到，講話中先照語速把唸過的位置往前推，結果到了再校正。
/// 只管畫面顯示到哪，不碰對位（SpeechAligner 的 position），也不算進「對上幾次」。
/// 位置都是第幾個音（SpokenKeys 的 index），指的是下一個要唸的那個。
struct SpeechLead {
    /// 句子邊界。先走不能越過去：句尾常停頓，走過頭會穿幫。
    struct Stop {
        /// 從這個音開始的話，先走最多走到第幾個音（邊界後的第一個音）。
        let limit: Int
        /// 邊界在原文的位置（UTF-16）。畫面最多變色到這裡，不會把下一句的開頭也算進去。
        let utf16Offset: Int
    }

    /// 最多比辨識確認的位置多走幾個音，大約一秒的量。
    static let maxLead = 4
    /// 辨識結果大約晚到這麼久（秒）。結果到的時候人還在講，其實已經唸到更後面。
    static let latency: Double = 0.6
    /// 說話偵測說停了這麼久（秒），還沒被確認的部分就收回來。
    static let quietPullback: Double = 0.8
    /// 一直在講，卻這麼久（秒）都沒對上，多半是講稿子以外的話，收回來等辨識。
    static let staleSeconds: Double = 2
    /// 語速（音／秒）的上下限。
    static let slowest: Double = 2
    static let fastest: Double = 7
    /// 新量到的語速佔幾成。
    static let smoothing: Double = 0.3
    /// 累積講了這麼多秒才量一次語速，太短的不準。
    static let sampleSeconds: Double = 1
    /// 講了這麼久還沒對上就不量了，重新累積。
    static let sampleLimit: Double = 3
    /// 一次往前跳超過這麼多個音，多半是辨識一口氣追上或跳了一段，不拿來量語速。
    static let sampleJump = 12
    /// 兩次更新隔太久（計時器卡住）只算這麼多秒。
    static let maxStep: Double = 0.3

    /// 句號、問號、驚嘆號、分號、刪節號；換行另外算。逗號不算，可以走過去。
    private static let enders: Set<Character> = ["。", "．", ".", "？", "?", "！", "!", "；", ";", "…"]

    private let stops: [Stop]
    /// 辨識確認的位置。
    private(set) var confirmed: Int
    /// 畫面顯示的位置，至少和 confirmed 一樣。
    private(set) var shown: Int
    /// 量到的語速，還沒量到是 nil。
    private(set) var measuredRate: Double?
    private let fallbackRate: Double
    /// 對上過才先走。剛開始、剛跳轉、先走的被收回之後，都要等辨識先對上一次。
    private var armed = false
    /// 上次確認之後，真的有出聲的秒數。
    private var voicedSinceConfirm: Double = 0
    /// 還能多算的延遲（秒）：確認的那一刻人還在講才有，沒出聲的時候慢慢用掉。
    private var credit: Double = 0
    private var quietSince: Double?
    private var lastTick: Double?
    private var lastVoiced = false
    /// 量語速用：累積往前對上了幾個音、這段時間出聲了幾秒。
    private var sampleKeys = 0
    private var sampleVoiced: Double = 0

    /// rate 是還沒量到語速時先用的（音／秒）。
    init(stops: [Stop], position: Int, rate: Double) {
        self.stops = stops
        let clamped = min(max(0, position), stops.count)
        confirmed = clamped
        shown = clamped
        fallbackRate = SpeechLead.clampRate(rate)
    }

    /// 目前用的語速（音／秒）。
    var rate: Double {
        measuredRate ?? fallbackRate
    }

    /// 畫面比確認的位置多走的時候，最多變色到原文的哪裡（UTF-16）；沒有多走是 nil。
    var stopOffset: Int? {
        guard shown > confirmed, confirmed < stops.count else { return nil }
        return stops[confirmed].utf16Offset
    }

    /// 跳轉、回開頭、暫停、繼續：位置重來，量到的語速留著。
    mutating func reset(to position: Int) {
        confirmed = min(max(0, position), stops.count)
        shown = confirmed
        armed = false
        voicedSinceConfirm = 0
        credit = 0
        quietSince = nil
        lastTick = nil
        lastVoiced = false
        sampleKeys = 0
        sampleVoiced = 0
    }

    /// 辨識往前對上了。真的位置追上或超過畫面就用真的；還落後一點點就先不退，等它追上來。
    mutating func confirmForward(to position: Int) {
        let target = min(max(0, position), stops.count)
        let advance = target - confirmed
        if advance > Self.sampleJump {
            sampleKeys = 0
            sampleVoiced = 0
        } else if advance > 0 {
            sampleKeys += advance
            if sampleVoiced >= Self.sampleSeconds {
                let sample = Self.clampRate(Double(sampleKeys) / sampleVoiced)
                measuredRate = rate + Self.smoothing * (sample - rate)
                sampleKeys = 0
                sampleVoiced = 0
            }
        }
        confirmed = target
        if shown < target || shown - target > Self.maxLead {
            shown = target
        }
        armed = true
        voicedSinceConfirm = 0
        credit = lastVoiced ? Self.latency : 0
    }

    /// 退回去重唸：照真的退，不等。
    mutating func confirmBackward(to position: Int) {
        confirmed = min(max(0, position), stops.count)
        shown = confirmed
        armed = true
        voicedSinceConfirm = 0
        credit = 0
        sampleKeys = 0
        sampleVoiced = 0
    }

    /// 每 0.1 秒左右呼叫一次。speaking 是說話偵測（停一下下還算在講），voiced 是這一下真的有出聲。
    mutating func tick(now: Double, speaking: Bool, voiced: Bool) {
        let step = lastTick.map { min(max(0, now - $0), Self.maxStep) } ?? 0
        lastTick = now
        lastVoiced = voiced
        if speaking {
            quietSince = nil
        } else if quietSince == nil {
            quietSince = now
        }
        if voiced {
            voicedSinceConfirm += step
            if armed {
                sampleVoiced += step
                if sampleVoiced > Self.sampleLimit {
                    sampleKeys = 0
                    sampleVoiced = 0
                }
            }
        } else {
            credit = max(0, credit - step)
        }

        // 停下來一陣子了，或講了很久都對不上：先走的收回來，等辨識。
        let quietLong = quietSince.map { now - $0 >= Self.quietPullback } ?? false
        if quietLong || voicedSinceConfirm >= Self.staleSeconds {
            if shown > confirmed {
                shown = confirmed
                armed = false
            }
            return
        }
        guard armed, voiced else { return }
        let lead = min(Double(Self.maxLead), rate * (voicedSinceConfirm + credit))
        let limit = confirmed < stops.count ? stops[confirmed].limit : stops.count
        let target = min(confirmed + Int(lead), limit)
        // 只往前，不會因為預測往回。
        if target > shown {
            shown = target
        }
    }

    /// 每個音之後的第一個句子邊界。
    static func sentenceStops(in text: String, keys: [SpokenKeys.Key]) -> [Stop] {
        var ends: [Int] = []
        var offset = 0
        for character in text {
            if character.isNewline || enders.contains(character) {
                ends.append(offset)
            }
            offset += character.utf16.count
        }
        var stops: [Stop] = []
        stops.reserveCapacity(keys.count)
        var end = 0
        var next = 0
        for key in keys {
            while end < ends.count && ends[end] < key.utf16Offset { end += 1 }
            // 後面沒有邊界了，整篇的結尾就是邊界。
            let edge = end < ends.count ? ends[end] : offset
            while next < keys.count && keys[next].utf16Offset <= edge { next += 1 }
            stops.append(Stop(limit: next, utf16Offset: edge))
        }
        return stops
    }

    private static func clampRate(_ value: Double) -> Double {
        min(fastest, max(slowest, value))
    }
}
