import SwiftUI

/// 一篇腳本。標題可以空著，列表就拿內文第一行當標題。
struct ScriptItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String = ""
    var body: String = ""
    var createdAt: Date = Date()
    /// 標題或內文真的變了才更新，換順序、設為使用中都不算。
    var updatedAt: Date = Date()

    var displayTitle: String {
        ScriptItem.displayTitle(title: title, body: body)
    }

    /// 列表上的兩行預覽。第一行已經拿去當標題時，從下一行開始。
    var preview: String {
        var lines = ScriptItem.contentLines(body)
        if let first = lines.first, first == displayTitle {
            lines.removeFirst()
        }
        return lines.prefix(2).joined(separator: "\n")
    }

    /// 分享出去的內容：內文；內文空著就給標題。
    var shareText: String {
        ScriptItem.shareText(title: title, body: body)
    }

    static func displayTitle(title: String, body: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return contentLines(body).first ?? "未命名"
    }

    static func shareText(title: String, body: String) -> String {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title : body
    }

    /// 有字的那幾行，去掉前後空白。
    private static func contentLines(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// 腳本列表，存在 Application Support/scripts.json。
/// 使用中那篇的內文同步到 settings.script，錄影流程只認 settings.script。
/// 只在主執行緒使用。
final class ScriptLibrary: ObservableObject {
    @Published private(set) var items: [ScriptItem] = []
    /// 有腳本的時候一定指到其中一篇；空列表是 nil。
    @Published private(set) var activeID: UUID?
    /// 讀檔或寫檔失敗時的訊息。內容還在記憶體裡。
    @Published var errorMessage: String?

    private struct StoredFile: Codable {
        var version: Int = 1
        var activeID: UUID?
        var items: [ScriptItem]
    }

    private struct Draft {
        var title: String
        var body: String
    }

    private let settings: SettingsStore
    private let fileURL: URL

    /// 編輯頁正在打的字。先放這裡，不發布，停手一下才併進 items：
    /// 每個字都重新發布整個陣列，長稿會卡，注音組字也可能被打斷。
    private var drafts: [UUID: Draft] = [:]
    private var draftWork: DispatchWorkItem?
    private let draftDelay: TimeInterval = 0.3

    private var saveWork: DispatchWorkItem?
    private let saveDelay: TimeInterval = 0.8
    private var dirty = false
    private var saveFailed = false
    /// 壞檔留不了底的時候不准寫，免得把原檔蓋掉。
    private var writingBlocked = false

    init(settings: SettingsStore) {
        self.settings = settings
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = support.appendingPathComponent("scripts.json")
        load()
    }

    // MARK: - 查詢

    func item(_ id: UUID) -> ScriptItem? {
        items.first { $0.id == id }
    }

    func isActive(_ id: UUID) -> Bool {
        activeID == id
    }

    /// 這篇還有沒併進 items 的字。
    func hasDraft(_ id: UUID) -> Bool {
        drafts[id] != nil
    }

    // MARK: - 編輯

    /// 編輯頁打字時呼叫：先記著，停手 0.3 秒才併進列表。
    func stage(id: UUID, title: String, body: String) {
        drafts[id] = Draft(title: title, body: body)
        draftWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.commitDrafts()
        }
        draftWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + draftDelay, execute: work)
    }

    /// 把打到一半的字併進列表（還不一定寫檔）。
    func commitDrafts() {
        draftWork?.cancel()
        draftWork = nil
        guard !drafts.isEmpty else { return }
        let pending = drafts
        drafts = [:]
        var changed = false
        for (id, draft) in pending {
            if apply(draft, to: id) { changed = true }
        }
        if changed { scheduleSave() }
    }

    /// 立刻併進列表並寫檔。離開頁面、進背景時呼叫。
    func flush() {
        commitDrafts()
        if dirty { save() }
    }

    // MARK: - 列表操作

    /// 新的一篇放最上面。列表原本是空的就直接設為使用中。
    @discardableResult
    func add(title: String = "", body: String = "") -> UUID {
        commitDrafts()
        let item = ScriptItem(title: title, body: body)
        items.insert(item, at: 0)
        finishStructuralChange()
        return item.id
    }

    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        commitDrafts()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let source = items[index]
        let copy = ScriptItem(title: "\(source.displayTitle.prefix(30)) 複本", body: source.body)
        items.insert(copy, at: index + 1)
        finishStructuralChange()
        return copy.id
    }

    /// 刪掉使用中那篇，就換成列表第一篇。
    func delete(_ id: UUID) {
        drafts[id] = nil
        commitDrafts()
        items.removeAll { $0.id == id }
        finishStructuralChange()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        commitDrafts()
        items.move(fromOffsets: source, toOffset: destination)
        finishStructuralChange()
    }

    func setActive(_ id: UUID) {
        commitDrafts()
        guard activeID != id, items.contains(where: { $0.id == id }) else { return }
        activeID = id
        finishStructuralChange()
    }

    /// 匯入文字檔，檔名當標題。iCloud 的檔案可能要先下載，所以在背景讀。
    /// 完成後在主執行緒回傳讀不出來的檔名。
    func importFiles(_ urls: [URL], completion: @escaping (_ failed: [String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var loaded: [ScriptItem] = []
            var failed: [String] = []
            for url in urls {
                if let text = ScriptTextFile.read(url) {
                    let title = url.deletingPathExtension().lastPathComponent
                    loaded.append(ScriptItem(title: title, body: text))
                } else {
                    failed.append(url.lastPathComponent)
                }
            }
            let newItems = loaded
            let failedNames = failed
            DispatchQueue.main.async {
                if !newItems.isEmpty {
                    self.commitDrafts()
                    self.items.insert(contentsOf: newItems, at: 0)
                    self.finishStructuralChange()
                }
                completion(failedNames)
            }
        }
    }

    // MARK: - 內部

    private func apply(_ draft: Draft, to id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        var item = items[index]
        guard item.title != draft.title || item.body != draft.body else { return false }
        item.title = draft.title
        item.body = draft.body
        item.updatedAt = Date()
        items[index] = item
        if id == activeID { syncScript() }
        return true
    }

    /// 增刪、排序、換使用中之後：補好 activeID、同步內文、馬上寫檔。
    private func finishStructuralChange() {
        repairActive()
        syncScript()
        save()
    }

    private func repairActive() {
        if let id = activeID, items.contains(where: { $0.id == id }) { return }
        let next = items.first?.id
        if activeID != next { activeID = next }
    }

    /// 使用中那篇的內文寫回 settings.script。內容沒變就不寫，免得主畫面白白重畫。
    private func syncScript() {
        let body = activeID.flatMap { item($0)?.body } ?? ""
        if settings.script != body {
            settings.script = body
        }
    }

    // MARK: - 讀寫檔

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            migrate()
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let stored = try JSONDecoder().decode(StoredFile.self, from: data)
            items = stored.items
            activeID = stored.activeID
            repairActive()
            // 兩邊不一樣時以檔案為準。
            syncScript()
        } catch {
            quarantineBrokenFile()
            migrate()
        }
    }

    /// 還沒有列表檔：舊版唯一那篇稿子變成第一篇。寫了檔之後就不會再走到這裡。
    /// 沒有稿子就先不寫檔：系統可能在設定還讀不到的時候就先把 App 叫起來，
    /// 那時寫了空列表，下次就不會再搬，舊稿子會被空列表蓋掉。
    private func migrate() {
        guard settings.hasScript else { return }
        items = [ScriptItem(body: settings.script)]
        finishStructuralChange()
    }

    /// 壞檔改名留底，不直接蓋掉。
    private func quarantineBrokenFile() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "scripts-bad-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4)).json"
        let backup = fileURL.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: fileURL, to: backup)
            errorMessage = "腳本檔打不開，原檔已留底。"
        } catch {
            writingBlocked = true
            errorMessage = "腳本檔打不開，這次的修改不會存檔。"
        }
    }

    private func scheduleSave() {
        dirty = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.save()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    /// 寫失敗時 dirty 留著，下次改動或進背景會再試一次。
    private func save() {
        saveWork?.cancel()
        saveWork = nil
        dirty = true
        guard !writingBlocked else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(StoredFile(activeID: activeID, items: items))
            try data.write(to: fileURL, options: .atomic)
            dirty = false
            if saveFailed {
                saveFailed = false
                errorMessage = nil
            }
        } catch {
            saveFailed = true
            errorMessage = "腳本沒存成功：\(error.localizedDescription)"
        }
    }
}

/// 讀匯入的文字檔：先試 UTF-8，再試 Big5、UTF-16。
enum ScriptTextFile {
    /// 讀不到、解不開、沒有字都回 nil。
    static func read(_ url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        var contents: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            contents = try? Data(contentsOf: readable)
        }
        guard let data = contents, let decoded = decode(data) else { return nil }
        let text = decoded
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func decode(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(2))
        if head == [0xFF, 0xFE] || head == [0xFE, 0xFF] {
            return String(data: data, encoding: .utf16)
        }
        // 純文字不會有 NUL，有的話是沒帶 BOM 的 UTF-16，拿去當 UTF-8 會解出一堆空字元。
        if data.contains(0) {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        for encoding in big5Encodings {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return String(data: data, encoding: .utf16LittleEndian)
    }

    /// Windows 存的 Big5 多半是 CP950，先試它。
    private static var big5Encodings: [String.Encoding] {
        let candidates: [CFStringEncodings] = [.dosChineseTrad, .big5, .big5_HKSCS_1999]
        return candidates.map { candidate in
            let cfEncoding = CFStringEncoding(candidate.rawValue)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        }
    }
}
