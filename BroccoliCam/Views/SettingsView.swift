import SwiftUI

/// 簡單設定。只列出此裝置實際支援的畫質與幀率。不放說明文字，選項要大、好按（QC-0005）。
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var camera: CameraService
    @Environment(\.dismiss) private var dismiss
    @State private var speechDenied = false

    private var fpsOptions: [Int] {
        camera.availableFPS[settings.resolution] ?? [30]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ModePicker()
                        .padding(.vertical, 8)
                } header: {
                    Text("模式")
                }

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
                    Toggle("停頓時提詞等我", isOn: $settings.waitOnPause)
                    LabeledSlider(title: "語速（估算時長用）", value: $settings.speechRate, range: 150...320, step: 10,
                                  display: "\(Int(settings.speechRate)) 字／分")
                } header: {
                    Text("提詞")
                }

                Section {
                    Toggle("提詞跟著我的聲音走", isOn: $settings.voiceFollow)
                } header: {
                    Text("語音跟隨（試用）")
                }

                Section {
                    LabeledSlider(title: "每行最多字數", value: $settings.subtitleMaxChars, range: 8...20, step: 1,
                                  display: "\(Int(settings.subtitleMaxChars)) 字")
                } header: {
                    Text("字幕")
                }

                Section {
                    Toggle("顯示頭像框", isOn: $settings.showGuide)
                    if settings.showGuide {
                        LabeledSlider(title: "頭像框大小", value: $settings.guideScale, range: 0.7...1.4, step: 0.05,
                                      display: "\(Int(settings.guideScale * 100))%")
                    }
                } header: {
                    Text("構圖")
                }

                Section {
                    Picker("倒數", selection: $settings.countdown) {
                        Text("不倒數").tag(0)
                        Text("3 秒").tag(3)
                        Text("5 秒").tag(5)
                        Text("10 秒").tag(10)
                    }
                    Toggle("接片時裁掉每段頭尾的空白", isOn: $settings.trimSilence)
                    Toggle("手機橫放時錄橫式影片", isOn: $settings.autoLandscape)
                } header: {
                    Text("錄影")
                }

                Section {
                    Toggle("顯示除錯資訊", isOn: $settings.showDebug)
                } header: {
                    Text("進階")
                }
            }
            .font(.system(size: 20))
            .environment(\.defaultMinListRowHeight, 60)
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: settings.voiceFollow) { _, on in
                guard on, !SpeechFollower.isAuthorized else { return }
                SpeechFollower.requestAuthorization { granted in
                    if !granted {
                        settings.voiceFollow = false
                        speechDenied = true
                    }
                }
            }
            .alert("沒有語音辨識的權限", isPresented: $speechDenied) {
                Button("好") {}
            } message: {
                Text("請到「設定 → 花椰菜相機」打開「語音辨識」，再回來打開這個開關。")
            }
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
