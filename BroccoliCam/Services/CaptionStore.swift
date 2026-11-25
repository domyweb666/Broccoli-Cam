import AVFoundation

/// 要放進字幕專案的一段影片。
struct CaptionSource: Equatable {
    let url: URL
    /// 保留的範圍（秒）。nil 是整段。
    var start: Double?
    var end: Double?
    var script = ""
    /// 錄完檢查時聽到的字，有就不用再辨識一次。
    var hearing: TakeHearing?
}

/// 字幕專案列表的一列。
struct CaptionEntry: Identifiable {
    let id: UUID
    /// nil 是這次讀不到（不代表壞了），檔案都還在。
    var project: CaptionProject?
    /// 占用空間，約略值：硬連結沒有去重。
    var bytes: Int64
    /// 有影片檔不見了，不能再燒。
    var isMissingVideo: Bool
}

enum CaptionStoreError: LocalizedError {
    case sourceMissing
    case videoMissing
    case notFound
    case noSpace
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing: return "這支影片的檔案不見了。"
        case .videoMissing: return "這個專案的影片檔不見了。"
        case .notFound: return "這個字幕專案已經刪掉了。"
        case .noSpace: return "手機空間不夠，請先清出一些空間。"
        case .unreadable(let reason): return "字幕專案這次讀不到：\(reason)"
        }
    }
}

/// 字幕專案，放在 Application Support/captions/{專案編號}/。
///
/// 每個專案有自己的原片（和 takes/ 互不影響的硬連結）、project.json、燒好的影片。規矩：
/// 1. 新專案先在暫存資料夾做齊，最後一步才改成正式的名字。做到一半被滑掉，原片還在 takes/。
/// 2. project.json 一次換上；舊的燒錄檔等「不再提到它的 project.json」寫成功才刪。
/// 3. project.json 壞了改名留底，從備份或資料夾裡的影片救回來，影片一律不刪。
/// 4. 只動 captions/ 裡的東西，不碰 TakeStore 的檔。
///
/// 讀寫都在同一條佇列照順序做，不卡主執行緒。
final class CaptionStore: @unchecked Sendable {
    static let shared = CaptionStore()

    /// 燒好的影片檔名開頭。
    static let burnedPrefix = "burned-"
    /// 還沒燒完的檔名開頭，和 CaptionExporter 的一樣。
    private static let burningPrefix = ".burning-"

    /// 寫檔失敗之類的訊息。在這裡的佇列上呼叫，start 之前設好。
    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "org.domyweb.broccolicam.captions", qos: .userInitiated)
    private let root: URL
    private let manager = FileManager()

    private static let projectName = "project.json"
    private static let backupName = "project-backup.json"
    private static let badPrefix = "project-bad-"
    private static let stagingPrefix = ".new-"
    private static let trashPrefix = ".trash-"
    private static let reserveName = "reserve.bin"
    private static let reserveSize = 512 * 1024

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("captions", isDirectory: true)
    }

    // MARK: - 路徑

    func folder(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func url(_ file: String, in id: UUID) -> URL {
        folder(id).appendingPathComponent(file)
    }

    /// 新的燒錄檔名，不會蓋到上一次的。
    static func newBurnedName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(burnedPrefix)\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4)).mov"
    }

    // MARK: - 開 App

    /// 收拾上次做到一半的東西。開 App 時叫一次。
    func start() {
        queue.async {
            self.tidy()
        }
    }

    private func tidy() {
        guard let names = try? manager.contentsOfDirectory(atPath: root.path) else { return }
        for name in names {
            let item = root.appendingPathComponent(name)
            if name.hasPrefix(Self.trashPrefix) {
                // 使用者確認過要刪的，上次沒刪完。
                try? manager.removeItem(at: item)
            } else if name.hasPrefix(Self.stagingPrefix) {
                finishStaging(item)
            }
        }
    }

    /// project.json 是建立時最後才寫的，讀得到就代表影片都進來了，只差改名。
    private func finishStaging(_ item: URL) {
        let source = item.appendingPathComponent(Self.projectName)
        if manager.fileExists(atPath: source.path) {
            guard let data = try? Data(contentsOf: source) else { return }
            if let project = Self.decode(data) {
                do {
                    try manager.moveItem(at: item, to: folder(project.id))
                    onLog?("字幕專案上次建到最後一步，接著建好了")
                } catch {
                    onLog?("字幕專案的暫存資料夾改不了名：\(error.localizedDescription)")
                }
                return
            }
        }
        // 還沒做齊。裡面的都是連結，原片還在 takes/。
        try? manager.removeItem(at: item)
        onLog?("清掉建到一半的字幕專案")
    }

    // MARK: - 建立

    /// 把影片連進新專案。失敗時什麼都不會留下，來源不動。
    func create(sources: [CaptionSource], isLandscape: Bool, style: CaptionStyle) async throws -> CaptionProject {
        try await run {
            try self.make(sources, isLandscape: isLandscape, style: style)
        }
    }

    /// 用同一批影片、同樣的裁切和稿子建過的專案。完成頁離開再回來、或重開 App 之後再按一次，才不會多一份。
    /// 改過「裁靜音」再接一次就是另一支影片，長度不同，不能沿用舊的。
    func existing(for sources: [CaptionSource]) async -> CaptionProject? {
        let wanted: [String] = sources.map { $0.url.lastPathComponent }
        let scripts: [String] = sources.map { Self.flat($0.script) }
        let found: [CaptionProject] = await candidates { project in
            project.clips.map(\.file) == wanted && project.clips.map({ Self.flat($0.script) }) == scripts
        }
        guard !found.isEmpty else { return nil }
        if let exact = Self.best(found.filter { Self.sameCuts($0, sources) }) { return exact }

        // 數字不同不代表裁得不同：裁到檔案外面、或裁完太短而整段保留，接出來都和沒裁一樣。
        // 看實際留下的範圍再比一次，才不會只因為這樣就另開一份，改過的字像不見了。
        var wantedRanges: [ClosedRange<Double>] = []
        var spans: [ClosedRange<Double>] = []
        for source in sources {
            guard let span = await Self.fileSpan(source.url) else { return nil }
            spans.append(span)
            wantedRanges.append(Self.kept(source.start, source.end, in: span))
        }
        let same: [CaptionProject] = found.filter { project in
            guard project.clips.count == spans.count else { return false }
            return project.clips.indices.allSatisfy { index in
                let clip: CaptionClip = project.clips[index]
                let range: ClosedRange<Double> = Self.kept(clip.start, clip.end, in: spans[index])
                return Self.near(range.lowerBound, wantedRanges[index].lowerBound)
                    && Self.near(range.upperBound, wantedRanges[index].upperBound)
            }
        }
        return Self.best(same)
    }

    /// 重開 App 救回來的接好影片：只知道由哪幾段接成，不知道各段裁到哪裡。
    /// 檔名和順序都一樣、總長也一樣，才是同一支。length 讀不到（nil）就只看檔名。
    func existing(takes: [String], length: Double?) async -> CaptionProject? {
        guard !takes.isEmpty else { return nil }
        let found: [CaptionProject] = await candidates { $0.clips.map(\.file) == takes }
        guard let length, length.isFinite else { return Self.best(found) }
        return Self.best(found.filter { abs($0.duration - length) <= 0.5 })
    }

    private func candidates(_ fits: @escaping (CaptionProject) -> Bool) async -> [CaptionProject] {
        let found: [CaptionProject]? = try? await run { () -> [CaptionProject] in
            self.ids().compactMap { id -> CaptionProject? in
                guard let project = try? self.read(id), fits(project), !self.isMissingVideo(project) else { return nil }
                return project
            }
        }
        return found ?? []
    }

    /// 對得上的不只一個時，有字幕的優先，再來是最近改過的。
    private static func best(_ projects: [CaptionProject]) -> CaptionProject? {
        projects.max { first, second in
            if first.lines.isEmpty != second.lines.isEmpty { return first.lines.isEmpty }
            return first.updatedAt < second.updatedAt
        }
    }

    /// 空白和換行不算差別。
    private static func flat(_ script: String) -> String {
        script.filter { !$0.isWhitespace }
    }

    private static func near(_ first: Double?, _ second: Double?) -> Bool {
        guard let first, let second else { return first == nil && second == nil }
        return abs(first - second) <= 0.01
    }

    private static func sameCuts(_ project: CaptionProject, _ sources: [CaptionSource]) -> Bool {
        guard project.clips.count == sources.count else { return false }
        return zip(project.clips, sources).allSatisfy { clip, source in
            near(clip.start, source.start) && near(clip.end, source.end)
        }
    }

    /// 影片檔本身的範圍（秒）。
    private static func fileSpan(_ url: URL) async -> ClosedRange<Double>? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange) else { return nil }
        let lower: Double = range.start.seconds
        let upper: Double = range.end.seconds
        guard lower.isFinite, upper.isFinite, upper > lower else { return nil }
        return lower...upper
    }

    /// 接片時實際留下的範圍，規則和 VideoStitcher 一樣：裁完太短就整段保留。
    private static func kept(_ start: Double?, _ end: Double?, in span: ClosedRange<Double>) -> ClosedRange<Double> {
        let first: Double = max(span.lowerBound, start ?? span.lowerBound)
        let last: Double = min(span.upperBound, end ?? span.upperBound)
        return last - first < 0.5 ? span : first...last
    }

    private func make(_ sources: [CaptionSource], isLandscape: Bool, style: CaptionStyle) throws -> CaptionProject {
        guard !sources.isEmpty else { throw CaptionStoreError.sourceMissing }
        let id = UUID()
        let staging = root.appendingPathComponent(Self.stagingPrefix + id.uuidString, isDirectory: true)
        do {
            try makeRoot()
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            var clips: [CaptionClip] = []
            for (index, source) in sources.enumerated() {
                guard manager.fileExists(atPath: source.url.path) else { throw CaptionStoreError.sourceMissing }
                var name = source.url.lastPathComponent
                if clips.contains(where: { $0.file == name }) { name = "\(index)-\(name)" }
                try attach(source.url, to: staging.appendingPathComponent(name))
                clips.append(CaptionClip(file: name, start: source.start, end: source.end, script: source.script,
                                         hearing: source.hearing))
            }
            let project = CaptionProject(id: id, isLandscape: isLandscape, duration: 0, clips: clips, style: style)
            let data = try Self.encode(project)
            try write(data, to: staging.appendingPathComponent(Self.backupName))
            try write(data, to: staging.appendingPathComponent(Self.projectName))
            try manager.moveItem(at: staging, to: folder(id))
            return project
        } catch {
            try? manager.removeItem(at: staging)
            onLog?("字幕專案沒建成：\(error.localizedDescription)")
            throw Self.readable(error)
        }
    }

    /// 硬連結不佔空間，takes/ 那邊刪掉也不影響這裡。連不成才複製。
    private func attach(_ source: URL, to target: URL) throws {
        do {
            try manager.linkItem(at: source, to: target)
        } catch {
            onLog?("硬連結不成，改用複製：\(error.localizedDescription)")
            try? manager.removeItem(at: target)
            try manager.copyItem(at: source, to: target)
        }
    }

    // MARK: - 讀

    /// 打開專案。順手備份一份讀得懂的 project.json，並清掉燒到一半的檔。
    func open(_ id: UUID) async throws -> CaptionProject {
        try await run { () -> CaptionProject in
            let project = try self.read(id)
            guard !self.isMissingVideo(project) else { throw CaptionStoreError.videoMissing }
            if let data = try? Self.encode(project) {
                try? self.write(data, to: self.url(Self.backupName, in: id))
            }
            self.sweep(project)
            return project
        }
    }

    /// 所有專案，新的在前面。
    func list() async throws -> [CaptionEntry] {
        try await run { () -> [CaptionEntry] in
            let entries: [CaptionEntry] = self.ids().compactMap { self.entry($0) }
            return entries.sorted { first, second in
                (first.project?.createdAt ?? .distantPast) > (second.project?.createdAt ?? .distantPast)
            }
        }
    }

    private func entry(_ id: UUID) -> CaptionEntry? {
        let bytes = size(of: id)
        do {
            let project = try read(id)
            return CaptionEntry(id: id, project: project, bytes: bytes, isMissingVideo: isMissingVideo(project))
        } catch CaptionStoreError.notFound {
            return nil
        } catch CaptionStoreError.videoMissing {
            return CaptionEntry(id: id, project: nil, bytes: bytes, isMissingVideo: true)
        } catch {
            return CaptionEntry(id: id, project: nil, bytes: bytes, isMissingVideo: false)
        }
    }

    private func ids() -> [UUID] {
        let names = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { UUID(uuidString: $0) }
    }

    private func read(_ id: UUID) throws -> CaptionProject {
        guard manager.fileExists(atPath: folder(id).path) else { throw CaptionStoreError.notFound }
        let source = url(Self.projectName, in: id)
        guard manager.fileExists(atPath: source.path) else { return try rescue(id) }
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            // 讀不到不代表壞了（例如還沒解鎖），這次什麼都不動。
            throw CaptionStoreError.unreadable(error.localizedDescription)
        }
        guard var project = Self.decode(data) else {
            do {
                let name = "\(Self.badPrefix)\(Int(Date().timeIntervalSince1970 * 1000)).json"
                try manager.moveItem(at: source, to: url(name, in: id))
                onLog?("字幕專案打不開，已改名留底")
            } catch {
                throw CaptionStoreError.unreadable(error.localizedDescription)
            }
            return try rescue(id)
        }
        project.id = id
        if let burned = project.burnedFile, !manager.fileExists(atPath: url(burned, in: id).path) {
            project.burnedFile = nil
            project.burnedResolution = nil
            project.isBurnStale = false
        }
        return project
    }

    /// project.json 不見或壞了：先用備份，再不行就拿資料夾裡的影片重建一個沒有字幕的。
    private func rescue(_ id: UUID) throws -> CaptionProject {
        var project: CaptionProject
        if let data = try? Data(contentsOf: url(Self.backupName, in: id)), let saved = Self.decode(data) {
            project = saved
        } else {
            let names = (try? manager.contentsOfDirectory(atPath: folder(id).path)) ?? []
            let movies: [String] = names
                .filter { $0.hasSuffix(".mov") && !$0.hasPrefix(Self.burnedPrefix) && !$0.hasPrefix(".") }
                .sorted()
            guard !movies.isEmpty else { throw CaptionStoreError.videoMissing }
            let clips: [CaptionClip] = movies.map { CaptionClip(file: $0, start: nil, end: nil, script: "") }
            // 長度 0 代表還沒算過，打開時會補算長度和方向。
            project = CaptionProject(isLandscape: false, duration: 0, clips: clips)
        }
        project.id = id
        // 備份可能比較舊，燒好的那支如果還在就認回來。
        if project.burnedFile.map({ !manager.fileExists(atPath: url($0, in: id).path) }) ?? true {
            project.burnedFile = newestBurned(id)
            project.isBurnStale = project.burnedFile != nil
        }
        if let data = try? Self.encode(project) {
            try? write(data, to: url(Self.projectName, in: id))
        }
        onLog?("字幕專案已經從備份救回來")
        return project
    }

    private func newestBurned(_ id: UUID) -> String? {
        let names = (try? manager.contentsOfDirectory(atPath: folder(id).path)) ?? []
        // 檔名開頭是時間，排序就是先後。
        return names.filter { $0.hasPrefix(Self.burnedPrefix) && $0.hasSuffix(".mov") }.sorted().last
    }

    private func isMissingVideo(_ project: CaptionProject) -> Bool {
        project.clips.isEmpty || project.clips.contains {
            !manager.fileExists(atPath: url($0.file, in: project.id).path)
        }
    }

    private func size(of id: UUID) -> Int64 {
        let names = (try? manager.contentsOfDirectory(atPath: folder(id).path)) ?? []
        var total: Int64 = 0
        for name in names {
            let attributes = try? manager.attributesOfItem(atPath: url(name, in: id).path)
            total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return total
    }

    /// 燒到一半被滑掉留下的檔。只刪燒錄檔，原片不動。
    private func sweep(_ project: CaptionProject) {
        let keep = Set(project.clips.map(\.file) + [project.burnedFile].compactMap { $0 })
        let names = (try? manager.contentsOfDirectory(atPath: folder(project.id).path)) ?? []
        for name in names where !keep.contains(name) {
            guard name.hasPrefix(Self.burnedPrefix) || name.hasPrefix(Self.burningPrefix) else { continue }
            try? manager.removeItem(at: url(name, in: project.id))
            onLog?("清掉沒燒完的影片 \(name)")
        }
    }

    // MARK: - 寫

    /// 存檔，照呼叫的順序寫。寫成功之後才刪 files（只給舊的燒錄檔用）。then 在主執行緒。
    /// backup：寫成功之後備份也換成這一份。
    func save(_ project: CaptionProject, deleting files: [String] = [], backup: Bool = false,
              then: @escaping @MainActor (Error?) -> Void) {
        queue.async {
            var failure: Error?
            do {
                // 專案已經刪掉的話資料夾不在，不可以又長回來。
                guard self.manager.fileExists(atPath: self.folder(project.id).path) else {
                    throw CaptionStoreError.notFound
                }
                let data = try Self.encode(project)
                try self.write(data, to: self.url(Self.projectName, in: project.id))
                if backup {
                    // 備份寫不進去沒關係，不動用預留的空間。
                    try? data.write(to: self.url(Self.backupName, in: project.id), options: .atomic)
                }
                let keep = Set(project.clips.map(\.file) + [project.burnedFile].compactMap { $0 })
                for file in files where !keep.contains(file) && file.hasPrefix(Self.burnedPrefix) {
                    try? self.manager.removeItem(at: self.url(file, in: project.id))
                }
            } catch {
                self.onLog?("字幕專案沒存成功：\(error.localizedDescription)")
                failure = Self.readable(error)
            }
            let result = failure
            Task { @MainActor in
                then(result)
            }
        }
    }

    /// 刪掉整個專案，連裡面的原片和燒好的影片。先改名再刪，刪到一半被滑掉下次會接著刪。
    func delete(_ id: UUID) async throws {
        try await run {
            try self.remove(id)
        }
    }

    /// 還沒有任何字幕的專案才刪（辨識被取消時用）。
    func discardIfEmpty(_ id: UUID) async {
        try? await run { () -> Void in
            let project = try self.read(id)
            guard project.lines.isEmpty, project.recognition == nil, project.burnedFile == nil else { return }
            // 有壞掉留底的 project.json，現在這份空的是救回來的，留底裡可能還有改過的字。
            let names = try self.manager.contentsOfDirectory(atPath: self.folder(id).path)
            guard !names.contains(where: { $0.hasPrefix(Self.badPrefix) }) else { return }
            try self.remove(id)
        }
    }

    private func remove(_ id: UUID) throws {
        guard manager.fileExists(atPath: folder(id).path) else { return }
        let trash = root.appendingPathComponent(Self.trashPrefix + UUID().uuidString, isDirectory: true)
        do {
            try manager.moveItem(at: folder(id), to: trash)
        } catch {
            try manager.removeItem(at: folder(id))
            return
        }
        try? manager.removeItem(at: trash)
    }

    private func write(_ data: Data, to target: URL) throws {
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            // 多半是硬碟滿了。放掉預留的空間再試一次，改到一半的字才存得下來。
            let reserve = root.appendingPathComponent(Self.reserveName)
            guard manager.fileExists(atPath: reserve.path) else { throw error }
            try? manager.removeItem(at: reserve)
            try data.write(to: target, options: .atomic)
            return
        }
        makeReserve()
    }

    private func makeReserve() {
        let reserve = root.appendingPathComponent(Self.reserveName)
        let attributes = try? manager.attributesOfItem(atPath: reserve.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size < Self.reserveSize else { return }
        try? Data(repeating: 0xA5, count: Self.reserveSize).write(to: reserve)
    }

    private func makeRoot() throws {
        if !manager.fileExists(atPath: root.path) {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        // 影片很大，不進 iCloud 備份。
        var target = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    // MARK: - 小工具

    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func encode(_ project: CaptionProject) throws -> Data {
        let encoder = JSONEncoder()
        // 時間萬一算出無限大，寧可照存也不要整份存不進去。
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try encoder.encode(project)
    }

    private static func decode(_ data: Data) -> CaptionProject? {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try? decoder.decode(CaptionProject.self, from: data)
    }

    private static func readable(_ error: Error) -> Error {
        if error is CaptionStoreError { return error }
        let code = (error as NSError)
        let full = code.domain == NSCocoaErrorDomain && code.code == NSFileWriteOutOfSpaceError
        let posixFull = code.domain == NSPOSIXErrorDomain && code.code == Int(ENOSPC)
        return full || posixFull ? CaptionStoreError.noSpace : error
    }
}
