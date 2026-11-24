import SwiftUI
import UIKit

/// 編輯某一篇腳本。從 ScriptListView 推進來，返回鈕就是系統的。
struct ScriptEditorView: View {
    let id: UUID
    var focusOnAppear = false

    @EnvironmentObject private var library: ScriptLibrary

    var body: some View {
        // 找不到這篇（被刪了）就留白，ScriptListView 會把這頁從 path 拿掉。
        if let item = library.item(id) {
            ScriptEditorContent(item: item, focusOnAppear: focusOnAppear)
                .id(id)
        } else {
            Color.clear
        }
    }
}

/// 編輯頁最後一次交給 library 的內容。放在參考型別裡，更新它不會讓畫面重算。
private final class ScriptEditorSync {
    var title: String
    var body: String

    init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

private struct ScriptEditorContent: View {
    private enum Field: Hashable {
        case title
        case body
    }

    let item: ScriptItem
    let focusOnAppear: Bool

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: ScriptLibrary
    @FocusState private var focus: Field?

    // 打字只動這兩個，再交給 library 延遲併進列表；
    // 直接綁列表，每個字都要重新發布整個陣列，注音組字會被打斷。
    @State private var title: String
    @State private var text: String
    @State private var sync: ScriptEditorSync
    @State private var confirmClear = false

    @ScaledMetric(relativeTo: .title2) private var baseSize: CGFloat = 22

    /// TextEditor 自己左右各縮 5pt，標題和預設文字要對齊它的字。
    private let editorPadding: CGFloat = 12
    private let textInset: CGFloat = 17

    init(item: ScriptItem, focusOnAppear: Bool) {
        self.item = item
        self.focusOnAppear = focusOnAppear
        _title = State(initialValue: item.title)
        _text = State(initialValue: item.body)
        _sync = State(initialValue: ScriptEditorSync(title: item.title, body: item.body))
    }

    private var fontSize: CGFloat {
        baseSize * CGFloat(settings.scriptTextScale)
    }

    // body 拆成幾層（版面、工具列、監聽），串太長編譯器會算不完。
    var body: some View {
        observed
            .task {
                guard focusOnAppear else { return }
                // 等推頁動畫跑完再叫鍵盤，太早設會被吃掉。
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !Task.isCancelled { focus = .body }
            }
            .onDisappear {
                library.flush()
            }
    }

    private var observed: some View {
        withToolbar
            .onChange(of: title) { _, new in
                // 標題欄按換行等於跳到內文。
                if new.contains(where: { $0.isNewline }) {
                    title = new.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
                    focus = .body
                } else {
                    stage()
                }
            }
            .onChange(of: text) { _, _ in
                stage()
            }
            .onChange(of: focus) { _, new in
                if new == nil { library.commitDrafts() }
            }
            .onChange(of: item.title) { _, new in
                guard new != sync.title, !library.hasDraft(item.id) else { return }
                sync.title = new
                title = new
            }
            .onChange(of: item.body) { _, new in
                // 只有別的地方改了這篇才同步進來；自己剛交出去的內容不能倒灌，不然會蓋掉新打的字。
                guard new != sync.body, !library.hasDraft(item.id) else { return }
                sync.body = new
                text = new
            }
    }

    private var withToolbar: some View {
        layout
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    toolbarButtons
                }
            }
            .confirmationDialog("清空內文？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    text = ""
                }
                Button("取消", role: .cancel) {}
            }
    }

    // 底部列直接排在內文下面，不用 safeAreaInset 疊：TextEditor 的框到它上緣為止，
    // 游標不可能被蓋住；鍵盤出來時整排一起被推到鍵盤上方。
    private var layout: some View {
        VStack(spacing: 0) {
            if let message = library.errorMessage {
                ScriptErrorBanner(message: message) {
                    library.errorMessage = nil
                }
            }
            titleField
            Divider()
                .padding(.horizontal, textInset)
            ScriptSegmentChips(
                text: text,
                speechRate: settings.speechRate,
                segmented: settings.segmentedRecording,
                inset: textInset
            )
            bodyEditor
            bottomBar
        }
    }

    private var titleField: some View {
        TextField("標題", text: $title, axis: .vertical)
            .font(.title3.weight(.bold))
            .lineLimit(1...3)
            .focused($focus, equals: .title)
            .padding(.horizontal, textInset)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
    }

    private var bodyEditor: some View {
        TextEditor(text: $text)
            .font(.system(size: fontSize))
            .lineSpacing(fontSize * 0.35)
            .focused($focus, equals: .body)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .padding(.horizontal, editorPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    placeholder
                }
            }
    }

    private var placeholder: some View {
        Text("把整篇稿子貼在這裡。\n段落之間空一行，就能一段一段錄，講錯只要重錄那一段。")
            .font(.system(size: fontSize))
            .lineSpacing(fontSize * 0.35)
            .foregroundStyle(.secondary)
            .padding(.horizontal, textInset)
            .padding(.top, 8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - 工具列

    @ViewBuilder
    private var toolbarButtons: some View {
        if focus != nil {
            Button {
                focus = nil
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
            }
            .accessibilityLabel("收起鍵盤")
        }
        ShareLink(item: shareText, subject: Text(ScriptItem.displayTitle(title: title, body: text))) {
            Label("分享", systemImage: "square.and.arrow.up")
        }
        .disabled(shareText.isEmpty)
        Menu {
            menuButtons
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private var menuButtons: some View {
        Button {
            if let pasted = UIPasteboard.general.string {
                text = pasted
            }
        } label: {
            Label("貼上並取代", systemImage: "doc.on.clipboard")
        }
        Button {
            changeScale(by: 0.1)
        } label: {
            Label("字放大", systemImage: "textformat.size.larger")
        }
        .disabled(!canGrow)
        Button {
            changeScale(by: -0.1)
        } label: {
            Label("字縮小", systemImage: "textformat.size.smaller")
        }
        .disabled(!canShrink)
        Divider()
        Button(role: .destructive) {
            confirmClear = true
        } label: {
            Label("清空", systemImage: "trash")
        }
        .disabled(text.isEmpty)
    }

    private var shareText: String {
        ScriptItem.shareText(title: title, body: text)
    }

    // MARK: - 底部列

    private var bottomBar: some View {
        HStack(spacing: 8) {
            ScriptStatsText(
                text: text,
                speechRate: settings.speechRate,
                segmented: settings.segmentedRecording
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                sizeButton("A−", label: "字縮小", enabled: canShrink, delta: -0.1)
                sizeButton("A＋", label: "字放大", enabled: canGrow, delta: 0.1)
            }
            useButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
        // 再大就擠不下三樣東西了；內文本身照樣跟著系統字級放大。
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func sizeButton(_ symbol: String, label: String, enabled: Bool, delta: Double) -> some View {
        Button {
            changeScale(by: delta)
        } label: {
            Text(symbol)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.3))
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var useButton: some View {
        if library.isActive(item.id) {
            Text("使用中")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.good)
                .modifier(UsePill(background: Theme.good.opacity(0.18)))
        } else {
            Button {
                library.setActive(item.id)
            } label: {
                Text("使用這篇")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .modifier(UsePill(background: Theme.accent))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 動作

    private var canGrow: Bool { settings.scriptTextScale < 1.8 - 0.01 }
    private var canShrink: Bool { settings.scriptTextScale > 0.8 + 0.01 }

    /// 先乘 10 取整再除回來，0.1 累加不會變成 1.2000000000000002。
    private func changeScale(by delta: Double) {
        let next: Double = ((settings.scriptTextScale + delta) * 10).rounded() / 10
        settings.scriptTextScale = min(max(next, 0.8), 1.8)
    }

    private func stage() {
        guard sync.title != title || sync.body != text else { return }
        sync.title = title
        sync.body = text
        library.stage(id: item.id, title: title, body: text)
        // 鍵盤已經收了（清空、貼上、收鍵盤時才定下來的注音）就不等了。
        if focus == nil { library.commitDrafts() }
    }
}

private struct UsePill: ViewModifier {
    let background: Color

    func body(content: Content) -> some View {
        content
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(background, in: Capsule())
            .contentShape(Capsule())
    }
}

/// 字數、預估時長、段數。只吃值，字沒變就不重算。
private struct ScriptStatsText: View {
    let text: String
    let speechRate: Double
    let segmented: Bool

    var body: some View {
        let count: Int = ScriptSegments.spokenCount(text)
        let countText: String = "\(count) 字"
        let detail: String = detailText(count: count)
        ViewThatFits(in: .horizontal) {
            Text(detail.isEmpty ? countText : countText + " · " + detail)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 2) {
                Text(countText)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private func detailText(count: Int) -> String {
        guard count > 0 else { return "" }
        let seconds = ScriptSegments.estimatedSeconds(text, charsPerMinute: speechRate)
        var detail = "約 \(ScriptSegments.formatDuration(seconds))"
        let segments = ScriptSegments.segments(of: text, segmented: segmented).count
        if segments > 1 {
            detail += " · \(segments) 段"
        }
        return detail
    }
}

/// 每一段各自要講多久，兩段以上才顯示。
private struct ScriptSegmentChips: View {
    let text: String
    let speechRate: Double
    let segmented: Bool
    let inset: CGFloat

    private var durations: [String] {
        let segments = ScriptSegments.segments(of: text, segmented: segmented)
        guard segments.count > 1 else { return [] }
        return segments.map { segment in
            ScriptSegments.formatDuration(
                ScriptSegments.estimatedSeconds(segment, charsPerMinute: speechRate))
        }
    }

    var body: some View {
        let chips: [String] = durations
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { index, duration in
                        Text("第 \(index + 1) 段 \(duration)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                .padding(.horizontal, inset)
            }
            .padding(.vertical, 6)
        }
    }
}
