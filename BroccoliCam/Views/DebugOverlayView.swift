import SwiftUI
import UIKit

/// App 內除錯資訊層：把真機上的格式、FPS、音訊路由與錯誤帶回來。
/// 開發環境沒有 Mac，這是回報問題的主要依據。
struct DebugOverlayView: View {
    @EnvironmentObject private var camera: CameraService
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var probe = CaptionProbeLog()
    @State private var copied = false

    var body: some View {
        overlay
            .onAppear {
                probe.run()
            }
    }

    /// 畫面上看到的和「複製」帶走的是同一份。
    private func report() -> String {
        guard !probe.lines.isEmpty else { return camera.debugSnapshot() }
        let captions = (["— 字幕辨識 —"] + probe.lines).joined(separator: "\n")
        return camera.debugSnapshot() + "\n" + captions
    }

    private var overlay: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let text = report()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("除錯資訊")
                        .font(.caption.weight(.bold))
                    Spacer()
                    Button(copied ? "已複製" : "複製") {
                        UIPasteboard.general.string = report()
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

/// 字幕辨識引擎的檢測結果。一次開 App 只測一次，不和紀錄擠在一起（紀錄只留最近幾行）。
@MainActor
final class CaptionProbeLog: ObservableObject {
    @Published private(set) var lines: [String] = []
    private static var kept: [String] = []
    private static var started = false

    func run() {
        lines = Self.kept
        guard !Self.started else { return }
        Self.started = true
        // 除錯層關掉也讓它測完，下次打開就有。
        CaptionBridge.probe { [weak self] line in
            Task { @MainActor [weak self] in
                Self.kept.append(line)
                self?.lines = Self.kept
            }
        }
    }
}
