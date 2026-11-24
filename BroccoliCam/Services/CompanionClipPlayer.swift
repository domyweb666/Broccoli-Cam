import AVFoundation
import Combine
import UIKit

/// 一位聆聽者的素材：一張定格圖、三支待機、幾支反應。
struct CompanionAssets {
    let stillURL: URL
    let idle: [URL]
    let reactions: [CompanionReaction: [URL]]

    /// 定格圖和待機片有放進 App 才算數；反應片可以缺。
    init?(person: CompanionPerson, bundle: Bundle = .main) {
        let prefix = "companion_\(person.rawValue)_"
        func urls(_ names: [String]) -> [URL] {
            names.compactMap { bundle.url(forResource: prefix + $0, withExtension: "mp4") }
        }
        let idle = urls(["idle_1", "idle_2", "idle_3"])
        guard let still = bundle.url(forResource: prefix + "still", withExtension: "jpg"), !idle.isEmpty else {
            return nil
        }
        stillURL = still
        self.idle = idle
        reactions = [
            .nod: urls(["nod_1", "nod_2"]),
            .brow: urls(["brow"]),
            .tilt: urls(["tilt"]),
            .lean: urls(["lean"])
        ]
    }

    /// 這個反應可以播哪些片。沒有抬眉、往前靠就退回點頭；
    /// 歪頭是在對方沒講話的時候做的，那時候點頭很怪，沒有就不做。
    func clips(for reaction: CompanionReaction) -> [URL] {
        let own = reactions[reaction] ?? []
        if !own.isEmpty || reaction == .tilt { return own }
        return reactions[.nod] ?? []
    }

    /// 素材有放進 App 的聆聽者。App 裝好之後不會變，算一次就好。
    static let available: [CompanionPerson] = CompanionPerson.allCases.filter { CompanionAssets(person: $0) != nil }

    /// 選的那一位沒有素材時，改用第一位有素材的。
    static func resolve(_ person: CompanionPerson) -> CompanionPerson? {
        available.contains(person) ? person : available.first
    }

    /// 選單用的小圖，縮過才不用每次都解整張。
    static func thumbnail(_ person: CompanionPerson) -> UIImage? {
        thumbnails[person]
    }

    private static let thumbnails: [CompanionPerson: UIImage] = {
        var result: [CompanionPerson: UIImage] = [:]
        for person in available {
            guard let assets = CompanionAssets(person: person),
                  let image = UIImage(contentsOfFile: assets.stillURL.path) else { continue }
            result[person] = image.preparingThumbnail(of: CGSize(width: 360, height: 640)) ?? image
        }
        return result
    }()
}

/// 播放聆聽者的預錄短片：待機片隨機輪播，要反應時淡入反應片，播完淡回待機。
/// 每支片的第一格和最後一格都是同一張定格圖，待機時動作又很小，所以任何時候切換都看不出接縫，
/// 不用等待機播完才反應。
/// 接下來可能要播的片（下一支待機、最可能的反應）先在後面的播放器載好，要用時馬上能從第 0 格播，
/// 沒載好之前不換到前面，所以不會有黑格。
/// 片子沒有音軌，播放器也靜音，不會碰到錄音用的 AVAudioSession。
final class CompanionClipPlayer: ObservableObject {
    private enum Kind { case idle, reaction }

    /// 後面的一台播放器裡裝了什麼。
    private struct Slot {
        var clip: URL?
        /// 第一格已經解好，按播放就有畫面。
        var ready = false
        /// 剛被蓋過去，淡化結束前還看得到，不能拿去載別的片。
        var fading = false
        /// 每載一次加一，舊的通知進來時才認得出來。
        var generation = 0
        var statusObserver: NSKeyValueObservation?
    }

    /// 要播但還沒載好的片。
    private struct Waiting {
        let index: Int
        let generation: Int
        let kind: Kind
    }

    /// 交叉淡化的秒數。
    static let fade: TimeInterval = 0.25
    /// 反應片這麼久還沒載好就算了，太晚才反應很怪。
    private static let lateLimit: TimeInterval = 0.4
    /// 片子可以播了，但一直沒回報第一格解好，等這麼久就當作好了。
    private static let prerollLimit: TimeInterval = 0.3

    /// 一台在前面播，其他的先載好接下來可能要播的：下一支待機、兩種最可能的反應。
    let players: [AVPlayer] = [AVPlayer(), AVPlayer(), AVPlayer(), AVPlayer()]
    /// 現在在前面的是哪一台，-1 是還沒有（只看到定格圖）。畫面看到變化就做淡化。
    @Published private(set) var front = -1
    /// 定格圖。播放器還沒出畫面的那一瞬間墊在底下，和片子第一格一樣。
    @Published private(set) var still: UIImage?

    private var person: CompanionPerson?
    /// 定格圖現在是誰。
    private var stillPerson: CompanionPerson?
    private var assets: CompanionAssets?
    private var slots: [Slot] = [Slot(), Slot(), Slot(), Slot()]
    private var waiting: Waiting?
    private var current: Kind = .idle
    /// 前面那支播完了，還沒有片可以接（停在最後一格）。
    private var frontEnded = false
    /// 換了人，新的人還沒淡進來。
    private var switching = false
    private var running = false

    /// 下一支待機、每種反應的下一支，先挑好才能先載。
    private var nextIdle: URL?
    private var nextReaction: [CompanionReaction: URL] = [:]
    private var lastClip: [Kind: URL] = [:]
    private var expecting: [CompanionReaction] = [.nod]
    /// 載入失敗的片，這次就不再試。
    private var broken: Set<URL> = []

    private var endObserver: NSObjectProtocol?
    private var personCancellable: AnyCancellable?
    private var modelCancellables: Set<AnyCancellable> = []
    private weak var model: CompanionModel?

    /// 至少有一位聆聽者的待機片放進 App 才算可用。
    var isAvailable: Bool { assets != nil }

    init() {
        for player in players {
            player.isMuted = true
            player.allowsExternalPlayback = false
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.automaticallyWaitsToMinimizeStalling = false
            player.actionAtItemEnd = .pause
        }
        // 一訂閱就會先收到目前選的那一位。
        personCancellable = UserDefaults.standard.publisher(for: \.companionPerson)
            .removeDuplicates()
            .sink { [weak self] raw in
                self?.choose(CompanionPerson(rawValue: raw ?? "") ?? .a)
            }
    }

    func start(model: CompanionModel) {
        guard isAvailable else { return }
        self.model = model
        if modelCancellables.isEmpty { subscribe(to: model) }
        if running {
            resume()
            return
        }
        running = true
        broken = []
        playIdle()
        preload()
    }

    func stop() {
        running = false
        modelCancellables = []
        model?.isReacting = false
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        waiting = nil
        frontEnded = false
        current = .idle
        players.forEach { $0.pause() }
        if switching {
            // 換到一半就離開，前面那台還是前一位。
            switching = false
            clearScreen()
            return
        }
        // 前面那台留著最後一格，其他的放掉，省記憶體。
        for index in slots.indices where index != front {
            unload(index)
        }
    }

    /// 回到前景時接著播（App 進背景時系統會把播放器停掉）。
    func resume() {
        guard running, players.indices.contains(front), !frontEnded else { return }
        players[front].play()
    }

    private func subscribe(to model: CompanionModel) {
        model.$nodCount
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.react(.nod) }
            .store(in: &modelCancellables)
        model.reactions
            .sink { [weak self] reaction in self?.react(reaction) }
            .store(in: &modelCancellables)
        model.expecting
            .sink { [weak self] reactions in
                self?.expecting = reactions
                self?.preload()
            }
            .store(in: &modelCancellables)
    }

    // MARK: - 換人

    private func choose(_ wanted: CompanionPerson) {
        guard let next = CompanionAssets.resolve(wanted), next != person,
              let loaded = CompanionAssets(person: next) else { return }
        person = next
        assets = loaded
        waiting = nil
        broken = []
        lastClip = [:]
        nextIdle = nil
        nextReaction = [:]

        guard running else {
            clearScreen()
            return
        }
        // 正在播：前一位繼續播到新的人載好，再淡過去。其他的先放掉。
        switching = true
        for index in slots.indices where index != front && !slots[index].fading {
            unload(index)
        }
        playIdle()
    }

    /// 沒在播的時候換人：把前一位的最後一格也清掉，下次開始時才不會閃過舊的人。
    private func clearScreen() {
        for index in slots.indices { unload(index) }
        front = -1
        showStill()
    }

    private func showStill() {
        guard let assets, stillPerson != person else { return }
        stillPerson = person
        still = UIImage(contentsOfFile: assets.stillURL.path)
    }

    // MARK: - 挑片

    private func react(_ reaction: CompanionReaction) {
        // 反應片還在播、正在換人、已經有一支反應在等，就不插隊，這一次直接丟掉。
        guard running, !switching, current == .idle, waiting?.kind != .reaction,
              let clip = upcoming(reaction) else { return }
        if request(clip, kind: .reaction) {
            nextReaction[reaction] = nil
            lastClip[.reaction] = clip
        }
    }

    private func playIdle() {
        guard running, let clip = upcomingIdle() else { return }
        if request(clip, kind: .idle) {
            nextIdle = nil
            lastClip[.idle] = clip
        }
    }

    private func upcomingIdle() -> URL? {
        if nextIdle == nil {
            nextIdle = pick(from: assets?.idle ?? [], avoiding: lastClip[.idle])
        }
        return nextIdle
    }

    private func upcoming(_ reaction: CompanionReaction) -> URL? {
        if nextReaction[reaction] == nil {
            nextReaction[reaction] = pick(from: assets?.clips(for: reaction) ?? [], avoiding: lastClip[.reaction])
        }
        return nextReaction[reaction]
    }

    /// 隨機挑一支，盡量不和上一支一樣。
    private func pick(from clips: [URL], avoiding last: URL?) -> URL? {
        let usable = clips.filter { !broken.contains($0) }
        let choices = usable.count > 1 ? usable.filter { $0 != last } : usable
        return choices.randomElement()
    }

    // MARK: - 載入

    /// 看不到、可以拿來載片的播放器。
    private func isFree(_ index: Int) -> Bool {
        index != front && !slots[index].fading && waiting?.index != index
    }

    private func loadedSlot(_ clip: URL) -> Int? {
        slots.indices.first { isFree($0) && slots[$0].clip == clip }
    }

    /// 接下來可能要播的先載好。重要的排前面，播放器不夠時後面的先不載。
    private func preload() {
        guard running, !switching else { return }
        var wanted: [URL] = []
        if let clip = upcomingIdle() { wanted.append(clip) }
        for reaction in expecting {
            if let clip = upcoming(reaction), !wanted.contains(clip) { wanted.append(clip) }
        }
        for clip in wanted where loadedSlot(clip) == nil {
            let spare = slots.indices.first { index -> Bool in
                guard isFree(index) else { return false }
                guard let holding = slots[index].clip else { return true }
                return !wanted.contains(holding)
            }
            guard let spare else { return }
            load(clip, into: spare)
        }
    }

    private func load(_ clip: URL, into index: Int) {
        let item = AVPlayerItem(url: clip)
        let player = players[index]
        player.pause()
        slots[index].statusObserver?.invalidate()
        slots[index].clip = clip
        slots[index].ready = false
        slots[index].generation += 1
        let generation = slots[index].generation
        slots[index].statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.statusChanged(index: index, generation: generation)
            }
        }
        player.replaceCurrentItem(with: item)
    }

    private func unload(_ index: Int) {
        slots[index].statusObserver?.invalidate()
        slots[index].statusObserver = nil
        slots[index].clip = nil
        slots[index].ready = false
        slots[index].fading = false
        slots[index].generation += 1
        players[index].replaceCurrentItem(with: nil)
    }

    private func statusChanged(index: Int, generation: Int) {
        guard slots[index].generation == generation, !slots[index].ready, let clip = slots[index].clip,
              let item = players[index].currentItem else { return }
        switch item.status {
        case .readyToPlay:
            break
        case .failed:
            loadFailed(clip, index: index)
            return
        default:
            return
        }
        let player = players[index]
        // preroll 在播放器還沒準備好或正在播時會直接當掉，先確認。
        guard player.status == .readyToPlay, player.rate == 0 else {
            becameReady(index: index, generation: generation)
            return
        }
        player.preroll(atRate: 1) { [weak self] _ in
            DispatchQueue.main.async {
                self?.becameReady(index: index, generation: generation)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.prerollLimit) { [weak self] in
            self?.becameReady(index: index, generation: generation)
        }
    }

    private func becameReady(index: Int, generation: Int) {
        guard slots[index].generation == generation, !slots[index].ready else { return }
        slots[index].ready = true
        if let waiting, waiting.index == index, waiting.generation == generation {
            present(index, kind: waiting.kind)
        }
    }

    private func loadFailed(_ clip: URL, index: Int) {
        broken.insert(clip)
        let wasWaiting = waiting?.index == index
        let kind = waiting?.kind
        if wasWaiting { waiting = nil }
        unload(index)
        if nextIdle == clip { nextIdle = nil }
        nextReaction = nextReaction.filter { $0.value != clip }
        if wasWaiting && (kind == .idle || frontEnded) { playIdle() }
        preload()
    }

    // MARK: - 播放

    /// 播這支片。載好了就馬上換到前面，還沒載好就等它。沒有播放器可以用時回傳 false。
    private func request(_ clip: URL, kind: Kind) -> Bool {
        let index: Int
        if let loaded = loadedSlot(clip) {
            index = loaded
        } else if let spare = spareSlot() {
            load(clip, into: spare)
            index = spare
        } else {
            return false
        }
        if slots[index].ready {
            present(index, kind: kind)
            return true
        }
        let generation = slots[index].generation
        waiting = Waiting(index: index, generation: generation, kind: kind)
        if kind == .reaction {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lateLimit) { [weak self] in
                self?.giveUpIfLate(index: index, generation: generation)
            }
        }
        return true
    }

    /// 臨時要載片時用哪一台：先用空的，再用載了但不是下一支待機的。
    private func spareSlot() -> Int? {
        let free = slots.indices.filter { isFree($0) }
        return free.first { slots[$0].clip == nil }
            ?? free.first { slots[$0].clip != nextIdle }
            ?? free.first
    }

    private func giveUpIfLate(index: Int, generation: Int) {
        guard let waiting, waiting.index == index, waiting.generation == generation else { return }
        self.waiting = nil
        if frontEnded { playIdle() }
    }

    /// 從第 0 格開始播，換到前面。
    private func present(_ index: Int, kind: Kind) {
        let player = players[index]
        player.play()
        waiting = nil
        switching = false
        frontEnded = false
        current = kind
        model?.isReacting = kind == .reaction

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        if let item = player.currentItem {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                self?.clipEnded()
            }
        }

        // 定格圖和影片同一刻換人，淡化中不會透出前一位。
        showStill()
        let previous = front
        front = index
        guard slots.indices.contains(previous), previous != index else {
            preload()
            return
        }
        // 淡化結束後把舊的那台停掉，空出來載下一支。
        slots[previous].fading = true
        let generation = slots[previous].generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fade + 0.1) { [weak self] in
            self?.release(previous, generation: generation)
        }
    }

    private func release(_ index: Int, generation: Int) {
        guard slots[index].generation == generation, slots[index].fading else { return }
        slots[index].fading = false
        slots[index].clip = nil
        slots[index].ready = false
        players[index].pause()
        guard running else { return }
        // 剛剛沒有播放器可以用，現在有了。
        if waiting == nil && (frontEnded || switching) { playIdle() }
        preload()
    }

    private func clipEnded() {
        guard running else { return }
        frontEnded = true
        current = .idle
        model?.isReacting = false
        // 有反應片正在等，就讓它接；沒有才接待機。
        if waiting == nil { playIdle() }
    }
}
