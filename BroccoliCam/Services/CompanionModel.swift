import Foundation
import Combine

/// 聆聽者：決定什麼時候做反應。
/// 只看音量，不理解內容、不評分、不出聲。
/// 「即時反應」開著時跟著停頓和音量走（ListenerReactor），關掉就是講話時隨機點頭。
/// 這裡只管時機；眨眼、呼吸已經在待機短片裡，播哪支片由 CompanionClipPlayer 決定。
/// 不做微笑：2026-11-23 多米試看後說微笑會干擾，聆聽者只要顯得專心。
final class CompanionModel: ObservableObject {
    /// 隨機點頭：每點一次頭就加一，播放器看到變化就切到點頭片段。
    @Published private(set) var nodCount = 0
    /// 即時反應交給播放器，它回答有沒有接下來要播。
    var onReaction: ((CompanionReaction) -> Bool)?
    /// 接下來最可能做的反應，播放器拿來預先載入。
    let expecting = CurrentValueSubject<[CompanionReaction], Never>([.nod])
    /// 反應片播放中，由播放器寫。
    var isReacting = false

    private var timer: Timer?
    private var cancellable: AnyCancellable?
    private var levelCancellable: AnyCancellable?
    private var instantCancellable: AnyCancellable?
    private var speaking = false
    private var nextNod: Date?
    private var instant = false
    private var reactor = ListenerReactor()
    /// 換預載的反應片要等這麼久都沒再變才換。講話停一下下又開口，不用把兩台預載的片整批換掉又換回來。
    private let expectingDelay: TimeInterval = 0.5
    /// 等著換成的那一組，和它的計時。
    private var expectingWork: DispatchWorkItem?
    private var expectingTarget: [CompanionReaction]?

    func start(meter: SpeechActivityMonitor) {
        guard timer == nil else { return }
        instantCancellable = UserDefaults.standard.publisher(for: \.instantReaction)
            .removeDuplicates()
            .sink { [weak self] value in
                self?.setInstant(value)
            }
        cancellable = meter.$isSpeaking
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.speakingChanged(value)
            }
        // 直接跟著收音每 0.1 秒的更新走，不等自己的計時器，反應才不會再慢一拍。
        // 每一次量到的音量都會送來（畫面上的音量條則是變夠多才重畫）。
        levelCancellable = meter.levelSamples
            .sink { [weak self] value in
                self?.heard(value)
            }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancellable = nil
        levelCancellable = nil
        instantCancellable = nil
        speaking = false
        nextNod = nil
        isReacting = false
        reactor.reset()
        cancelPendingExpecting()
    }

    private func setInstant(_ value: Bool) {
        instant = value
        reactor.reset()
        // 講到一半才關掉即時反應，不要馬上點頭。
        if !value && speaking {
            nextNod = Date().addingTimeInterval(Double.random(in: 2.5...4.5))
        }
        // 使用者自己切的，馬上換。
        updateExpecting(immediately: true)
    }

    private func heard(_ level: Float) {
        guard instant else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let reaction = reactor.feed(time: now, level: Double(level), busy: isReacting) {
            // 播放器沒接（還在換人、沒有這種片），就當沒做過，不扣間隔。
            let accepted = onReaction?(reaction) == true
            if !accepted { reactor.declined() }
            #if targetEnvironment(simulator)
            NSLog("[companion] %.2f %@ %@", now, "\(reaction)", accepted ? "播" : "沒接")
            #endif
        }
        updateExpecting()
    }

    /// 接了但來不及播。
    func reactionDropped() {
        reactor.declined()
    }

    /// 接下來最可能的反應變了，告訴播放器換預載的片。講話中途的變化要穩定 expectingDelay 秒才換。
    private func updateExpecting(immediately: Bool = false) {
        let next: [CompanionReaction] = instant ? reactor.expecting : [.nod]
        guard next != expecting.value else {
            // 又變回現在載著的那組，等著的就不用換了。
            cancelPendingExpecting()
            return
        }
        if immediately {
            cancelPendingExpecting()
            expecting.send(next)
            return
        }
        // 已經在等換成同一組，照原本的時間。
        guard expectingTarget != next else { return }
        cancelPendingExpecting()
        expectingTarget = next
        let work = DispatchWorkItem { [weak self] in
            guard let self, let target = self.expectingTarget else { return }
            self.expectingTarget = nil
            self.expectingWork = nil
            if target != self.expecting.value { self.expecting.send(target) }
        }
        expectingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + expectingDelay, execute: work)
    }

    private func cancelPendingExpecting() {
        expectingWork?.cancel()
        expectingWork = nil
        expectingTarget = nil
    }

    private func speakingChanged(_ value: Bool) {
        if value {
            speaking = true
            // 開口後過一會兒才第一次點頭，不要一講話就點。
            nextNod = Date().addingTimeInterval(Double.random(in: 2.5...4.5))
        } else {
            speaking = false
            nextNod = nil
        }
    }

    private func tick() {
        guard !instant else { return }
        // 點頭：只在對方持續講話時，偶爾一次，間隔不固定。
        if speaking, let due = nextNod, Date() >= due {
            nodCount += 1
            #if targetEnvironment(simulator)
            NSLog("[companion] %.2f 隨機點頭", ProcessInfo.processInfo.systemUptime)
            #endif
            nextNod = Date().addingTimeInterval(Double.random(in: 4...8))
        }
    }
}
