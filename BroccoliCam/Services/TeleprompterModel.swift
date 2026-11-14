import UIKit

/// 提詞捲動狀態。與錄影狀態互相獨立，可各自啟動／暫停。
final class TeleprompterModel: ObservableObject {
    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var isPlaying = false

    /// 捲動速度（pt／秒）
    var speed: CGFloat = 36
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    /// 捲到最後一行停在閱讀區上緣附近為止。
    private var maxOffset: CGFloat {
        max(0, contentHeight - viewportHeight * 0.35)
    }

    var isAtEnd: Bool {
        maxOffset > 0 && offset >= maxOffset
    }

    func play() {
        guard !isPlaying else { return }
        if isAtEnd { offset = 0 }
        isPlaying = true
        lastTimestamp = 0
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func pause() {
        displayLink?.invalidate()
        displayLink = nil
        if isPlaying { isPlaying = false }
    }

    func toggle() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func reset() {
        pause()
        offset = 0
    }

    /// 手動滑動時直接指定位置。
    func setOffset(_ value: CGFloat) {
        offset = min(maxOffset, max(0, value))
    }

    @objc private func step(_ link: CADisplayLink) {
        if lastTimestamp == 0 {
            lastTimestamp = link.timestamp
            return
        }
        let dt = link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        let next = offset + speed * CGFloat(dt)
        if next >= maxOffset {
            offset = maxOffset
            pause()
        } else {
            offset = next
        }
    }
}
