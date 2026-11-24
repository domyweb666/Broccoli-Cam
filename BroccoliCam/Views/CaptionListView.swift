import SwiftUI
import AVFoundation

/// 字幕專案列表。從設定進來，點一個回校對頁。
struct CaptionListView: View {
    /// 校對頁打開／關掉。打開時主畫面不可以把相機叫起來。
    var onEditing: (Bool) -> Void = { _ in }

    /// nil 是還在讀。
    @State private var entries: [CaptionEntry]?
    @State private var editing: CaptionTicket?
    @State private var pendingDelete: CaptionEntry?
    @State private var problem: String?

    // 彈出視窗分兩層掛，串太長編譯器會算不完。
    var body: some View {
        dialogs
            .fullScreenCover(item: $editing, onDismiss: {
                onEditing(false)
                reload()
            }) { ticket in
                CaptionEditorView(projectID: ticket.id)
            }
    }

    private var dialogs: some View {
        list
            .navigationTitle("字幕專案")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: reload)
            .confirmationDialog(
                "刪掉這個字幕專案？",
                isPresented: deleteShown,
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { entry in
                Button("刪掉", role: .destructive) { delete(entry) }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text("這裡的原片和燒好的影片會一起刪掉，不能還原。存在照片裡的不受影響。")
            }
            .alert("沒有成功", isPresented: problemShown) {
                Button("好") {}
            } message: {
                Text(problem ?? "")
            }
    }

    private var list: some View {
        List {
            ForEach(entries ?? []) { entry in
                row(entry)
            }
        }
        .listStyle(.plain)
        .overlay {
            if let entries {
                if entries.isEmpty {
                    ContentUnavailableView("還沒有字幕專案", systemImage: "captions.bubble")
                }
            } else {
                ProgressView()
            }
        }
    }

    private func row(_ entry: CaptionEntry) -> some View {
        Button {
            open(entry)
        } label: {
            CaptionEntryRow(entry: entry)
        }
        .buttonStyle(.plain)
        // 刪除不用 role: .destructive：系統會先把那列收掉，按取消又跳回來。
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                pendingDelete = entry
            } label: {
                Label("刪除", systemImage: "trash")
            }
            .tint(Theme.record)
        }
        .contextMenu {
            Button {
                pendingDelete = entry
            } label: {
                Label("刪除", systemImage: "trash")
            }
        }
    }

    private func open(_ entry: CaptionEntry) {
        if entry.isMissingVideo {
            problem = CaptionStoreError.videoMissing.localizedDescription
            return
        }
        guard entry.project != nil else {
            problem = "這個專案這次讀不到，等一下再試。"
            reload()
            return
        }
        onEditing(true)
        editing = CaptionTicket(id: entry.id)
    }

    private func reload() {
        Task { @MainActor in
            do {
                entries = try await CaptionStore.shared.list()
            } catch {
                entries = entries ?? []
                problem = error.localizedDescription
            }
        }
    }

    private func delete(_ entry: CaptionEntry) {
        Task { @MainActor in
            do {
                try await CaptionStore.shared.delete(entry.id)
            } catch {
                problem = error.localizedDescription
            }
            reload()
        }
    }

    private var deleteShown: Binding<Bool> {
        Binding<Bool>(
            get: { pendingDelete != nil },
            set: { shown in
                if !shown { pendingDelete = nil }
            }
        )
    }

    private var problemShown: Binding<Bool> {
        Binding<Bool>(
            get: { problem != nil },
            set: { shown in
                if !shown { problem = nil }
            }
        )
    }
}

/// 一列：縮圖、日期、狀態、占用空間。
private struct CaptionEntryRow: View {
    let entry: CaptionEntry

    var body: some View {
        HStack(spacing: 14) {
            CaptionThumb(entry: entry)
            VStack(alignment: .leading, spacing: 4) {
                Text(dateText)
                    .font(.headline)
                Text(stateText)
                    .font(.subheadline)
                    .foregroundStyle(stateColor)
                Text(sizeText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var dateText: String {
        guard let project = entry.project else { return "—" }
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened,
                                     locale: Locale(identifier: "zh_Hant_TW"))
        return project.createdAt.formatted(style)
    }

    private var stateText: String {
        if entry.isMissingVideo { return "影片不見了" }
        guard let project = entry.project else { return "這次讀不到" }
        if project.lines.isEmpty && project.recognition == nil { return "還沒對字幕" }
        if project.pendingCount > 0 { return "還有 \(project.pendingCount) 句" }
        if project.burnedFile == nil { return "還沒燒" }
        return project.isBurnStale ? "要重燒" : "已燒"
    }

    private var stateColor: Color {
        guard let project = entry.project, !entry.isMissingVideo else { return .yellow }
        if project.pendingCount > 0 || project.isBurnStale { return .yellow }
        return project.burnedFile == nil ? .secondary : Theme.good
    }

    private var sizeText: String {
        let size = ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)
        guard let project = entry.project, project.duration > 0 else { return "約 \(size)" }
        let length = ScriptSegments.formatDuration(project.duration)
        return "\(length) · 約 \(size)"
    }
}

private struct CaptionThumb: View {
    let entry: CaptionEntry
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.1)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(width: 54, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
        .task(id: entry.project?.clips.first?.file) {
            image = await load()
        }
    }

    private func load() async -> UIImage? {
        guard let clip = entry.project?.clips.first else { return nil }
        let asset = AVURLAsset(url: CaptionStore.shared.url(clip.file, in: entry.id))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let time = CMTime(seconds: (clip.start ?? 0) + 0.5, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: result.image)
    }
}
