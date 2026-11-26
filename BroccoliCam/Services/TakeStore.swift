import AVFoundation

/// 一段錄好的影片。只記檔名：App 更新後容器的絕對路徑會變。
struct SavedTake: Codable, Equatable {
    var file: String
    var firstSound: Double?
    var lastSound: Double?
    /// 錄完檢查時聽到的字，加字幕直接拿來用。沒檢查過、舊檔是 nil。
    var hearing: TakeHearing?
}

/// 分段錄到一半的進度。
struct SavedSession: Codable, Equatable {
    var segments: [String]
    var currentIndex: Int
    var takes: [Int: SavedTake]
    var takesLandscape: Bool?
    var pending: SavedTake?
    /// 錄 pending 那一刻介面轉的角度。
    var pendingAngle: Double
    var declinedSegments: [String]?
    /// 各段對字幕用的稿子，重點是空字串。舊檔沒有，等於全部照念。
    var captionScripts: [String]?
    /// 各段是不是提綱的重點。舊檔沒有，等於都不是。
    var points: [Bool]?
    /// declinedSegments 各段是不是重點。全稿和提綱切出來的字可能一樣，只比字分不出來。
    var declinedPoints: [Bool]?

    /// 各段。少記的、長度對不上的，都當成照念。
    var pieces: [ScriptPiece] {
        segments.indices.map { index in
            let text: String = segments[index]
            let isPoint: Bool = Self.value(points, index) ?? false
            let script: String = Self.value(captionScripts, index) ?? text
            // 重點一定沒有稿子，不管檔案裡寫什麼。
            return ScriptPiece(text: text, captionScript: isPoint ? "" : script, isPoint: isPoint)
        }
    }

    var declinedPieces: [ScriptPiece]? {
        declinedSegments.map { texts in
            texts.indices.map { index in
                let isPoint: Bool = Self.value(declinedPoints, index) ?? false
                return isPoint ? ScriptPiece.point(texts[index]) : ScriptPiece.spoken(texts[index])
            }
        }
    }

    private static func value<T>(_ list: [T]?, _ index: Int) -> T? {
        guard let list, list.indices.contains(index) else { return nil }
        return list[index]
    }

    /// 已經錄了幾段。
    var count: Int {
        takes.count + (pending == nil ? 0 : 1)
    }

    var files: [String] {
        takes.values.map(\.file) + (pending.map { [$0.file] } ?? [])
    }

    /// 拿掉這幾個檔之後剩下的進度。什麼都不剩就是 nil。
    func removing(_ gone: Set<String>) -> SavedSession? {
        var result = self
        result.takes = takes.filter { !gone.contains($0.value.file) }
        if let pending, gone.contains(pending.file) { result.pending = nil }
        if result.takes.isEmpty { result.takesLandscape = nil }
        return result.count == 0 ? nil : result
    }

    /// 不含聽到的字。
    var withoutHearings: SavedSession {
        var result = self
        for index in takes.keys { result.takes[index]?.hearing = nil }
        result.pending?.hearing = nil
        return result
    }

    /// 這支接好的影片是不是就由現在這幾段接成的。
    func matches(_ files: [String]?) -> Bool {
        guard let files, !files.isEmpty else { return false }
        return Set(files) == Set(takes.values.map(\.file))
    }
}

/// 正在錄的檔。開錄前就寫下來，錄到一半被滑掉才知道那個檔是哪一段的。
struct SavedRecording: Codable, Equatable {
    var file: String
    /// 分段錄影的第幾段；一鏡到底是 nil。
    var index: Int?
    var script: String
    var angle: Double
    /// 寫檔器說失敗、但檔案還在。下次開 App 再看一次能不能用。
    var failed = false
    /// 看過幾次都看不出好壞。
    var attempts = 0
    /// 正在接片的輸出檔：由哪幾段接成。一般錄影是 nil。
    var takes: [String]?
}

/// 完成、還沒存到照片的影片（一鏡到底，或接好的）。
struct SavedVideo: Codable, Equatable {
    var file: String
    var isStitched: Bool
    var script: String
    var isLandscape: Bool
    var notice: String?
    /// 由哪幾段接成。存到照片之後只刪這幾段。
    var takes: [String]?
    /// 一鏡到底那支錄完檢查時聽到的字。
    var hearing: TakeHearing?
}

struct TakeManifest: Codable, Equatable {
    var session: SavedSession?
    /// 切到「不看」時收著的進度。
    var shelf: SavedSession?
    var recordings: [SavedRecording] = []
    var videos: [SavedVideo] = []

    /// 不含聽到的字，小很多，提到的檔案一樣。聽到的字可以再聽一次，檔案清單不行。
    var withoutHearings: TakeManifest {
        var result = self
        result.session = session?.withoutHearings
        result.shelf = shelf?.withoutHearings
        for index in result.videos.indices { result.videos[index].hearing = nil }
        return result
    }

    /// 有提到的檔案。
    var files: Set<String> {
        var result = Set<String>()
        result.formUnion(session?.files ?? [])
        result.formUnion(shelf?.files ?? [])
        result.formUnion(recordings.map(\.file))
        result.formUnion(videos.map(\.file))
        return result
    }
}

/// 錄影檔和進度清單，放在 Application Support/takes/。
///
/// 兩條規矩，違反就會掉素材：
/// 1. 檔案開始寫之前，清單已經寫進硬碟提到它（flush 回 true 才開錄）。
/// 2. 刪檔一律排在「不再提到它的清單」寫成功之後。清單沒寫成功就先欠著不刪。
///
/// 寫檔、刪檔都在同一條佇列照順序做，不卡主執行緒。
final class TakeStore: @unchecked Sendable {
    static let shared = TakeStore()

    struct Loaded {
        var manifest = TakeManifest()
        /// 要記進除錯紀錄的話。
        var notes: [String] = []
    }

    /// 寫檔失敗之類的訊息。在 TakeStore 的佇列上呼叫，load 之前設好。
    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "org.domyweb.broccolicam.takes", qos: .userInitiated)
    private let folder: URL
    private static let manifestName = "manifest.json"
    private static let badPrefix = "manifest-bad-"
    private static let reserveName = "reserve.bin"
    private static let reserveSize = 128 * 1024
    private static let mergedPrefix = "broccoli-merged-"
    /// 短於這個長度的錄影當作沒錄到。
    private static let shortest: Double = 0.5
    /// 看不出好壞的檔案最多看幾次。
    private static let maxAttempts = 3

    // 以下只在 queue 上讀寫
    private var lastWritten: TakeManifest?
    private var lastSaveOK = true
    /// 清單讀不到：這次不寫也不清，免得蓋掉還好好的清單。
    private var blocked = false
    /// 清單還沒寫成功，欠著沒刪的檔。
    private var deferred: Set<String> = []
    /// 寫進硬碟幾次了。補寫完整清單前拿來看中間有沒有寫過更新的。
    private var writeCount = 0

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("takes", isDirectory: true)
    }

    // MARK: - 檔名

    /// 新的錄影檔名，不會和任何既有的檔重複。
    static func newFileName(merged: Bool = false) -> String {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let prefix = merged ? mergedPrefix : "broccoli-"
        return "\(prefix)\(stamp)-\(UUID().uuidString.prefix(4)).mov"
    }

    func url(_ file: String) -> URL {
        folder.appendingPathComponent(file)
    }

    // MARK: - 存檔

    /// 存下最新狀態，寫成功之後才刪 files。照呼叫的順序做。
    func save(_ manifest: TakeManifest, deleting files: [String] = []) {
        queue.async {
            self.commit(manifest, deleting: files)
        }
    }

    /// 等前面排的都做完，回傳最近一次有沒有寫成功。不要在主執行緒呼叫。
    func flush() -> Bool {
        queue.sync { lastSaveOK }
    }

    private func commit(_ manifest: TakeManifest, deleting files: [String]) {
        deferred.formUnion(files)
        if !blocked, manifest != lastWritten {
            if let light = quickVersion(of: manifest) {
                // 清單提到新的檔（多半是馬上要開錄的那個），開錄要等這次寫完。
                // 聽到的字很多時整份編碼要一下子，先寫不含聽到的字的那份（提到的檔案一樣，規矩 1 照樣成立），
                // 開錄就不用等；完整的那份排在後面馬上補寫。補寫之前被滑掉，只少了聽到的字，可以再聽一次。
                lastWritten = light
                writeCount += 1
                let mine = writeCount
                queue.async {
                    self.catchUp(manifest, after: mine)
                }
            } else {
                guard let written = write(manifest) else {
                    lastSaveOK = false
                    return
                }
                lastWritten = written
                writeCount += 1
            }
        }
        lastSaveOK = true
        let mentioned = manifest.files
        for file in deferred where !mentioned.contains(file) {
            try? FileManager.default.removeItem(at: url(file))
        }
        deferred.removeAll()
    }

    /// 提到新的檔、又帶著聽到的字時，先寫不含聽到的字的那份。寫成功回傳那份；不適用或沒寫成功是 nil，照一般的寫。
    private func quickVersion(of manifest: TakeManifest) -> TakeManifest? {
        // 開 App 第一次寫（還沒寫過）照一般的寫。
        guard let known = lastWritten?.files, !manifest.files.isSubset(of: known) else { return nil }
        let light = manifest.withoutHearings
        guard light != manifest, (try? writeOnce(light)) != nil else { return nil }
        makeReserve()
        return light
    }

    /// 補寫完整的那份。中間已經寫過更新的就不寫，不然會蓋掉新的。
    private func catchUp(_ manifest: TakeManifest, after count: Int) {
        guard !blocked, writeCount == count else { return }
        // 寫不進去（多半是硬碟滿了）就留著不含聽到的字的那份，和 write 寫不下時的做法一樣。
        guard (try? writeOnce(manifest)) != nil else { return }
        makeReserve()
        lastWritten = manifest
        writeCount += 1
    }

    /// 回傳真的寫進去的那份，沒寫成功是 nil。
    private func write(_ manifest: TakeManifest) -> TakeManifest? {
        do {
            try writeOnce(manifest)
        } catch {
            // 多半是硬碟滿了。聽到的字先不存，不要吃掉預留的空間，清單寫得進去才要緊。
            let light = manifest.withoutHearings
            if light != manifest, (try? writeOnce(light)) != nil { return light }
            // 放掉預留的空間再試一次，這樣才寫得下「這個檔可以刪了」。
            try? FileManager.default.removeItem(at: url(Self.reserveName))
            do {
                try writeOnce(light)
                return light
            } catch {
                onLog?("錄影清單沒存成功：\(error.localizedDescription)")
                return nil
            }
        }
        makeReserve()
        return manifest
    }

    private func writeOnce(_ manifest: TakeManifest) throws {
        try makeFolder()
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url(Self.manifestName), options: .atomic)
    }

    private func makeFolder() throws {
        guard !FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 影片很大，不進 iCloud 備份。
        var target = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    private func makeReserve() {
        let reserve = url(Self.reserveName)
        // 上次硬碟滿的時候可能只寫了一半，大小不夠就重寫。
        let attributes = try? FileManager.default.attributesOfItem(atPath: reserve.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size < Self.reserveSize else { return }
        try? Data(repeating: 0xA5, count: Self.reserveSize).write(to: reserve)
    }

    // MARK: - 開 App 時讀回來

    private struct Snapshot {
        var manifest = TakeManifest()
        /// 清單是什麼時候寫的。沒有清單就是很久以前。
        var date = Date.distantPast
        /// takes/ 裡的檔和最後修改時間（不含清單自己）。
        var files: [String: Date] = [:]
        var readable = true
        var notes: [String] = []
    }

    enum Verdict {
        case usable(isLandscape: Bool)
        case broken
        case unsure
    }

    /// 讀清單、看看正在錄的那個檔能不能用、清掉沒人提到的檔。
    /// 清單讀不到就什麼都不動。讀完之前不要呼叫 save。
    func load() async -> Loaded {
        let snapshot: Snapshot = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.read())
            }
        }
        var notes = snapshot.notes
        guard snapshot.readable else { return Loaded(manifest: TakeManifest(), notes: notes) }

        var manifest = snapshot.manifest
        let interrupted = manifest.recordings
        manifest.recordings = []
        dropMissing(&manifest, existing: Set(snapshot.files.keys), notes: &notes)
        // 各段對不上了，就當成單支：存完不准動到現在這幾段。
        for index in manifest.videos.indices where manifest.videos[index].isStitched {
            let owner = manifest.session ?? manifest.shelf
            if owner?.matches(manifest.videos[index].takes) != true {
                manifest.videos[index].isStitched = false
                manifest.videos[index].takes = nil
            }
        }

        for entry in interrupted {
            guard snapshot.files[entry.file] != nil, !manifest.files.contains(entry.file) else { continue }
            let verdict = await Self.examine(url(entry.file))
            Self.settle(entry, verdict, into: &manifest, notes: &notes)
        }

        // 沒人提到、又比清單新的影片：清單當時沒寫成功，或清單壞了。能播就當成還沒儲存的影片，不清掉。
        let examined = Set(interrupted.map(\.file))
        let strays = snapshot.files
            .filter { $0.value > snapshot.date && $0.key.hasSuffix(".mov") && !examined.contains($0.key) }
            .map { $0.key }
            .sorted()
        for file in strays where !manifest.files.contains(file) {
            let verdict = await Self.examine(url(file))
            let entry = SavedRecording(file: file, index: nil, script: "", angle: 0)
            Self.settle(entry, verdict, into: &manifest, notes: &notes)
        }

        // 沒有可用的段落就不算有進度。
        if manifest.session?.count == 0 { manifest.session = nil }
        if manifest.shelf?.count == 0 { manifest.shelf = nil }

        let kept = manifest
        let mentioned = kept.files
        let leftovers: [String] = snapshot.files.keys.filter { !mentioned.contains($0) }
        if !leftovers.isEmpty { notes.append("清掉沒用到的錄影檔 \(leftovers.count) 個") }
        // 這裡不等：後面的 save 排在同一條佇列，順序不會亂。
        save(kept, deleting: leftovers)
        return Loaded(manifest: kept, notes: notes)
    }

    /// 在 queue 上呼叫。
    private func read() -> Snapshot {
        var snapshot = Snapshot()
        let manager = FileManager.default
        let names: [String]
        do {
            try makeFolder()
            names = try manager.contentsOfDirectory(atPath: folder.path)
        } catch {
            return block(&snapshot, "錄影資料夾讀不到：\(error.localizedDescription)")
        }
        for name in names where name != Self.manifestName && name != Self.reserveName && !name.hasPrefix(Self.badPrefix) {
            let attributes = try? manager.attributesOfItem(atPath: url(name).path)
            snapshot.files[name] = (attributes?[.modificationDate] as? Date) ?? Date()
        }
        guard names.contains(Self.manifestName) else { return snapshot }

        let source = url(Self.manifestName)
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            // 讀不到不代表壞了（例如還沒解鎖）。
            return block(&snapshot, "錄影清單讀不到，這次不動任何檔案：\(error.localizedDescription)")
        }
        do {
            snapshot.manifest = try JSONDecoder().decode(TakeManifest.self, from: data)
            let attributes = try? manager.attributesOfItem(atPath: source.path)
            snapshot.date = (attributes?[.modificationDate] as? Date) ?? Date.distantPast
        } catch {
            // 壞檔改名留底。日期維持很久以前，資料夾裡能播的影片都會救回來，當成還沒儲存的影片。
            let name = "\(Self.badPrefix)\(Int(Date().timeIntervalSince1970)).json"
            do {
                try manager.moveItem(at: source, to: url(name))
                snapshot.notes.append("錄影清單打不開，已改名留底")
            } catch {
                return block(&snapshot, "錄影清單打不開，也搬不動：\(error.localizedDescription)")
            }
        }
        return snapshot
    }

    private func block(_ snapshot: inout Snapshot, _ note: String) -> Snapshot {
        blocked = true
        snapshot.readable = false
        snapshot.notes.append(note)
        return snapshot
    }

    /// 檔案不見的段落拿掉，其他的照留。
    private func dropMissing(_ manifest: inout TakeManifest, existing: Set<String>, notes: inout [String]) {
        let missing = manifest.files.subtracting(existing)
        if !missing.isEmpty { notes.append("有 \(missing.count) 個錄影檔不見了") }
        manifest.session = manifest.session.map { Self.trimmed($0, existing: existing) }
        manifest.shelf = manifest.shelf.map { Self.trimmed($0, existing: existing) }
        manifest.videos.removeAll { !existing.contains($0.file) }
    }

    private static func trimmed(_ session: SavedSession, existing: Set<String>) -> SavedSession {
        var result = session
        result.takes = session.takes.filter {
            session.segments.indices.contains($0.key) && existing.contains($0.value.file)
        }
        if let pending = session.pending, !existing.contains(pending.file) {
            result.pending = nil
        }
        result.currentIndex = min(max(0, session.currentIndex), max(0, session.segments.count - 1))
        if result.takes.isEmpty { result.takesLandscape = nil }
        return result
    }

    /// 錄到一半的檔要放回哪裡。
    private static func settle(_ entry: SavedRecording, _ verdict: Verdict,
                               into manifest: inout TakeManifest, notes: inout [String]) {
        switch verdict {
        case .broken:
            notes.append("錄到一半的檔不能用，略過 \(entry.file)")
        case .unsure:
            var again = entry
            again.failed = true
            again.attempts += 1
            if again.attempts >= maxAttempts {
                notes.append("錄到一半的檔一直打不開，略過 \(entry.file)")
            } else {
                notes.append("錄到一半的檔這次打不開，先留著 \(entry.file)")
                manifest.recordings.append(again)
            }
        case .usable(let isLandscape):
            notes.append("救回錄到一半的檔 \(entry.file)")
            if let index = entry.index, !entry.failed, var session = manifest.session,
               session.segments.indices.contains(index), session.pending == nil {
                session.pending = SavedTake(file: entry.file, firstSound: nil, lastSound: nil)
                session.pendingAngle = entry.angle
                session.currentIndex = index
                manifest.session = session
                return
            }
            // 接片前就記下由哪幾段接成，和現在的各段對得上才算接好的那支，對不上就當單支。
            let stitched = manifest.session?.matches(entry.takes) ?? false
            // 接好的那支能播就是寫完了，結尾是完整的。
            let merged = entry.file.hasPrefix(mergedPrefix)
            manifest.videos.append(SavedVideo(file: entry.file, isStitched: stitched,
                                              script: entry.script, isLandscape: isLandscape,
                                              notice: merged ? nil : "結尾有一小段沒存到",
                                              takes: stitched ? entry.takes : nil))
        }
    }

    // MARK: - 檢查影片

    /// 檔案能不能用。錄影時每 2 秒落地一次片段，被滑掉之後前面的通常還能播。
    static func examine(_ url: URL) async -> Verdict {
        await withCheckedContinuation { (continuation: CheckedContinuation<Verdict, Never>) in
            let reply = OneReply(continuation)
            Task.detached {
                reply.send(await Self.inspect(url))
            }
            // 讀檔卡住的話不能讓 App 一直不能錄。
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                reply.send(.unsure)
            }
        }
    }

    private static func inspect(_ url: URL) async -> Verdict {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            let playable: Bool = try await asset.load(.isPlayable)
            // 說不能播不代表壞了（例如媒體服務剛重啟），之後再判。
            guard playable else { return .unsure }
            let tracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .video)
            guard let video = tracks.first else { return .broken }
            let whole: CMTime = try await asset.load(.duration)
            let range: CMTimeRange = try await video.load(.timeRange)
            let size: CGSize = try await video.load(.naturalSize)
            let seconds: Double = max(number(whole), number(range.duration))
            guard seconds >= shortest else { return .broken }
            return .usable(isLandscape: size.width > size.height)
        } catch {
            return .unsure
        }
    }

    private static func number(_ time: CMTime) -> Double {
        time.isNumeric ? time.seconds : 0
    }

    /// 只回覆一次。
    private final class OneReply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Verdict, Never>?

        init(_ continuation: CheckedContinuation<Verdict, Never>) {
            self.continuation = continuation
        }

        func send(_ verdict: Verdict) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: verdict)
        }
    }
}
