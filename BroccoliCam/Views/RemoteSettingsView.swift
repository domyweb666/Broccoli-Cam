import SwiftUI

/// 藍牙控制：測試踏板送什麼鍵、逐段或逐行、每個動作對應哪些鍵。
struct RemoteSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var lastKey: RemoteKey?
    /// 正在等使用者按一個鍵來指定給這個動作。
    @State private var waiting: RemoteAction?
    @State private var confirmReset = false

    var body: some View {
        Form {
            testSection
            jumpSection
            keysSection
            resetSection
        }
        .font(.title3)
        .environment(\.defaultMinListRowHeight, 60)
        .navigationTitle("藍牙控制")
        .navigationBarTitleDisplayMode(.inline)
        .background(alignment: .topLeading) {
            RemoteKeyCatcher(isActive: !confirmReset) { key in
                received(key)
            }
        }
        .onDisappear {
            waiting = nil
        }
        .confirmationDialog("還原成預設的按鍵？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("還原預設", role: .destructive) {
                settings.remoteBindings = .standard
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func received(_ key: RemoteKey) {
        lastKey = key
        guard let action = waiting else { return }
        settings.remoteBindings.assign(key, to: action)
        waiting = nil
    }

    // MARK: - 區塊

    private var testSection: some View {
        Section("按鍵測試") {
            HStack(spacing: 12) {
                Text(lastKey?.label ?? "—")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(testResult)
                    .foregroundStyle(testAction == nil ? Color.secondary : Theme.accent)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }

    private var testAction: RemoteAction? {
        guard let lastKey else { return nil }
        return settings.remoteBindings.action(for: lastKey)
    }

    private var testResult: String {
        guard lastKey != nil else { return "" }
        return testAction?.label ?? "沒有對應"
    }

    private var jumpSection: some View {
        Section("跳轉") {
            Picker("跳轉", selection: $settings.jumpMode) {
                ForEach(JumpMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private var keysSection: some View {
        Section("按鍵") {
            ForEach(RemoteAction.allCases) { action in
                RemoteActionRow(
                    action: action,
                    keys: settings.remoteBindings.keys(for: action),
                    isWaiting: waiting == action,
                    onTap: { waiting = waiting == action ? nil : action },
                    onRemove: { key in settings.remoteBindings.remove(key) }
                )
            }
        }
    }

    private var resetSection: some View {
        Section {
            Button("還原預設", role: .destructive) {
                waiting = nil
                confirmReset = true
            }
            .disabled(settings.remoteBindings == .standard)
        }
    }
}

/// 一個動作：上面一行點了等按鍵，下面是目前對應的鍵，點叉叉移除。
private struct RemoteActionRow: View {
    let action: RemoteAction
    let keys: [RemoteKey]
    let isWaiting: Bool
    let onTap: () -> Void
    let onRemove: (RemoteKey) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !keys.isEmpty {
                keyList
            }
        }
        .padding(.vertical, 4)
    }

    private var header: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Text(action.label)
                    .foregroundStyle(Color.primary)
                Spacer()
                if isWaiting {
                    Text("請按一下踏板")
                        .foregroundStyle(Theme.accent)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isWaiting ? "\(action.label)，取消指定按鍵" : "\(action.label)，指定按鍵")
    }

    private var keyList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(keys, id: \.self) { key in
                    keyButton(key)
                }
            }
        }
    }

    private func keyButton(_ key: RemoteKey) -> some View {
        Button {
            onRemove(key)
        } label: {
            HStack(spacing: 8) {
                Text(key.label)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.primary)
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Color.white.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("移除 \(key.label)")
    }
}
