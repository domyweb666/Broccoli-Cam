import Foundation
import Combine

/// 陪伴模式的聆聽者：依「有沒有在講話」決定眨眼、點頭、微笑的時機。
/// 只看音量判斷出來的說話／停頓，不理解內容、不評分、不出聲。
/// 這裡只管時機，長相由 CompanionView 決定；之後換成預錄短片也沿用這套時機。
final class CompanionModel: ObservableObject {
    /// 眼睛是不是閉著（眨眼的那一瞬間）。
    @Published private(set) var eyesClosed = false
    /// 每點一次頭就加一，畫面用它觸發動畫。
    @Published private(set) var nodCount = 0
    /// 現在是不是在微笑。
    @Published private(set) var smiling = false

    private var timer: Timer?
    private var cancellable: AnyCancellable?
    private var speaking = false
    private var speakingSince: Date?
    private var nextBlink = Date()
    private var blinkEnds: Date?
    private var nextNod: Date?
    private var smileEnds: Date?
    private var lastSmile = Date.distantPast

    func start(meter: SpeechActivityMonitor) {
        guard timer == nil else { return }
        nextBlink = Date().addingTimeInterval(Double.random(in: 2...4))
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
        speakingSince = nil
        nextNod = nil
        eyesClosed = false
        smiling = false
    }

    private func speakingChanged(_ value: Bool) {
        let now = Date()
        if value {
            speaking = true
            speakingSince = now
            // 開口後過一會兒才第一次點頭，不要一講話就點。
            nextNod = now.addingTimeInterval(Double.random(in: 2.5...4.5))
        } else {
            // 講完一段話（至少講了兩秒）停下來，有時候微笑一下；不是每次，免得像機器。
            if speaking, let since = speakingSince, now.timeIntervalSince(since) > 2,
               now.timeIntervalSince(lastSmile) > 8, Bool.random() {
                smiling = true
                smileEnds = now.addingTimeInterval(1.8)
                lastSmile = now
            }
            speaking = false
            speakingSince = nil
            nextNod = nil
        }
    }

    private func tick() {
        let now = Date()

        // 眨眼：間隔不固定。
        if let ends = blinkEnds {
            if now >= ends {
                blinkEnds = nil
                eyesClosed = false
                nextBlink = now.addingTimeInterval(Double.random(in: 2.5...6))
            }
        } else if now >= nextBlink {
            eyesClosed = true
            blinkEnds = now.addingTimeInterval(0.13)
        }

        // 點頭：只在對方持續講話時，偶爾一次，間隔不固定。
        if speaking, let due = nextNod, now >= due {
            nodCount += 1
            nextNod = now.addingTimeInterval(Double.random(in: 4...8))
        }

        if let ends = smileEnds, now >= ends {
            smileEnds = nil
            smiling = false
        }
    }
}
