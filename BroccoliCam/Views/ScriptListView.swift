import SwiftUI
import UniformTypeIdentifiers

/// 從列表推進編輯頁的路徑。
struct ScriptRoute: Hashable {
    let id: UUID
    /// 剛新增的那篇，進去就叫出鍵盤。
    var startsFocused = false
}

/// 腳本列表：新增、匯入、複製、排序、刪除、選使用哪一篇。當 sheet 的內容，自帶 NavigationStack。
struct ScriptListView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: ScriptLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var path: [ScriptRoute] = []
    @State private var editMode: EditMode = .inactive
    @State private var showImporter = false
    @State private var importError: String?
    @State private var pendingDelete: ScriptItem?

    // body 拆成幾層（列表、工具列、彈出視窗），串太長編譯器會算不完。
    var body: some View {
        NavigationStack(path: $path) {
            presented
                .navigationDestination(for: ScriptRoute.self) { route in
                    ScriptEditorView(id: route.id, focusOnAppear: route.startsFocused)
                }
        }
        // 正在編輯的那篇不見了就退回列表。由列表改 path，不讓編輯頁自己 dismiss，免得把整張 sheet 關掉。
        .onChange(of: library.items.map(\.id)) { _, ids in
            path.removeAll { !ids.contains($0.id) }
            if ids.count < 2 { editMode = .inactive }
        }
        .onDisappear {
            library.flush()
        }
    }

    private var presented: some View {
        listWithToolbar
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: importTypes,
                allowsMultipleSelection: true,
                onCompletion: { result in handleImport(result) }
            )
            .alert("匯入失敗", isPresented: importErrorShown) {
                Button("好") {}
            } message: {
                Text(importError ?? "")
            }
            // 不用 confirmationDialog：新系統不畫「取消」，刪了不能還原，取消要看得到。
            .alert(deleteTitle, isPresented: deleteShown, presenting: pendingDelete) { item in
                Button("刪除", role: .destructive) {
                    withAnimation { library.delete(item.id) }
                }
                Button("取消", role: .cancel) {}
            }
    }

    private var listWithToolbar: some View {
        list
            .navigationTitle("腳本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") {
                        library.flush()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("腳本")
                            .font(.headline)
                        Text("\(library.items.count) 篇")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    trailingButtons
                }
            }
    }

    @ViewBuilder
    private var trailingButtons: some View {
        // 長按就能拖；這顆給找不到長按、或用旁白的人，按了每列出現把手。
        if library.items.count > 1 {
            Button {
                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
            } label: {
                Image(systemName: editMode.isEditing ? "checkmark" : "arrow.up.arrow.down")
            }
            .accessibilityLabel(editMode.isEditing ? "排好了" : "調整順序")
        }
        Button {
            showImporter = true
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .accessibilityLabel("匯入")
        Button(action: addScript) {
            Image(systemName: "plus")
        }
        .accessibilityLabel("新增腳本")
    }

    // 列表一直在，空的時候蓋一層；用 if 換掉整個 List，新增後推頁會跟換畫面打架。
    private var list: some View {
        List {
            ForEach(library.items) { item in
                row(item)
            }
            .onMove { source, destination in
                library.move(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .overlay {
            if library.items.isEmpty {
                emptyState
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = library.errorMessage {
                ScriptErrorBanner(message: message) {
                    library.errorMessage = nil
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("還沒有腳本", systemImage: "doc.text")
        } actions: {
            Button(action: addScript) {
                Text("新增腳本")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func row(_ item: ScriptItem) -> some View {
        let active: Bool = library.isActive(item.id)
        return NavigationLink(value: ScriptRoute(id: item.id)) {
            ScriptRow(item: item, isActive: active, speechRate: settings.speechRate,
                      showsDuration: settings.promptAmount != PromptAmount.outline)
        }
        .listRowBackground(active ? Theme.accent.opacity(0.16) : Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            swipeButtons(item, active: active)
        }
        .contextMenu {
            menuButtons(item, active: active)
        }
    }

    // 刪除不用 role: .destructive：系統會先把那列收掉，按取消又跳回來。
    @ViewBuilder
    private func swipeButtons(_ item: ScriptItem, active: Bool) -> some View {
        Button {
            pendingDelete = item
        } label: {
            Label("刪除", systemImage: "trash")
        }
        .tint(Theme.record)
        Button {
            duplicate(item)
        } label: {
            Label("複製", systemImage: "doc.on.doc")
        }
        .tint(.gray)
        if !active {
            Button {
                use(item)
            } label: {
                Label("使用", systemImage: "checkmark.circle")
            }
            .tint(Theme.good)
        }
    }

    @ViewBuilder
    private func menuButtons(_ item: ScriptItem, active: Bool) -> some View {
        if !active {
            Button {
                use(item)
            } label: {
                Label("使用這篇", systemImage: "checkmark.circle")
            }
        }
        Button {
            duplicate(item)
        } label: {
            Label("複製一份", systemImage: "doc.on.doc")
        }
        ShareLink(item: item.shareText, subject: Text(item.displayTitle)) {
            Label("分享", systemImage: "square.and.arrow.up")
        }
        .disabled(item.shareText.isEmpty)
        Divider()
        Button(role: .destructive) {
            pendingDelete = item
        } label: {
            Label("刪除", systemImage: "trash")
        }
    }

    // MARK: - 動作

    private func addScript() {
        editMode = .inactive
        let id = library.add()
        path = [ScriptRoute(id: id, startsFocused: true)]
    }

    private func duplicate(_ item: ScriptItem) {
        withAnimation { _ = library.duplicate(item.id) }
    }

    private func use(_ item: ScriptItem) {
        withAnimation { library.setActive(item.id) }
    }

    // MARK: - 匯入

    private var importTypes: [UTType] {
        var types: [UTType] = [.plainText]
        if let markdown = UTType(filenameExtension: "md") {
            types.append(markdown)
        }
        return types
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            library.importFiles(urls) { failed in
                guard !failed.isEmpty else { return }
                importError = "讀不出文字：" + failed.joined(separator: "、")
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private var importErrorShown: Binding<Bool> {
        Binding(
            get: { importError != nil },
            set: { shown in
                if !shown { importError = nil }
            }
        )
    }

    // MARK: - 刪除確認

    private var deleteTitle: String {
        guard let item = pendingDelete else { return "刪除這篇？" }
        return "刪除「\(item.displayTitle.prefix(20))」？"
    }

    private var deleteShown: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { shown in
                if !shown { pendingDelete = nil }
            }
        )
    }
}

/// 列表的一列。只吃值，內容沒變就不重算字數。
private struct ScriptRow: View {
    let item: ScriptItem
    let isActive: Bool
    let speechRate: Double
    /// 提綱是用自己的話講，照字數估的時長不準。
    let showsDuration: Bool

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !item.preview.isEmpty {
                Text(item.preview)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(meta)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// 字級調到輔助使用大小時，標籤改放標題下面，不跟標題搶寬度。
    private var header: some View {
        let layout: AnyLayout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            Text(item.displayTitle)
                .font(.title3.weight(.bold))
                .lineLimit(2)
            if isActive {
                Text("使用中")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Theme.accent, in: Capsule())
                    .fixedSize()
            }
        }
    }

    private var meta: String {
        let count = ScriptSegments.spokenCount(item.body)
        guard showsDuration else { return "\(count) 字 · \(ScriptRelativeTime.text(item.updatedAt))" }
        let seconds = ScriptSegments.estimatedSeconds(item.body, charsPerMinute: speechRate)
        let duration = ScriptSegments.formatDuration(seconds)
        return "\(count) 字 · 約 \(duration) · \(ScriptRelativeTime.text(item.updatedAt))"
    }
}

/// 「剛剛」「5 分鐘前」「昨天」。固定繁中，不跟手機語言跑。
private enum ScriptRelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter
    }()

    static func text(_ date: Date) -> String {
        let now = Date()
        // 不到一分鐘、或手機時間被往回調過。
        guard now.timeIntervalSince(date) >= 60 else { return "剛剛" }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// 存檔出錯的提示，列表和編輯頁共用。
struct ScriptErrorBanner: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("關閉")
        }
        .foregroundStyle(.white)
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(Theme.record, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
