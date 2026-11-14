import SwiftUI

/// 簡單設定。只列出此裝置實際支援的畫質與幀率。
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var camera: CameraService
    @Environment(\.dismiss) private var dismiss

    private var fpsOptions: [Int] {
        camera.availableFPS[settings.resolution] ?? [30]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("影片") {
                    Picker("畫質", selection: $settings.resolution) {
                        ForEach(camera.availableResolutions) { resolution in
                            Text(resolution.label).tag(resolution)
                        }
                    }
                    Picker("幀率", selection: $settings.fps) {
                        ForEach(fpsOptions, id: \.self) { fps in
                            Text("\(fps) FPS").tag(fps)
                        }
                    }
                    Toggle("影片左右鏡像", isOn: $settings.mirrorOutput)
                }

                Section {
                    LabeledSlider(title: "文字大小", value: $settings.fontSize, range: 16...48, step: 1,
                                  display: "\(Int(settings.fontSize))")
                    LabeledSlider(title: "速度", value: $settings.speed, range: 8...120, step: 2,
                                  display: "\(Int(settings.speed))")
                    LabeledSlider(title: "底色深淺", value: $settings.promptBackground, range: 0...0.9, step: 0.05,
                                  display: "\(Int(settings.promptBackground * 100))%")
                    Toggle("開始錄影時自動開始提詞", isOn: $settings.autoStartPrompter)
                } header: {
                    Text("提詞")
                } footer: {
                    Text("提詞文字只顯示在預覽上，不會錄進影片。")
                }

                Section {
                    Toggle("顯示頭像框", isOn: $settings.showGuide)
                    if settings.showGuide {
                        LabeledSlider(title: "頭像框大小", value: $settings.guideScale, range: 0.7...1.4, step: 0.05,
                                      display: "\(Int(settings.guideScale * 100))%")
                    }
                } header: {
                    Text("構圖")
                } footer: {
                    Text("頭像框不會錄進影片。臉的位置只在這支手機上比對，不會上傳。")
                }

                Section("錄影") {
                    Picker("倒數", selection: $settings.countdown) {
                        Text("不倒數").tag(0)
                        Text("3 秒").tag(3)
                        Text("5 秒").tag(5)
                        Text("10 秒").tag(10)
                    }
                }

                Section {
                    Toggle("顯示除錯資訊", isOn: $settings.showDebug)
                } header: {
                    Text("進階")
                } footer: {
                    Text("回報問題時打開，把內容複製給開發者。也可以長按主畫面的麥克風圖示切換。")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(display)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}
