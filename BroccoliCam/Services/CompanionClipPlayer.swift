import AVFoundation
import Combine
import UIKit

/// 播放聆聽者的預錄短片：待機片隨機輪播，點頭時淡入點頭片，播完淡回待機。
/// 每支片的第一格和最後一格都是同一張定格圖，待機時動作又很小，所以任何時候切換都看不出接縫，
/// 不用等待機播完才點頭。
/// 片子沒有音軌，播放器也靜音，不會碰到錄音用的 AVAudioSession。
final class CompanionClipPlayer: ObservableObject {
    enum Kind { case idle, nod }

    /// 交叉淡化的秒數。
    static let fade: TimeInterval = 0.25

    /// 兩台播放器輪流用：一台在前面播，另一台載入下一支，切換時交叉淡化。
    let players: [AVPlayer] = [AVPlayer(), AVPlayer()]
    /// 現在在前面的是哪一台。畫面看到變化就做淡化。
    @Published private(set) var front = 0
    /// 定格圖。播放器還沒出畫面的那一瞬間墊在底下，和片子第一格一樣。
    let still: UIImage?

    private let idleClips: [URL]
    private let nodClips: [URL]
    private var current: Kind = .idle
    private var lastIdle: URL?
    private var lastNod: URL?
    private var endObserver: NSObjectProtocol?
    private var nodCancellable: AnyCancellable?
    private var running = false

    /// 待機片有放進 App 才算可用。
    var isAvailable: Bool { !idleClips.isEmpty }

    init(bundle: Bundle = .main) {
        func urls(_ names: [String]) -> [URL] {
            names.compactMap { bundle.url(forResource: $0, withExtension: "mp4") }
        }
        idleClips = urls(["companion_idle_1", "companion_idle_2", "companion_idle_3"])
        nodClips = urls(["companion_nod_1", "companion_nod_2"])
        still = bundle.url(forResource: "companion_still", withExtension: "jpg")
            .flatMap { UIImage(contentsOfFile: $0.path) }
        for player in players {
            player.isMuted = true
            player.allowsExternalPlayback = false
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.automaticallyWaitsToMinimizeStalling = false
            player.actionAtItemEnd = .pause
        }
    }

    func start(model: CompanionModel) {
        guard isAvailable else { return }
        if nodCancellable == nil {
            nodCancellable = model.$nodCount
                .dropFirst()
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.nod() }
        }
        if running {
            resume()
            return
        }
        running = true
        play(nextIdle(), kind: .idle)
    }

    func stop() {
        running = false
        nodCancellable = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        players.forEach { $0.pause() }
    }

    /// 回到前景時接著播（App 進背景時系統會把播放器停掉）。
    func resume() {
        guard running else { return }
        players[front].play()
    }

    private func nod() {
        // 正在點頭就不插隊，這一次直接丟掉。
        guard running, current == .idle, let clip = pick(from: nodClips, avoiding: lastNod) else { return }
        lastNod = clip
        play(clip, kind: .nod)
    }

    private func nextIdle() -> URL {
        let clip = pick(from: idleClips, avoiding: lastIdle) ?? idleClips[0]
        lastIdle = clip
        return clip
    }

    /// 隨機挑一支，盡量不和上一支一樣。
    private func pick(from clips: [URL], avoiding last: URL?) -> URL? {
        let choices = clips.count > 1 ? clips.filter { $0 != last } : clips
        return choices.randomElement()
    }

    /// 在後面那台播放器載入新片段並開始播，再把它換到前面。
    private func play(_ url: URL, kind: Kind) {
        let next = 1 - front
        let item = AVPlayerItem(url: url)
        let player = players[next]
        player.replaceCurrentItem(with: item)
        player.seek(to: .zero)
        player.play()
        current = kind

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.clipEnded()
        }

        let previous = front
        front = next
        // 淡化結束後把舊的那台停掉，省電。期間如果又切回來就不停。
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fade + 0.1) { [weak self] in
            guard let self, self.front != previous else { return }
            self.players[previous].pause()
        }
    }

    private func clipEnded() {
        guard running else { return }
        play(nextIdle(), kind: .idle)
    }
}
