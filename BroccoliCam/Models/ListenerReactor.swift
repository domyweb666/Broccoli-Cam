import Foundation

/// 聆聽者的一個反應。
enum CompanionReaction: Hashable {
    /// 點頭
    case nod
    /// 眉毛抬一下
    case brow
    /// 歪頭等你
    case tilt
    /// 往前靠一點
    case lean
}

/// 「即時反應」的狀態機：一直餵它時間和音量（dBFS），它回答現在要不要做一個反應。
/// 只看音量，不辨識內容。純邏輯，不碰時鐘、畫面和麥克風，所以可以拿錄好的音量序列重跑。
struct ListenerReactor {
    /// 所有可以調的數字。
    private enum Tuning {
        // 音量門檻：跟著環境的底噪和這個人的音量走。
        /// 完全沒有訊號時的音量會掉到 -160，太低會把底噪拉壞，先夾住。
        static let minLevel: Double = -90
        /// 用最近幾秒估底噪和音量。
        static let historySeconds: Double = 8
        static let floorPercentile: Double = 0.10
        static let peakPercentile: Double = 0.90
        /// 底噪一秒最多往上調多少。一直講話時，低點也會變高，不能跟太快。
        static let floorRisePerSecond: Double = 1.5
        /// 這麼久音量都這麼平就是環境音（冷氣剛打開），底噪直接跟上去。講話不會這麼平。
        static let steadySeconds: Double = 2
        static let steadyRange: Double = 6
        /// 剛開始先聽一下環境。
        static let warmUpSeconds: Double = 0.5
        /// 高出底噪多少算講話：取「底噪到高點」的四成，夾在上下限之間。
        static let loudRatio: Double = 0.40
        static let loudMarginMin: Double = 8
        static let loudMarginMax: Double = 20
        /// 講話中要掉得比門檻低這麼多才算停。
        static let loudHysteresis: Double = 3
        static let loudAbsoluteMin: Double = -60

        // 開口：這段時間裡要有幾次有聲音。敲桌、碰撞只有一兩次，不算。
        static let onsetWindow: Double = 0.45
        static let onsetSamples = 3
        /// 安靜這麼久算停頓。
        static let quietAfter: Double = 0.35
        /// 停頓這麼久，前面講的就算告一段落。
        static let turnBreak: Double = 1.0

        // 點頭
        static let nodTalk: Double = 1.5
        static let nodChance: Double = 0.7
        /// 一直講沒停，隔這麼久也點一次。
        static let longTalk: ClosedRange<Double> = 8...12

        // 抬眉：最近 0.3 秒比平常大聲這麼多。
        static let browRise: Double = 7
        static let browWindow: Double = 0.45
        static let browSamples = 4
        /// 這幾次裡至少要有幾次明顯比平常大聲，單獨一聲爆音不算。
        static let browSampleRise: Double = 3
        static let browLoudNeeded = 3
        /// 「平常」是最近這麼多次有聲音的平均（一次 0.1 秒），太少就先不比。
        static let browBaseSamples = 60
        static let browBaseNeeded = 15
        static let browChance: Double = 0.9

        // 歪頭：停很久，而且前面真的有講話。
        static let tiltPause: Double = 3
        static let tiltTalk: Double = 1
        static let tiltChance: Double = 0.9

        // 往前靠：停很久之後重新開口。
        static let leanPause: Double = 2
        static let leanChance: Double = 0.9

        /// 兩次反應之間至少隔多久，每次隨機。
        static let gap: ClosedRange<Double> = 3...5
        /// 這麼久沒收到音量（切到背景、相機停掉），前面的就不算數。
        static let resetGap: Double = 1
        /// 0.1 秒一次的時間加起來會差一點點，比較時讓一下。
        static let epsilon: Double = 0.001
    }

    private struct Sample {
        let time: Double
        let level: Double
    }

    private let random: (ClosedRange<Double>) -> Double

    private var lastTime: Double?
    private var startTime: Double = 0
    private var history: [Sample] = []
    private var noiseFloor: Double?
    private var threshold: Double = Tuning.loudAbsoluteMin

    private var talking = false
    private var hasTalked = false
    /// 最近有聲音的時間點，用來判斷開口。
    private var loudTimes: [Double] = []
    private var lastLoud: Double?
    /// 這一口氣從什麼時候開始。
    private var burstStart: Double = 0
    /// 上次點頭之後講了多久（不含停頓）。
    private var talked: Double = 0
    /// 這一輪（中間沒停超過 turnBreak）講了多久。
    private var turnTalk: Double = 0
    private var longDue: Double = 0

    /// 最近有聲音時的音量，代表這個人平常多大聲。
    private var voiced: [Double] = []
    private var wasRaised = false
    /// 這一次停頓已經歪過頭了。
    private var tiltDone = false
    private var nextAllowed: Double = 0

    /// `random` 回傳範圍內的亂數，測試時可以換成固定的。
    init(random: @escaping (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) {
        self.random = random
        longDue = random(Tuning.longTalk)
    }

    /// 接下來最可能做的反應，播放器拿來預先載入。
    var expecting: [CompanionReaction] {
        if !talking, hasTalked, let lastTime, let lastLoud, lastTime - lastLoud >= Tuning.turnBreak {
            return [.tilt, .lean]
        }
        return [.nod, .brow]
    }

    /// 忘掉聽過的一切。
    mutating func reset() {
        self = ListenerReactor(random: random)
    }

    /// 餵一次音量。`time` 是一直往前走的秒數，`busy` 是反應片還在播。
    /// 回傳現在要做的反應；播放中或太密集時，發生的事直接丟掉。
    mutating func feed(time: Double, level rawLevel: Double, busy: Bool) -> CompanionReaction? {
        let level = max(Tuning.minLevel, rawLevel)
        if let last = lastTime, time - last > Tuning.resetGap || time < last {
            let allowed = nextAllowed
            reset()
            nextAllowed = allowed
        }
        if lastTime == nil { startTime = time }
        let step = lastTime.map { time - $0 } ?? 0
        lastTime = time

        updateThreshold(time: time, level: level, step: step)
        guard time - startTime >= Tuning.warmUpSeconds else { return nil }

        let limit = talking ? threshold - Tuning.loudHysteresis : threshold
        let loud = level > limit
        let changed = updateTalking(time: time, loud: loud)
        let raised = updateRaised(time: time, level: level, loud: loud)
        let open = !busy && time >= nextAllowed

        let reaction: CompanionReaction
        let chance: Double
        if let changed {
            reaction = changed
            chance = changed == .lean ? Tuning.leanChance : Tuning.nodChance
        } else if raised {
            reaction = .brow
            chance = Tuning.browChance
        } else if talking, loud, open, time >= longDue {
            reaction = .nod
            chance = 1
        } else if open, waitedLong(time: time) {
            tiltDone = true
            reaction = .tilt
            chance = Tuning.tiltChance
        } else {
            return nil
        }

        guard open, random(0...1) <= chance else { return nil }
        if reaction == .nod {
            talked = 0
            if talking {
                turnTalk += max(0, time - burstStart)
                burstStart = time
            }
        }
        longDue = time + random(Tuning.longTalk)
        nextAllowed = time + random(Tuning.gap)
        return reaction
    }

    // MARK: - 門檻

    private mutating func updateThreshold(time: Double, level: Double, step: Double) {
        history.append(Sample(time: time, level: level))
        while let first = history.first, time - first.time > Tuning.historySeconds {
            history.removeFirst()
        }
        let sorted = history.map { $0.level }.sorted()
        let last = Double(sorted.count - 1)
        let low = sorted[Int(last * Tuning.floorPercentile)]
        let peak = sorted[Int(last * Tuning.peakPercentile)]

        // 往下馬上跟，往上慢慢跟。
        var value = noiseFloor ?? low
        value = low < value ? low : min(low, value + Tuning.floorRisePerSecond * step)

        if let first = history.first, time - first.time >= Tuning.steadySeconds {
            let recent = history.filter { time - $0.time <= Tuning.steadySeconds }.map { $0.level }
            let lowest = recent.min() ?? level
            let highest = recent.max() ?? level
            if highest - lowest < Tuning.steadyRange {
                value = max(value, recent.reduce(0, +) / Double(recent.count))
                // 音量這麼平的不是講話，前面誤認成講話的不算，也不要因為它「停了」就點頭。
                if talking {
                    talking = false
                    talked = 0
                    turnTalk = 0
                    loudTimes = []
                }
            }
        }

        noiseFloor = value
        let margin = min(Tuning.loudMarginMax, max(Tuning.loudMarginMin, Tuning.loudRatio * (peak - value)))
        threshold = max(Tuning.loudAbsoluteMin, value + margin)
    }

    // MARK: - 開口和停頓

    /// 更新講話／停頓。剛停下來回傳點頭，停很久之後重新開口回傳往前靠。
    private mutating func updateTalking(time: Double, loud: Bool) -> CompanionReaction? {
        if loud { loudTimes.append(time) }
        while let first = loudTimes.first, time - first > Tuning.onsetWindow {
            loudTimes.removeFirst()
        }

        if talking {
            if loud {
                lastLoud = time
                return nil
            }
            let last = lastLoud ?? time
            guard time - last + Tuning.epsilon >= Tuning.quietAfter else { return nil }
            talking = false
            loudTimes = []
            let burst = max(0, last - burstStart)
            talked += burst
            turnTalk += burst
            return talked >= Tuning.nodTalk ? .nod : nil
        }

        guard loud, loudTimes.count >= Tuning.onsetSamples, let started = loudTimes.first else { return nil }
        let pause = lastLoud.map { started - $0 }
        let again = hasTalked
        talking = true
        hasTalked = true
        tiltDone = false
        burstStart = started
        lastLoud = time
        if pause == nil || (pause ?? 0) >= Tuning.turnBreak {
            talked = 0
            turnTalk = 0
            longDue = started + random(Tuning.longTalk)
        }
        if again, let pause, pause >= Tuning.leanPause { return .lean }
        return nil
    }

    /// 停頓夠久、前面有講話、這次停頓還沒歪過頭。
    private func waitedLong(time: Double) -> Bool {
        guard !talking, !tiltDone, turnTalk >= Tuning.tiltTalk, let lastLoud else { return false }
        return time - lastLoud + Tuning.epsilon >= Tuning.tiltPause
    }

    // MARK: - 突然大聲

    /// 音量剛剛明顯拉高（只有變高的那一下是 true）。
    private mutating func updateRaised(time: Double, level: Double, loud: Bool) -> Bool {
        let base = voiced.count >= Tuning.browBaseNeeded ? Self.averagePower(voiced) : nil
        if talking && loud {
            voiced.append(level)
            if voiced.count > Tuning.browBaseSamples { voiced.removeFirst() }
        }

        var raised = false
        if talking, let base {
            let recent = history.filter { time - $0.time <= Tuning.browWindow }
                .suffix(Tuning.browSamples)
                .map { $0.level }
            if recent.count >= Tuning.browSamples {
                let loudCount = recent.filter { $0 >= base + Tuning.browSampleRise }.count
                raised = loudCount >= Tuning.browLoudNeeded
                    && Self.averagePower(recent) >= base + Tuning.browRise
            }
        }
        let was = wasRaised
        wasRaised = raised
        return raised && !was
    }

    /// 用能量平均（再換回 dB），字和字中間的短空隙才不會把平均拉低。
    private static func averagePower(_ levels: [Double]) -> Double {
        let sum = levels.reduce(0.0) { $0 + pow(10, $1 / 10) }
        return 10 * log10(sum / Double(levels.count))
    }
}
