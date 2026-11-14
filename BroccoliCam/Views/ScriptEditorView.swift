import SwiftUI
import UIKit

/// 文件式文字稿編輯：整篇貼上、可修改、可清空。自動保存最後一次使用的稿件。
struct ScriptEditorView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $settings.script)
                    .font(.system(size: 19))
                    .lineSpacing(7)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)

                if settings.script.isEmpty {
                    Text("把整篇稿子貼在這裡。\n不需要分段切卡，錄影時會在鏡頭旁邊自動往上捲。")
                        .font(.system(size: 19))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 17)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle("稿件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("清空", role: .destructive) {
                        confirmClear = true
                    }
                    .disabled(settings.script.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        if let text = UIPasteboard.general.string {
                            settings.script = text
                        }
                    } label: {
                        Label("貼上並取代", systemImage: "doc.on.clipboard")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Text("\(settings.script.count) 字")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .confirmationDialog("清空整篇稿件？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    settings.script = ""
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
}
