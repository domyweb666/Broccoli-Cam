import SwiftUI

/// 簡單設定。只列出此裝置實際支援的畫質與幀率。
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
                    Picker("模式", selection: $settings.companionMode) {
                        Text("提詞").tag(false)
                        Text("陪伴").tag(true)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("模式")
                } footer: {
                    Text("提詞：照著稿子唸。陪伴：不看稿，鏡頭旁邊有一位聆聽者，你講話時它會點頭，適合知道要說什麼、但對著鏡頭會緊張的時候。聆聽者不會錄進影片。")
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
                } footer: {
                    Text("提詞文字只顯示在預覽上，不會錄進影片。錄影中停下來不講話，提詞會暫停，開口再繼續。")
                }

                Section {
                    Toggle("提詞跟著我的聲音走", isOn: $settings.voiceFollow)
                } header: {
                    Text("語音跟隨（試用）")
                } footer: {
                    Text("打開後，錄影時你唸到哪，提詞就捲到哪，停下來它也停。需要語音辨識的權限。聽不清楚的時候會自動改回固定速度。這個功能還在試，錄出來的聲音有問題就先關掉。")
                }

                Section {
                    LabeledSlider(title: "每行最多字數", value: $settings.subtitleMaxChars, range: 8...20, step: 1,
                                  display: "\(Int(settings.subtitleMaxChars)) 字")
                } header: {
                    Text("字幕")
                } footer: {
                    Text("錄完在完成頁按「產生字幕檔」，會用你的稿子對影片的聲音，做出 SRT 檔，可以匯入剪映、CapCut、Premiere。直式短影音建議 12 到 14 字。")
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
                } footer: {
                    Text("稿件用空行分段後，可以一段一段錄，最後自動接成一支。音量鍵和藍牙自拍遙控器也可以開始、停止錄影。手機橫著架，錄出來就是 16:9 的橫式影片，畫面上的字會跟著轉過來。")
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
