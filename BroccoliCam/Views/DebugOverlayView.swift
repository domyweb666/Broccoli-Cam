import SwiftUI
import UIKit

/// App 內除錯資訊層：把真機上的格式、FPS、音訊路由與錯誤帶回來。
/// 開發環境沒有 Mac，這是回報問題的主要依據。
struct DebugOverlayView: View {
    @EnvironmentObject private var camera: CameraService
    @EnvironmentObject private var settings: SettingsStore
    @State private var copied = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let text = camera.debugSnapshot()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("除錯資訊")
                        .font(.caption.weight(.bold))
                    Spacer()
                    Button(copied ? "已複製" : "複製") {
                        UIPasteboard.general.string = camera.debugSnapshot()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copied = false
                        }
                    }
                    .font(.caption.weight(.semibold))
                    Button("關閉") {
                        settings.showDebug = false
                    }
                    .font(.caption.weight(.semibold))
                }
                ScrollView {
                    Text(text)
                        .font(.system(size: 10.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .foregroundStyle(.white)
            .padding(10)
            .frame(maxWidth: .infinity)
            .frame(height: 250)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 10)
        }
    }
}
