import AVFoundation
import Combine
import UIKit

/// 播放到哪裡。一秒更新十次，獨立出來才不會讓整張句子清單跟著重畫。
@MainActor
final class CaptionClock: ObservableObject {
    @Published var time: Double = 0
}

enum CaptionEditorError: LocalizedError {
    case notAuthorized
    /// 重新對的時候整支都沒聽到。
    case heardNothing

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "沒有語音辨識的權限"
        case .heardNothing: return "這次沒有辨識到，字幕維持原樣"
        }
    }
}

/// 校對頁：讀專案、對字幕、改句子、存檔、播放、燒錄。
@MainActor
final class CaptionEditorModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        /// 正在對字幕。
        case recognizing
        case failed(String)
        case ready
    }

    enum Burn: Equatable {
        case none
        case running(Double)
        /// 太燙停下來了，涼了會自己繼續。canLower：還能改成 1080p。
        case hot(canLower: Bool)
        case finished
        case failed(String)
    }

    enum Photo: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
        /// 沒有照片權限，要到設定打開。
        case denied
    }

    struct Limits {
        var portrait: Int
        var landscape: Int
    }

    private struct Snapshot {
        let lines: [CaptionLine]
        let style: CaptionStyle
    }

    let id: UUID
    /// 播放壞掉重新載入時會換一個新的。
    @Published private(set) var player = AVPlayer()
    let clock = CaptionClock()
    let exporter = CaptionExporter()

    @Published private(set) var phase: Phase = .loading
    /// 對字幕的進度 0–1。
    @Published private(set) var progress: Double = 0
    @Published private(set) var project: CaptionProject
    @Published private(set) var selectedID: UUID?
    /// 現在播到哪一句。
    @Published private(set) var playingID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var canUndo = false
    /// 來源是 4K 才給選。
    @Published private(set) var has4K = false
    @Published var resolution: CaptionResolution = .hd1080
    @Published private(set) var burn: Burn = .none
    @Published private(set) var burnPhoto: Photo = .idle
    @Published private(set) var originalPhoto: Photo = .idle
    /// 存檔沒成功的訊息，存成功就消失。
    @Published var saveError: String?
    /// 畫面上閃一下的字。
    @Published private(set) var note: String?
    /// 整支平移了幾秒。nil 是沒在平移。
    @Published private(set) var shiftOffset: Double?
    /// 影片播不出來的訊息。重新載入成功就消失。
    @Published private(set) var playerProblem: String?
    @Published private(set) var isReloading = false

    private let store = CaptionStore.shared
    private var video: CaptionVideo?
    private var limits = Limits(portrait: 12, landscape: 18)
    private var log: (String) -> Void = { _ in }

    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var noteTask: Task<Void, Never>?
    /// 每次重新對字幕換一張，晚到的進度不算數。
    private var recognizeTicket = 0

    private var undoStack: [Snapshot] = []
    private let undoLimit = 40
    /// 正在打字的那一句，連續打的字算一步撤銷。
    private var typingID: UUID?
    /// 游標在第幾個字元（UTF-16）。
    private var cursor = 0
    private var shiftBase: Snapshot?

    private var dirty = false
    /// 開啟之後改過東西。離開前一定再寫一次。
    private var touched = false

    private var timeObserver: Any?
    private var watches = Set<AnyCancellable>()
    private var seeking = false
    private var scrubTarget: Double?
    private var burnFraction: Double = 0

    init(id: UUID) {
        self.id = id
        project = CaptionProject(id: id, isLandscape: false, duration: 0, clips: [])
    }

    // MARK: - 開和關

    var pending: [CaptionLine] { project.lines.filter(\.blocksBurning) }
    var rest: [CaptionLine] { project.lines.filter { !$0.blocksBurning } }
    var isBurning: Bool {
        switch burn {
        case .running, .hot: return true
        default: return false
        }
    }
    /// 第一次對字幕，還沒有任何結果。
    var isFirstRecognition: Bool { project.recognition == nil && project.lines.isEmpty }
    var burnedURL: URL? { project.burnedFile.map { store.url($0, in: id) } }

    /// 畫面出現。重複呼叫沒有關係。
    func start(limits: Limits, log: @escaping (String) -> Void) {
        self.limits = limits
        self.log = log
        useAudioForPlayback()
        guard loadTask == nil else { return }
        loadTask = Task { await load() }
    }

    /// 失敗之後再試一次。
    func retry() {
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    /// 畫面消失：停播放器、寫檔、停掉還在跑的事。
    func teardown() {
        loadTask?.cancel()
        loadTask = nil
        recognizeTicket += 1
        endShift()
        if touched { saveNow(force: true, backup: true) }
        if isBurning { exporter.cancel() }
        burn = .none
        releasePlayer()
        playerProblem = nil
        isReloading = false
    }

    /// 離開前景可能直接被滑掉，先寫進檔案。
    func leaveForeground(toBackground: Bool) {
        if dirty || (toBackground && touched) { saveNow(force: true, backup: toBackground) }
        if toBackground { player.pause() }
    }

    /// 回到前景：停著的那一格可能在背景畫成黑的，重畫一次。
    func returnToForeground() {
        useAudioForPlayback()
        video?.refresh()
    }

    /// 要離開了。寫成功（或沒東西要寫）回 true。
    func finish(_ done: @escaping (Bool) -> Void) {
        player.pause()
        endShift()
        guard touched else {
            done(true)
            return
        }
        saveNow(force: true, backup: true, then: done)
    }

    private func load() async {
        phase = .loading
        do {
            var loaded = try await store.open(id)
            try Task.checkCancellation()
            var timeline: CaptionBridge.Timeline?
            if loaded.duration <= 0 {
                // 剛建好（或從備份救回來）的專案，長度和方向在這裡算。
                let measured = try await CaptionBridge.timeline(loaded)
                try Task.checkCancellation()
                loaded.duration = measured.total
                if let landscape = measured.isLandscape { loaded.isLandscape = landscape }
                timeline = measured
                project = loaded
                save()
            }
            project = loaded
            if isFirstRecognition {
                try await recognize(timeline)
            }
            try await openPlayer()
            selectedID = selectedID ?? pending.first?.id
            phase = .ready
        } catch {
            guard !Task.isCancelled else { return }
            log("字幕校對打不開：\(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    private func useAudioForPlayback() {
        // 相機會把音訊切成錄音，播放前切回來，聲音才會從喇叭出來。
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            log("校對音訊設定失敗：\(error.localizedDescription)")
        }
    }

    // MARK: - 對字幕

    /// keepsOnFailure：整支都沒聽到就丟錯、不換掉現有的字幕。
    private func recognize(_ known: CaptionBridge.Timeline?, keepsOnFailure: Bool = false) async throws {
        phase = .recognizing
        progress = 0
        guard await authorized() else { throw CaptionEditorError.notAuthorized }
        try Task.checkCancellation()
        recognizeTicket += 1
        let ticket = recognizeTicket
        // 切出去一下不要馬上斷掉。時間到系統會收回，斷掉的段落會標成沒辨識到。
        let background = BackgroundHold(name: "對字幕")
        defer { background.end() }

        let source = project
        let timeline: CaptionBridge.Timeline
        if let known {
            timeline = known
        } else {
            timeline = try await CaptionBridge.timeline(source)
        }
        try Task.checkCancellation()
        let maxChars = source.isLandscape ? limits.landscape : limits.portrait
        let result = try await CaptionBridge.build(
            source, timeline: timeline, maxChars: maxChars, log: log,
            progress: { @Sendable [weak self] value in
                Task { @MainActor [weak self] in
                    self?.recognitionMoved(value, ticket: ticket)
                }
            }
        )
        try Task.checkCancellation()
        if keepsOnFailure, CaptionBridge.heardNothing(result.lines, result.recognition) {
            throw CaptionEditorError.heardNothing
        }
        let isFirst = isFirstRecognition
        var next = project
        next.lines = CaptionEditing.cleaned(result.lines, duration: next.duration)
        next.recognition = result.recognition
        commit(next)
        // 打開時的備份是空的，第一次對好就換上。重新對的不換，備份留著打開時的字。
        saveNow(force: true, backup: isFirst)
    }

    private func recognitionMoved(_ value: Double, ticket: Int) {
        guard ticket == recognizeTicket, value.isFinite else { return }
        progress = max(progress, min(1, value))
    }

    private func authorized() async -> Bool {
        #if targetEnvironment(simulator)
        // 模擬器用假的辨識引擎，不用權限。
        if UserDefaults.standard.object(forKey: "debugFakeCaptions") != nil { return true }
        #endif
        if SpeechFollower.isAuthorized { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SpeechFollower.requestAuthorization { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// 重新對一次，改過的字會被蓋掉（可以撤銷）。失敗或取消就維持原樣。
    func recognizeAgain() {
        guard phase == .ready, !isBurning, !isReloading else { return }
        player.pause()
        endShift()
        let before = Snapshot(lines: project.lines, style: project.style)
        loadTask?.cancel()
        loadTask = Task {
            do {
                try await recognize(nil, keepsOnFailure: !before.lines.isEmpty)
                push(before)
                selectedID = pending.first?.id
            } catch {
                if !Task.isCancelled { show(error.localizedDescription) }
            }
            guard !Task.isCancelled else { return }
            phase = .ready
        }
    }

    /// 取消「重新對一次」。
    func cancelRecognizeAgain() {
        loadTask?.cancel()
        recognizeTicket += 1
        phase = .ready
    }

    // MARK: - 存檔

    private func save() {
        dirty = true
        touched = true
        saveNow()
    }

    /// 打字時不會停，所以固定隔一下寫一次，不是等停下來才寫。
    private func scheduleSave() {
        dirty = true
        touched = true
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow(force: Bool = false, deleting files: [String] = [], backup: Bool = false,
                         then: ((Bool) -> Void)? = nil) {
        saveTask?.cancel()
        saveTask = nil
        guard dirty || force else {
            then?(true)
            return
        }
        dirty = false
        store.save(project, deleting: files, backup: backup) { [weak self] error in
            if let error {
                self?.dirty = true
                self?.saveError = "字幕沒存成功：\(error.localizedDescription)"
            } else {
                self?.saveError = nil
            }
            then?(error == nil)
        }
    }

    // MARK: - 改句子

    /// 一次完整的修改：記一步撤銷、更新畫面、存檔。
    private func change(_ body: (inout CaptionProject) -> Void) {
        // 平移一律從開始時的句子算，中途改的字會被蓋掉，先把平移收尾。
        endShift()
        let before = Snapshot(lines: project.lines, style: project.style)
        var next = project
        body(&next)
        guard next.lines != before.lines || next.style != before.style else { return }
        typingID = nil
        push(before)
        commit(next)
    }

    private func commit(_ changed: CaptionProject) {
        var next = changed
        next.lines = CaptionEditing.sorted(next.lines)
        next.updatedAt = Date()
        if next.burnedFile != nil, burnContentDiffers(next, project) {
            next.isBurnStale = true
        }
        project = next
        video?.update(lines: next.burnLines, style: next.style)
        scheduleSave()
    }

    /// 燒出來會不會不一樣。只是按確認不算改過。
    private func burnContentDiffers(_ a: CaptionProject, _ b: CaptionProject) -> Bool {
        guard a.style == b.style else { return true }
        let first = a.burnLines
        let second = b.burnLines
        guard first.count == second.count else { return true }
        return zip(first, second).contains { left, right in
            left.text != right.text || left.start != right.start || left.end != right.end
        }
    }

    private func push(_ snapshot: Snapshot) {
        undoStack.append(snapshot)
        if undoStack.count > undoLimit { undoStack.removeFirst(undoStack.count - undoLimit) }
        canUndo = true
    }

    func undo() {
        guard shiftBase == nil, let last = undoStack.popLast() else { return }
        canUndo = !undoStack.isEmpty
        typingID = nil
        var next = project
        next.lines = last.lines
        next.style = last.style
        commit(next)
        if let selectedID, !next.lines.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    private func update(_ lineID: UUID, _ body: (inout CaptionLine) -> Void) {
        change { project in
            guard let index = project.lines.firstIndex(where: { $0.id == lineID }) else { return }
            body(&project.lines[index])
        }
    }

    /// 打字。連續改同一句算一步撤銷。
    func setText(_ text: String, of lineID: UUID) {
        guard let index = project.lines.firstIndex(where: { $0.id == lineID }),
              project.lines[index].text != text else { return }
        endShift()
        let before = Snapshot(lines: project.lines, style: project.style)
        if typingID != lineID {
            push(before)
            typingID = lineID
        }
        var next = project
        next.lines[index].text = text
        commit(next)
    }

    /// 開始打字，先停下來。
    func beganTyping(_ lineID: UUID) {
        player.pause()
        if selectedID != lineID { selectedID = lineID }
    }

    func endedTyping() {
        typingID = nil
    }

    /// 上一句收起來時會晚到，不是正在改的那句就不算。
    func moveCursor(_ utf16Offset: Int, in lineID: UUID) {
        guard selectedID == lineID else { return }
        cursor = utf16Offset
    }

    func confirm(_ lineID: UUID) {
        let start = project.lines.first { $0.id == lineID }?.start ?? 0
        update(lineID) { $0.isConfirmed = true }
        goToNextPending(after: start)
    }

    func confirmAll() {
        change { project in
            for index in project.lines.indices where project.lines[index].blocksBurning {
                project.lines[index].isConfirmed = true
            }
        }
    }

    /// 用稿子寫的、或用聽到的。選了就算確認。
    func choose(_ text: String, for lineID: UUID) {
        let start = project.lines.first { $0.id == lineID }?.start ?? 0
        update(lineID) { line in
            line.text = text
            line.isConfirmed = true
        }
        goToNextPending(after: start)
    }

    private func goToNextPending(after start: Double) {
        let left = pending
        guard let next = left.first(where: { $0.start >= start }) ?? left.first else {
            // 都確認完了。
            selectedID = nil
            player.pause()
            return
        }
        select(next.id)
    }

    func split(_ lineID: UUID) {
        guard let line = project.lines.first(where: { $0.id == lineID }) else { return }
        guard let (first, second) = CaptionEditing.split(line, atUTF16: cursor) else {
            show("把游標放在要拆開的地方")
            return
        }
        change { project in
            guard let index = project.lines.firstIndex(where: { $0.id == lineID }) else { return }
            project.lines[index] = first
            project.lines.insert(second, at: index + 1)
        }
        cursor = 0
    }

    func canMerge(_ line: CaptionLine) -> Bool {
        !line.isHidden && CaptionEditing.next(after: line.id, in: project.lines) != nil
    }

    func mergeNext(_ lineID: UUID) {
        guard let line = project.lines.first(where: { $0.id == lineID }), !line.isHidden,
              let next = CaptionEditing.next(after: lineID, in: project.lines) else { return }
        change { project in
            project.lines.removeAll { $0.id == next.id }
            guard let index = project.lines.firstIndex(where: { $0.id == lineID }) else { return }
            project.lines[index] = CaptionEditing.merged(line, next)
        }
        cursor = 0
    }

    func toggleHidden(_ lineID: UUID) {
        guard let line = project.lines.first(where: { $0.id == lineID }) else { return }
        let wasPending = line.blocksBurning
        change { project in
            project.lines = CaptionEditing.toggledHidden(lineID, in: project.lines, duration: project.duration)
        }
        // 不要的那句收掉就往下一句；拿回來的留在原地，可能還要改字。
        if wasPending, !line.isHidden { goToNextPending(after: line.start) }
    }

    func nudge(_ lineID: UUID, by delta: Double) {
        change { project in
            project.lines = CaptionEditing.nudge(lineID, by: delta, in: project.lines, duration: project.duration)
        }
        if let line = project.lines.first(where: { $0.id == lineID }) { seek(to: line.start) }
    }

    func replaceAll(_ find: String, with replacement: String) {
        let result = CaptionEditing.replaceAll(find, with: replacement, in: project.lines)
        change { $0.lines = result.lines }
        show(result.count == 0 ? "沒有找到" : "換了 \(result.count) 處")
    }

    func setStyle(_ style: CaptionStyle) {
        change { $0.style = style }
    }

    // MARK: - 整支平移

    func beginShift() {
        guard shiftBase == nil else { return }
        shiftBase = Snapshot(lines: project.lines, style: project.style)
        shiftOffset = 0
    }

    /// 都從一開始的位置算，來回按不會愈切愈短。
    func shift(by delta: Double) {
        guard let base = shiftBase, let offset = shiftOffset else { return }
        let next = ((offset + delta) * 10).rounded() / 10
        shiftOffset = next
        var changed = project
        changed.lines = next == 0
            ? base.lines
            : CaptionEditing.shifted(base.lines, by: next, duration: project.duration)
        commit(changed)
    }

    func endShift() {
        guard let base = shiftBase else { return }
        let gone = shiftedOutCount
        if shiftOffset != 0 { push(base) }
        shiftBase = nil
        shiftOffset = nil
        if gone > 0 { show(Self.shiftedOut(gone)) }
    }

    /// 平移之後整句跑到影片外面、看不到的有幾句。本來就看不到的不算。
    var shiftedOutCount: Int {
        guard let base = shiftBase, shiftOffset != 0 else { return 0 }
        let visible: Set<UUID> = Set(base.lines.filter { Self.isVisible($0) }.map(\.id))
        return project.lines.filter { visible.contains($0.id) && !Self.isVisible($0) }.count
    }

    static func shiftedOut(_ count: Int) -> String {
        "有 \(count) 句移到影片外面"
    }

    /// 剩不到 0.05 秒等於看不到。
    private static func isVisible(_ line: CaptionLine) -> Bool {
        !line.isHidden && line.end - line.start >= 0.05
            && !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 播放

    /// 點一句：跳過去播。
    func select(_ lineID: UUID) {
        guard let line = project.lines.first(where: { $0.id == lineID }) else { return }
        if selectedID != lineID { cursor = 0 }
        selectedID = lineID
        typingID = nil
        seek(to: line.start)
        player.play()
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
            return
        }
        if clock.time >= project.duration - 0.1 { seek(to: 0) }
        player.play()
    }

    func pause() {
        player.pause()
    }

    func scrub(to time: Double) {
        clock.time = time
        scrubTarget = time
        pumpSeek()
    }

    private func seek(to time: Double) {
        let target = min(max(0, time), max(0, project.duration - 0.05))
        scrub(to: target)
    }

    /// 前一次跳完才跳下一次，拖拉時不會塞車，最後停的位置一定會到。
    /// 影片還沒準備好就先記著，準備好會再來一次；這時候硬跳有閃退的紀錄。
    private func pumpSeek() {
        guard !seeking, let target = scrubTarget, player.currentItem?.status == .readyToPlay else { return }
        scrubTarget = nil
        seeking = true
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.seeking = false
                self?.pumpSeek()
            }
        }
    }

    private func openPlayer() async throws {
        releasePlayer()
        let video = CaptionBridge.makeVideo(project)
        try await video.prepare()
        let item: AVPlayerItem = try await video.playerItem()
        try Task.checkCancellation()
        video.update(lines: project.burnLines, style: project.style)
        self.video = video
        has4K = video.is4K
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        watchPlayer()
        watchItem(item)
    }

    private func watchItem(_ item: AVPlayerItem) {
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.itemMoved(status)
                }
            }
            .store(in: &watches)
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self else { return }
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                MainActor.assumeIsolated {
                    self.playbackBroke(error)
                }
            }
            .store(in: &watches)
        // 系統的影音服務重開過，手上的播放器就不能再用了。
        NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.playbackBroke(nil)
                }
            }
            .store(in: &watches)
    }

    private func itemMoved(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay: pumpSeek()
        case .failed: playbackBroke(player.currentItem?.error)
        default: break
        }
    }

    private func playbackBroke(_ error: Error?) {
        guard playerProblem == nil else { return }
        player.pause()
        playerProblem = "影片播不出來"
        guard let error else {
            log("字幕預覽停了：影音服務重新啟動")
            return
        }
        let detail = error as NSError
        log("字幕預覽播不出來：\(detail.localizedDescription)（\(detail.domain) \(detail.code)）")
    }

    /// 換一個新的播放器重來，停在原本的位置。字幕不受影響。
    func reloadPlayer() {
        guard phase == .ready, !isBurning, !isReloading else { return }
        isReloading = true
        let time = clock.time
        loadTask?.cancel()
        loadTask = Task {
            do {
                useAudioForPlayback()
                // 監看都掛在舊的播放器上，先拆掉再換。
                releasePlayer()
                player = AVPlayer()
                // 先清掉，新的那支又壞掉時才記得到。
                playerProblem = nil
                try await openPlayer()
                isReloading = false
                scrub(to: time)
            } catch {
                guard !Task.isCancelled else { return }
                isReloading = false
                playerProblem = "影片播不出來"
                log("字幕預覽重新載入失敗：\(error.localizedDescription)")
            }
        }
    }

    private func watchPlayer() {
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.isPlaying = status != .paused
                }
            }
            .store(in: &watches)
        let step = CMTime(value: 1, timescale: 10)
        timeObserver = player.addPeriodicTimeObserver(forInterval: step, queue: .main) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.ticked(time.seconds)
            }
        }
        exporter.$state
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                MainActor.assumeIsolated {
                    switch state {
                    case .idle: break
                    case .running(let fraction):
                        self.burnFraction = fraction
                        self.burnMoved()
                    case .done(let url): self.burnDone(url)
                    case .failed(let message): self.burnFailed(message)
                    case .cancelled: self.burnCancelled()
                    }
                }
            }
            .store(in: &watches)
        exporter.$isHot
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.burnMoved()
                }
            }
            .store(in: &watches)
    }

    private func ticked(_ seconds: Double) {
        guard seconds.isFinite, !seeking, scrubTarget == nil else { return }
        clock.time = seconds
        let current = project.burnLines.first { $0.start <= seconds && seconds < $0.end }?.id
        if current != playingID { playingID = current }
    }

    private func releasePlayer() {
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        watches.removeAll()
        player.replaceCurrentItem(with: nil)
        video = nil
        seeking = false
        scrubTarget = nil
        isPlaying = false
    }

    // MARK: - 燒錄

    func startBurn() {
        guard phase == .ready, project.canBurn, !isBurning else { return }
        guard let video else {
            // 重新載入還沒好，或沒載入成功。
            show("影片還沒載入好")
            return
        }
        player.pause()
        endShift()
        let wanted: CaptionResolution = has4K ? resolution : .hd1080
        burnFraction = 0
        burn = .running(0)
        burnPhoto = .idle
        saveNow()
        log("開始燒字幕 \(wanted.label)，\(project.burnLines.count) 句")
        exporter.start(video: video, lines: project.burnLines, style: project.style,
                       resolution: wanted, output: store.url(CaptionStore.newBurnedName(), in: id))
    }

    /// 太燙，改成 1080p 從頭燒。
    func continueAt1080() {
        exporter.continueAt1080()
    }

    /// 太燙也照燒。
    func keepBurning() {
        exporter.keepGoing()
    }

    func cancelBurn() {
        exporter.cancel()
    }

    /// 關掉燒錄的畫面，回去校對。
    func dismissBurn() {
        guard !isBurning else { return }
        burn = .none
    }

    private func burnMoved() {
        guard isBurning, exporter.isBusy else { return }
        burn = exporter.isHot
            ? .hot(canLower: exporter.resolution == .uhd4K)
            : .running(min(1, max(0, burnFraction)))
    }

    private func burnDone(_ url: URL) {
        guard isBurning else { return }
        keepAwake()
        var name = url.lastPathComponent
        let home = store.url(name, in: id)
        if !FileManager.default.fileExists(atPath: home.path) {
            // 不在專案資料夾裡就搬進來。
            name = CaptionStore.newBurnedName()
            do {
                try FileManager.default.moveItem(at: url, to: store.url(name, in: id))
            } catch {
                burnFailed(error.localizedDescription)
                return
            }
        }
        let old = project.burnedFile
        var next = project
        next.burnedFile = name
        // 選 4K 但中途改 1080p 的話，以實際輸出的為準。
        next.burnedResolution = exporter.resolution
        next.isBurnStale = false
        next.updatedAt = Date()
        project = next
        touched = true
        burn = .finished
        log("字幕燒好了")
        // 新的記下來之後才刪舊的。
        let outdated: [String] = old.map { $0 == name ? [] : [$0] } ?? []
        saveNow(force: true, deleting: outdated)
        saveBurnedToPhotos()
    }

    private func burnFailed(_ message: String) {
        guard isBurning else { return }
        keepAwake()
        burn = .failed(message)
        log("燒字幕失敗：\(message)")
    }

    private func burnCancelled() {
        guard isBurning else { return }
        keepAwake()
        burn = .none
    }

    /// 整個 app 開著都不熄螢幕，燒錄那邊收尾時可能會關掉。
    private func keepAwake() {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    // MARK: - 存到照片

    func saveBurnedToPhotos() {
        guard let url = burnedURL, burnPhoto != .saving else { return }
        burnPhoto = .saving
        PhotoSaver.save(videoAt: url) { [weak self] result in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.burnPhoto = Self.photo(result)
                // 燒完的畫面自己會顯示；從選單存的就閃一句。
                if self.burn == .none { self.tell(self.burnPhoto, saved: "字幕版已存到照片") }
            }
        }
    }

    /// 原片存到照片。多段的在這裡接起來，接好的只放暫存。
    func saveOriginal() {
        guard originalPhoto != .saving else { return }
        originalPhoto = .saving
        let source = self.project
        Task {
            let result = await Self.exportOriginal(source)
            originalPhoto = Self.photo(result)
            if burn == .none { tell(originalPhoto, saved: "原片已存到照片") }
        }
    }

    private func tell(_ photo: Photo, saved: String) {
        switch photo {
        case .saved: show(saved)
        case .failed(let message): show("沒有存到照片：\(message)")
        case .denied: show("沒有照片權限，請到「設定」打開")
        case .idle, .saving: break
        }
    }

    private static func exportOriginal(_ project: CaptionProject) async -> Result<Void, Error> {
        let clips = CaptionBridge.stitchClips(project)
        guard let first = clips.first else { return .failure(CaptionStoreError.videoMissing) }
        if clips.count == 1, first.start == nil, first.end == nil {
            return await savePhoto(first.url)
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("original-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: output) }
        do {
            try await VideoStitcher.stitch(clips, to: output)
        } catch {
            return .failure(error)
        }
        return await savePhoto(output)
    }

    private static func savePhoto(_ url: URL) async -> Result<Void, Error> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, Error>, Never>) in
            PhotoSaver.save(videoAt: url) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private static func photo(_ result: Result<Void, Error>) -> Photo {
        switch result {
        case .success:
            return .saved
        case .failure(let error):
            if let known = error as? PhotoSaveError, case .denied = known { return .denied }
            return .failed(error.localizedDescription)
        }
    }

    /// 寫一份 SRT 到暫存，給分享用。
    func srtFile() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("花椰菜相機字幕-\(formatter.string(from: Date())).srt")
        try CaptionBridge.srt(project).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 提示

    func show(_ text: String) {
        note = text
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.note = nil
        }
    }
}

/// 向系統借一點背景時間。時間到或做完就還。
private final class BackgroundHold: @unchecked Sendable {
    private var token: UIBackgroundTaskIdentifier = .invalid

    @MainActor
    init(name: String) {
        token = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.end()
            }
        }
    }

    @MainActor
    func end() {
        guard token != .invalid else { return }
        let finished = token
        token = .invalid
        UIApplication.shared.endBackgroundTask(finished)
    }
}
