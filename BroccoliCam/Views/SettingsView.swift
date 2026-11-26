import SwiftUI

/// 簡單設定。只列出此裝置實際支援的畫質與幀率。不放說明文字，選項要大、好按（QC-0005）。
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var camera: CameraService
    @Environment(\.dismiss) private var dismiss
    /// 主畫面有錄好、還沒接起來的段落。
    var hasTakes = false
    /// 字幕校對頁打開／關掉。
    var onCaptionEditing: (Bool) -> Void = { _ in }

    @State private var speechDenied = false
    /// 想改成的分段設定，等使用者確認要丟掉已錄的段落。
    @State private var wantedSegmented: Bool?

    private var fpsOptions: [Int] {
        camera.availableFPS[settings.resolution] ?? [30]
    }

    var body: some View {
        NavigationStack {
            styledForm
                .onChange(of: settings.voiceFollow) { _, on in
                    askSpeech(on)
                }
                .alert("沒有語音辨識的權限", isPresented: $speechDenied) {
                    Button("好") {}
                } message: {
                    Text("請到「設定 → 花椰菜相機」打開「語音辨識」，再回來打開這個開關。")
                }
                .alert("已經錄好的段落會刪掉", isPresented: confirmSegmentedShown,
                       presenting: wantedSegmented) { wanted in
                    Button("刪掉並切換", role: .destructive) {
                        settings.segmentedRecording = wanted
                    }
                    Button("取消", role: .cancel) {}
                }
        }
    }

    private var styledForm: some View {
        form
            .font(.system(size: 20))
            .environment(\.defaultMinListRowHeight, 60)
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

    // 每一區各自一個屬性，整張表寫在一起編譯器會算不完。
    private var form: some View {
        // 看多少字、有人聽、不看自己、即時反應只放在主畫面的「看多少字」選單，這裡不再重複（QC-0012，回報 #94）。
        Form {
            guideSection
            promptSection
            voiceSection
            videoSection
            recordingSection
            micSection
            subtitleSection
            advancedSection
        }
    }

    private var guideSection: some View {
        Section {
            GuidePicker()
                .padding(.vertical, 8)
            if settings.guideStyle != .off {
                LabeledSlider(title: "濃淡", value: $settings.guideOpacity, range: 0.2...1, step: 0.05,
                              display: Self.percent(settings.guideOpacity))
            }
            if settings.guideStyle == .head {
                LabeledSlider(title: "頭像框大小", value: $settings.guideScale, range: 0.7...1.4, step: 0.05,
                              display: Self.percent(settings.guideScale))
            }
            // 主畫面預設只放語音跟隨和一鍵優化，要的人自己打開（回報 #87）。
            Toggle("主畫面也放構圖和防抖鍵", isOn: $settings.showAllQuickToggles)
        } header: {
            Text("構圖")
        }
    }

    private var promptSection: some View {
        Section {
            LabeledSlider(title: "文字大小", value: $settings.fontSize, range: 16...48, step: 1,
                          display: "\(Int(settings.fontSize))")
            LabeledSlider(title: "速度", value: $settings.speed, range: 8...120, step: 2,
                          display: "\(Int(settings.speed))")
            LabeledSlider(title: "底色深淺", value: $settings.promptBackground, range: 0...0.9, step: 0.05,
                          display: Self.percent(settings.promptBackground))
            LabeledSlider(title: "語速（估算時長用）", value: $settings.speechRate, range: 150...320, step: 10,
                          display: "\(Int(settings.speechRate)) 字／分")
            Toggle("開始錄影時自動開始提詞", isOn: $settings.autoStartPrompter)
            Toggle("停頓時提詞等我", isOn: $settings.waitOnPause)
            Toggle("分段錄影", isOn: segmentedBinding)
            NavigationLink("藍牙控制") {
                RemoteSettingsView()
            }
        } header: {
            Text("提詞")
        }
    }

    private var voiceSection: some View {
        Section {
            Toggle("提詞跟著我的聲音走", isOn: $settings.voiceFollow)
        } header: {
            Text("語音跟隨")
        }
    }

    private var videoSection: some View {
        Section {
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
            Picker("防抖", selection: stabilizationBinding) {
                ForEach(camera.availableStabilizations) { level in
                    Text(level.label).tag(level)
                }
            }
            Toggle("畫面優化", isOn: $settings.lookEnabled)
            Picker("優化過場", selection: $settings.lookTransition) {
                ForEach(LookTransition.allCases) { Text($0.label).tag($0) }
            }
            Toggle("影片左右鏡像", isOn: $settings.mirrorOutput)
        } header: {
            Text("影片")
        }
    }

    /// 顯示實際生效的強度；存下來的選擇在不支援的格式上不會被改掉。
    private var stabilizationBinding: Binding<StabilizationLevel> {
        Binding<StabilizationLevel>(
            get: { camera.effectiveStabilization(settings.stabilization) },
            set: { settings.stabilization = $0 }
        )
    }

    private var recordingSection: some View {
        Section {
            Picker("倒數", selection: $settings.countdown) {
                Text("不倒數").tag(0)
                Text("3 秒").tag(3)
                Text("5 秒").tag(5)
                Text("10 秒").tag(10)
            }
            Toggle("接片時裁掉每段頭尾的空白", isOn: $settings.trimSilence)
            Toggle("手機橫放時錄橫式影片", isOn: $settings.autoLandscape)
            Toggle("錄完檢查", isOn: $settings.takeCheck)
        } header: {
            Text("錄影")
        }
    }

    /// 收音：哪支麥克風、藍牙、雙聲道。這一區要講清楚現在用的是哪支、藍牙音質會變差，所以有說明文字。
    private var micSection: some View {
        Section {
            Picker("麥克風", selection: $settings.micChoice) {
                ForEach(micOptions) { option in
                    Text(option.label).tag(option.id)
                }
            }
            Toggle("藍牙麥克風", isOn: $settings.bluetoothMic)
            Picker("雙聲道外接麥", selection: $settings.micChannelMode) {
                ForEach(MicChannelMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            if CameraService.supportsBluetoothHQ {
                Toggle("AirPods 高品質收音", isOn: $settings.airPodsMic)
            }
        } header: {
            Text("收音")
        } footer: {
            Text(micFooter)
                .font(.footnote)
        }
    }

    private struct MicOption: Identifiable {
        let id: String
        let label: String
    }

    private var micOptions: [MicOption] {
        var list = [MicOption(id: MicChoice.automatic.storage, label: "自動（有外接就用外接）"),
                    MicOption(id: MicChoice.builtIn.storage, label: "手機麥克風")]
        let external = camera.micRoute.available.filter { $0.kind != .builtIn }
        for port in external {
            list.append(MicOption(id: MicChoice.port(uid: port.id, name: port.name).storage, label: port.name))
        }
        // 指定過、現在沒接上的那支也列出來，選單才對得上。
        if case .port(let uid, let name) = MicChoice(storage: settings.micChoice),
           !external.contains(where: { $0.id == uid }) {
            list.append(MicOption(id: settings.micChoice, label: "\(name)（沒接上，先自動挑）"))
        }
        return list
    }

    private var micFooter: String {
        let route = camera.micRoute
        var lines = ["現在：\(route.summary)"]
        if let waiting = route.waitingFor {
            lines.append("「\(waiting)」這段錄完就會換過去。")
        }
        if route.isPhoneQuality {
            lines.append("藍牙麥克風走電話用的通道，聲音只有電話音質、會比較悶。DJI Mic Mini、Mic 3 要好音質，請把 USB-C 接收器插在手機上。")
        } else if settings.bluetoothMic {
            lines.append("藍牙麥克風（DJI 直連手機、AirPods）是電話音質，比 USB-C 接收器差。")
        } else {
            lines.append("藍牙麥克風關著：戴 AirPods、DJI 用藍牙直連時，還是用手機麥克風收音。")
        }
        if settings.micChannelMode == .stereo {
            lines.append("立體聲：兩支發射器各錄在左、右聲道。只有一支發射器時請選合成單聲道，不然只有一邊耳朵有聲音。")
        }
        return lines.joined(separator: "\n")
    }

    private var subtitleSection: some View {
        Section {
            NavigationLink("字幕專案") {
                CaptionListView(onEditing: onCaptionEditing)
            }
            CaptionStylePicker(style: $settings.captionStyle)
                .padding(.vertical, 8)
            LabeledSlider(title: "直式一行字數", value: $settings.captionCharsPortrait, range: 6...16, step: 1,
                          display: "\(Int(settings.captionCharsPortrait)) 字")
            LabeledSlider(title: "橫式一行字數", value: $settings.captionCharsLandscape, range: 8...24, step: 1,
                          display: "\(Int(settings.captionCharsLandscape)) 字")
            LabeledSlider(title: "SRT 每行最多字數", value: $settings.subtitleMaxChars, range: 8...20, step: 1,
                          display: "\(Int(settings.subtitleMaxChars)) 字")
        } header: {
            Text("字幕")
        }
    }

    private var advancedSection: some View {
        Section {
            Toggle("顯示除錯資訊", isOn: $settings.showDebug)
        } header: {
            Text("進階")
        }
    }

    /// 已經錄了幾段的時候，改分段會讓它們全部作廢，先問一次。
    private var segmentedBinding: Binding<Bool> {
        Binding<Bool>(
            get: { settings.segmentedRecording },
            set: { wanted in
                if hasTakes {
                    wantedSegmented = wanted
                } else {
                    settings.segmentedRecording = wanted
                }
            }
        )
    }

    private var confirmSegmentedShown: Binding<Bool> {
        Binding<Bool>(
            get: { wantedSegmented != nil },
            set: { shown in
                if !shown { wantedSegmented = nil }
            }
        )
    }

    private func askSpeech(_ on: Bool) {
        guard on, !SpeechFollower.isAuthorized else { return }
        SpeechFollower.requestAuthorization { granted in
            if !granted {
                settings.voiceFollow = false
                speechDenied = true
            }
        }
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// 構圖線三選一：關、頭像框、九宮格。
private struct GuidePicker: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        HStack(spacing: 12) {
            ForEach(GuideStyle.allCases) { style in
                styleButton(style)
            }
        }
    }

    private func styleButton(_ style: GuideStyle) -> some View {
        let selected = settings.guideStyle == style
        return Button {
            settings.guideStyle = style
        } label: {
            VStack(spacing: 10) {
                GuideThumb(style: style, color: selected ? Color.black : Color.white)
                Text(style.label)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .modifier(ModeCard(selected: selected, height: 116))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 構圖線的小示意圖：直式畫面裡一個人形輪廓，或一個九宮格。
private struct GuideThumb: View {
    let style: GuideStyle
    let color: Color

    private let w: CGFloat = 34
    private let h: CGFloat = 58

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(color.opacity(0.22))
            switch style {
            case .off:
                EmptyView()
            case .head:
                head
            case .grid:
                grid
            }
        }
        .frame(width: w, height: h)
        .accessibilityHidden(true)
    }

    private var head: some View {
        VStack(spacing: 2) {
            Ellipse()
                .stroke(color, lineWidth: 1.5)
                .frame(width: 15, height: 21)
            UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10)
                .stroke(color, lineWidth: 1.5)
                .frame(width: 26, height: 11)
        }
    }

    private var grid: some View {
        ZStack {
            HStack(spacing: w / 3) {
                bar(1.5, h)
                bar(1.5, h)
            }
            VStack(spacing: h / 3) {
                bar(w, 1.5)
                bar(w, 1.5)
            }
        }
    }

    private func bar(_ width: CGFloat, _ height: CGFloat) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: width, height: height)
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
