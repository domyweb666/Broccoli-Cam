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
/// 每支片的第一格和最後一格都接近同一張定格圖，但待機片中段的姿勢（頭的位置、大小、肩膀）和定格圖差很多：
/// 2026-11 用 ffmpeg 比臉部 SSIM，5 秒的待機片只有頭約 0.2 秒、尾約 0.3–0.4 秒接近定格圖（#92）。
/// 待機播到一半切反應片，畫面會看到人「跳一下」。所以反應只在接縫切：
/// 待機片剛開始（seamWindow 內）就馬上換；其他時候先排隊，這支待機稍微播快一點，播完直接接反應片；
/// 到接縫要等太久就不做這次反應。反應片頭尾也是定格圖，播完淡回待機沒有這個問題。
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

    /// 排隊等接縫的反應：前面這支待機片播完就接著播。
    private struct Queued {
        let index: Int
        let generation: Int
        /// 每排一次加一，保險計時器回來時才認得出是不是同一次。
        let token: Int
    }

    /// 交叉淡化的秒數。現在只在接縫切，兩邊畫面幾乎一樣，稍微拉長一點把剩下的小差異蓋掉。
    static let fade: TimeInterval = 0.3
    /// 反應片這麼久還沒載好就算了，太晚才反應很怪。
    private static let lateLimit: TimeInterval = 0.4
    /// 片子可以播了，但一直沒回報第一格解好，等這麼久就當作好了。
    private static let prerollLimit: TimeInterval = 0.3
    /// 待機片播不到這麼久，畫面還在定格圖附近，反應可以馬上切過去。
    private static let seamWindow: TimeInterval = 0.15
    /// 反應排隊時，待機片播快一點，早點回到接縫。待機動作很小，這個速度看不太出來；設 1 就不加速。
    private static let catchUpRate: Float = 1.4
    /// 保險：預估到接縫的時間過了這麼久，待機片還沒播完（片子卡住），就不等了。
    private static let seamSlack: TimeInterval = 0.3

    /// 排隊最多等多久（實際秒數，已經算進加速）。超過就不做這次反應，太晚做會對不上對方。
    private static func seamWaitLimit(_ reaction: CompanionReaction) -> TimeInterval {
        switch reaction {
        // 停頓後點頭：晚一點點頭，對方接著講也還是自然的附和。
        case .nod: return 2.0
        // 抬眉是對「突然大聲」的反應，慢了就不知道在回應什麼。
        case .brow: return 1.2
        // 往前靠是對方重新開口時做的，講個一兩句內靠過去都還對得上。
        case .lean: return 1.5
        // 歪頭是等對方繼續講，停頓本來就長，可以等最久。
        case .tilt: return 2.5
        }
    }

    /// 一台在前面播，其他的先載好接下來可能要播的：下一支待機、兩種最可能的反應。
    /// 媒體服務重啟之後舊的都不能用，會整組換新，畫面要跟著換。
    @Published private(set) var players: [AVPlayer] = CompanionClipPlayer.makePlayers()
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
    private var queued: Queued?
    private var queueToken = 0
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
    private var resetObserver: NSObjectProtocol?
    private var personCancellable: AnyCancellable?
    private var modelCancellables: Set<AnyCancellable> = []
    private weak var model: CompanionModel?

    /// 至少有一位聆聽者的待機片放進 App 才算可用。
    var isAvailable: Bool { assets != nil }

    private static func makePlayers() -> [AVPlayer] {
        (0..<4).map { _ in
            let player = AVPlayer()
            player.isMuted = true
            player.allowsExternalPlayback = false
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.automaticallyWaitsToMinimizeStalling = false
            player.actionAtItemEnd = .pause
            return player
        }
    }

    init() {
        resetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuild()
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

    deinit {
        if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    /// 媒體服務重啟：舊的播放器全部作廢，換一組新的，重新從定格圖開始。
    private func rebuild() {
        dropQueued()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        waiting = nil
        frontEnded = false
        switching = false
        current = .idle
        model?.isReacting = false
        broken = []
        clearScreen()
        players = Self.makePlayers()
        guard running else { return }
        playIdle()
        preload()
    }

    func stop() {
        dropQueued()
        running = false
        modelCancellables = []
        model?.onReaction = nil
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
        guard running else { return }
        // 進過背景，排隊時算的等待時間已經不準，這次反應放掉，待機片回原速。
        dropQueued()
        if players.indices.contains(front), !frontEnded {
            players[front].play()
            return
        }
        // 停在最後一格、或一支都沒播起來：再試一次，之前載不起來的也給它機會。
        guard waiting == nil else { return }
        broken = []
        playIdle()
        preload()
    }

    private func subscribe(to model: CompanionModel) {
        model.$nodCount
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in _ = self?.react(.nod) }
            .store(in: &modelCancellables)
        model.onReaction = { [weak self] reaction in
            self?.react(reaction) ?? false
        }
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
        // 排隊的是前一位的反應片，不播了；前一位的待機回原速，播到新的人載好。
        dropQueued()
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

    /// 回傳有沒有接下來要播（排隊等接縫也算，冷卻照算）。
    /// 回 true 之後才放棄的（等太晚、載不起來、換人、進背景），會呼叫 model 的 reactionDropped 把冷卻退回來。
    private func react(_ reaction: CompanionReaction) -> Bool {
        // 反應片還在播、正在換人、已經有一支反應在等或在排隊，就不插隊，這一次直接丟掉。
        // 排隊中又來新的，也是留先來的：先來的片已經在載、待機也加速了，換掉等於前面白等；
        // 即時反應兩次之間至少隔 3 秒，比最長的排隊時間還久，實際上幾乎碰不到。
        guard running, !switching, current == .idle, waiting?.kind != .reaction, queued == nil,
              let clip = upcoming(reaction) else { return false }
        // 先記成用掉了，換到前面時順手預載的才會挑下一支，不會把同一支再載一份。
        let previousLast = lastClip[.reaction]
        nextReaction[reaction] = nil
        lastClip[.reaction] = clip
        guard begin(clip, for: reaction) else {
            nextReaction[reaction] = clip
            lastClip[.reaction] = previousLast
            return false
        }
        preload()
        return true
    }

    /// 看前面的待機片播到哪裡，決定馬上換、排隊等接縫，還是這次不做。
    private func begin(_ clip: URL, for reaction: CompanionReaction) -> Bool {
        // 前面停在最後一格、或還沒有片（只看到定格圖），都和反應片第一格一樣，馬上接。
        guard players.indices.contains(front), !frontEnded else {
            return request(clip, kind: .reaction)
        }
        guard waiting == nil, let position = idlePosition() else { return false }
        // 待機片剛開始，還在定格圖附近：反應片已經載好就馬上換。
        if position.elapsed < Self.seamWindow, let index = loadedSlot(clip), slots[index].ready {
            present(index, kind: .reaction)
            return true
        }
        return enqueue(clip, for: reaction, remaining: position.remaining)
    }

    /// 前面那支片播了幾秒、還剩幾秒（片子本身的秒數，沒算播放速度）。
    private func idlePosition() -> (elapsed: TimeInterval, remaining: TimeInterval)? {
        guard players.indices.contains(front), let item = players[front].currentItem else { return nil }
        let elapsed = item.currentTime().seconds
        let duration = item.duration.seconds
        guard elapsed.isFinite, duration.isFinite, duration > 0 else { return nil }
        return (elapsed, max(0, duration - elapsed))
    }

    /// 排隊等接縫：反應片先在後面載好，這支待機片稍微播快一點，播完就接反應片。
    /// 照加速後的速度算，到接縫要等太久就不排。
    private func enqueue(_ clip: URL, for reaction: CompanionReaction, remaining: TimeInterval) -> Bool {
        let player = players[front]
        // 沒在播（例如剛被系統停掉）就等不到接縫。
        guard player.rate > 0 else { return false }
        let rate: Float = player.currentItem?.canPlayFastForward == true ? Self.catchUpRate : 1
        let wait = remaining / TimeInterval(rate)
        guard wait <= Self.seamWaitLimit(reaction), let index = slot(for: clip) else { return false }
        queueToken += 1
        let token = queueToken
        queued = Queued(index: index, generation: slots[index].generation, token: token)
        if player.rate != rate { player.rate = rate }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait + Self.seamSlack) { [weak self] in
            guard let self, self.queued?.token == token else { return }
            self.dropQueued()
        }
        return true
    }

    /// 放棄排隊中的反應：待機片回原速，告訴 model 這次沒做成（冷卻退回來）。
    /// 排隊用的那台留著載好的片，之後由 preload 決定要不要換掉。
    private func dropQueued() {
        guard queued != nil else { return }
        queued = nil
        restoreRate()
        model?.reactionDropped()
    }

    /// 前面那台如果被加速過，調回 1。rate 是 0 代表停著，設成 1 會讓它開始播，所以只動正在播的。
    /// 停著的那台下次 play() 會用 defaultRate（1），不用管。
    private func restoreRate() {
        guard players.indices.contains(front) else { return }
        let player = players[front]
        if player.rate > 0, player.rate != 1 { player.rate = 1 }
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
        index != front && !slots[index].fading && waiting?.index != index && queued?.index != index
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
        // 排隊的反應片載不起來：放掉，前面的待機照常播完接下一支待機。
        if queued?.index == index { dropQueued() }
        let wasWaiting = waiting?.index == index
        let kind = waiting?.kind
        if wasWaiting { waiting = nil }
        if wasWaiting && kind == .reaction { model?.reactionDropped() }
        unload(index)
        if nextIdle == clip { nextIdle = nil }
        nextReaction = nextReaction.filter { $0.value != clip }
        if wasWaiting && (kind == .idle || frontEnded) { playIdle() }
        preload()
    }

    // MARK: - 播放

    /// 播這支片。載好了就馬上換到前面，還沒載好就等它。沒有播放器可以用時回傳 false。
    private func request(_ clip: URL, kind: Kind) -> Bool {
        guard let index = slot(for: clip) else { return false }
        if slots[index].ready {
            present(index, kind: kind)
            return true
        }
        startWaiting(index: index, generation: slots[index].generation, kind: kind)
        return true
    }

    /// 拿一台裝著這支片的播放器：已經載好的優先，沒有就找一台來載。沒有播放器可以用時回傳 nil。
    private func slot(for clip: URL) -> Int? {
        if let loaded = loadedSlot(clip) { return loaded }
        guard let spare = spareSlot() else { return nil }
        load(clip, into: spare)
        return spare
    }

    /// 等這台載好再換到前面。反應片等太久就算了。
    private func startWaiting(index: Int, generation: Int, kind: Kind) {
        waiting = Waiting(index: index, generation: generation, kind: kind)
        guard kind == .reaction else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lateLimit) { [weak self] in
            self?.giveUpIfLate(index: index, generation: generation)
        }
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
        model?.reactionDropped()
        if frontEnded { playIdle() }
    }

    /// 從第 0 格開始播，換到前面。
    private func present(_ index: Int, kind: Kind) {
        // 排隊的反應到接縫時已經先拿掉；這裡還有就是別的片先上了，那次反應不播。
        dropQueued()
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
        if let queued {
            // 接縫到了，換排隊的反應片上來。還沒載好就照一般的等法（最多 lateLimit），
            // 這段時間畫面停在待機的最後一格，和反應片第一格一樣，晚一點接也看不出接縫。
            self.queued = nil
            guard slots[queued.index].generation == queued.generation else {
                model?.reactionDropped()
                playIdle()
                return
            }
            if slots[queued.index].ready {
                present(queued.index, kind: .reaction)
            } else {
                startWaiting(index: queued.index, generation: queued.generation, kind: .reaction)
            }
            return
        }
        // 有反應片正在等，就讓它接；沒有才接待機。
        if waiting == nil { playIdle() }
    }
}
