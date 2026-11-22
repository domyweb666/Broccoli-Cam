import Foundation
import Combine

/// 陪伴模式的聆聽者：依「有沒有在講話」決定什麼時候點頭。
/// 只看音量判斷出來的說話／停頓，不理解內容、不評分、不出聲。
/// 這裡只管時機；眨眼、呼吸已經在待機短片裡，播哪支片由 CompanionClipPlayer 決定。
/// 不做微笑：2026-11-23 多米試看後說微笑會干擾，聆聽者只要顯得專心。
final class CompanionModel: ObservableObject {
    /// 每點一次頭就加一，播放器看到變化就切到點頭片段。
    @Published private(set) var nodCount = 0

    private var timer: Timer?
    private var cancellable: AnyCancellable?
    private var speaking = false
    private var nextNod: Date?

    func start(meter: SpeechActivityMonitor) {
        guard timer == nil else { return }
        cancellable = meter.$isSpeaking
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.speakingChanged(value)
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
        speaking = false
        nextNod = nil
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
        // 點頭：只在對方持續講話時，偶爾一次，間隔不固定。
        if speaking, let due = nextNod, Date() >= due {
            nodCount += 1
            nextNod = Date().addingTimeInterval(Double.random(in: 4...8))
        }
    }
}
