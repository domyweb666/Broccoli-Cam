import SwiftUI

/// 拍攝主畫面：9:16 前鏡頭預覽、提詞、構圖框、錄影控制。
struct RecordingView: View {
    @EnvironmentObject private var camera: CameraService
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = RecordingViewModel()
    @StateObject private var orientation = OrientationMonitor()
    @StateObject private var companion = CompanionModel()

    @State private var showScript = false
    @State private var showSettings = false

    // body 拆成三層（版面、狀態監聽、彈出視窗），一整串寫在一起編譯器會算不完。
    var body: some View {
        presented
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
    }

    /// 版面：預覽、控制列、橫放時的側邊列。
    private var layout: some View {
        GeometryReader { geo in
            let previewHeight = min(geo.size.width * 16 / 9, geo.size.height)
            let previewWidth = previewHeight * 9 / 16

            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                PreviewStack(
                    prompter: viewModel.prompter,
                    companion: companion,
                    phase: viewModel.phase,
                    text: viewModel.currentText,
                    isMerging: viewModel.isMerging,
                    angle: uiAngle,
                    size: CGSize(width: previewWidth, height: previewHeight)
                )
                .frame(width: previewWidth, height: previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(spacing: 10) {
                    Spacer()
                    if uiAngle == 0 {
                        statusAndSegments
                    }
                    ControlBar(
                        viewModel: viewModel,
                        prompter: viewModel.prompter,
                        angle: uiAngle,
                        showScript: $showScript,
                        showSettings: $showSettings
                    )
                }
                .padding(.bottom, 6)

                if uiAngle != 0 {
                    sideStrip(previewHeight: previewHeight)
                }

                if settings.showDebug {
                    DebugOverlayView()
                        .padding(.top, previewHeight * 0.34)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// 橫放：計時、收音、分段列轉 90 度，沿著使用者看到的下緣排，避開提詞那一側。
    private func sideStrip(previewHeight: CGFloat) -> some View {
        let topInset: CGFloat = previewHeight * 0.40 + 20
        let length: CGFloat = max(200, min(previewHeight - topInset - 110, 440))
        let thickness: CGFloat = viewModel.isSegmented ? 150 : 44
        let edge: Alignment = uiAngle > 0 ? .leading : .trailing
        return statusAndSegments
            .frame(width: length)
            .rotationEffect(.degrees(uiAngle))
            .frame(width: thickness, height: length)
            .padding(.top, topInset)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: edge)
    }

    /// 狀態監聽：設定、方向、前後景變了要做的事。
    private var observed: some View {
        cameraObserved
            .onChange(of: orientation.angle) { _, _ in
                viewModel.deviceAngle = deviceAngle
            }
            .onChange(of: settings.autoLandscape) { _, _ in
                viewModel.deviceAngle = deviceAngle
            }
            .onChange(of: settings.companionMode) { _, _ in
                viewModel.updateScript(settings.activeScript)
                viewModel.prompter.reset()
                updateCompanion()
            }
            .onChange(of: settings.speed) { _, speed in
                viewModel.prompter.speed = CGFloat(speed)
            }
            .onChange(of: showScript) { _, _ in updateHardwareEnabled() }
            .onChange(of: showSettings) { _, _ in updateHardwareEnabled() }
    }

    /// 和相機有關的監聽。
    private var cameraObserved: some View {
        layout
        .onAppear {
            viewModel.attach(camera, settings: settings)
            viewModel.updateScript(settings.activeScript)
            viewModel.prompter.speed = CGFloat(settings.speed)
            viewModel.deviceAngle = deviceAngle
            UIApplication.shared.isIdleTimerDisabled = true
            startCamera()
            updateCompanion()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            companion.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if viewModel.review == nil { startCamera() }
            case .background:
                viewModel.interrupt()
                camera.stop()
            default:
                break
            }
        }
        .onChange(of: settings.resolution) { _, resolution in
            // 換畫質後，幀率若不支援就退回可用的值。
            let supported = camera.availableFPS[resolution] ?? [30]
            if !supported.contains(settings.fps) {
                settings.fps = supported.first ?? 30
            }
            startCamera()
        }
        .onChange(of: settings.fps) { _, _ in startCamera() }
        .onChange(of: settings.mirrorOutput) { _, _ in startCamera() }
        .onChange(of: settings.voiceFollow) { _, _ in startCamera() }
        .onChange(of: camera.availableFPS) { _, map in
            // 第一次取得裝置能力後，修正存下來但此裝置不支援的設定。
            if map[settings.resolution] == nil {
                settings.resolution = .hd1080
            } else if let list = map[settings.resolution], !list.contains(settings.fps) {
                settings.fps = list.first ?? 30
            }
        }
    }

    /// 彈出視窗：提示、稿件、設定、完成頁。
    private var presented: some View {
        observed
        .alert("接片沒有成功", isPresented: mergeErrorShown) {
            Button("好") {}
        } message: {
            Text(viewModel.mergeError ?? "")
        }
        .alert("手機的擺法和前面不一樣", isPresented: orientationErrorShown) {
            Button("好") {}
        } message: {
            Text(viewModel.orientationError ?? "")
        }
        .sheet(isPresented: $showScript, onDismiss: {
            viewModel.updateScript(settings.activeScript)
            viewModel.prompter.reset()
        }) {
            ScriptEditorView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .fullScreenCover(item: $viewModel.review, onDismiss: {
            startCamera()
        }) { video in
            VideoReviewView(video: video, onDiscardAll: {
                viewModel.discardAllTakes()
            })
        }
    }

    /// 計時、收音狀態和分段列。直放時在控制列上方，橫放時轉 90 度放到側邊。
    @ViewBuilder
    private var statusAndSegments: some View {
        VStack(spacing: 10) {
            StatusRow(phase: viewModel.phase, elapsed: viewModel.elapsed, estimate: estimate,
                      canSwitchMode: !viewModel.isBusy && viewModel.pending == nil)
            if viewModel.isSegmented {
                SegmentBar(viewModel: viewModel)
            }
        }
    }

    /// 手機現在的擺法。關掉「橫放時錄橫式」就一律當直放。
    private var deviceAngle: Double {
        settings.autoLandscape ? orientation.angle : 0
    }

    /// 介面元件要轉幾度。開始倒數之後就固定，不跟著手機晃動。
    private var uiAngle: Double {
        viewModel.phase == .idle ? deviceAngle : viewModel.lockedAngle
    }

    private var orientationErrorShown: Binding<Bool> {
        Binding(
            get: { viewModel.orientationError != nil },
            set: { shown in
                if !shown { viewModel.orientationError = nil }
            }
        )
    }

    private func updateCompanion() {
        if settings.companionMode {
            companion.start(meter: camera.meter)
        } else {
            companion.stop()
        }
    }

    /// 目前這段（或整篇）稿件預估要講多久；沒有稿件時不顯示。
    private var estimate: TimeInterval? {
        guard settings.usesPrompter else { return nil }
        return ScriptSegments.estimatedSeconds(viewModel.currentText, charsPerMinute: settings.speechRate)
    }

    private var mergeErrorShown: Binding<Bool> {
        Binding(
            get: { viewModel.mergeError != nil },
            set: { shown in
                if !shown { viewModel.mergeError = nil }
            }
        )
    }

    private func updateHardwareEnabled() {
        viewModel.hardwareEnabled = !(showScript || showSettings)
    }

    private func startCamera() {
        camera.start(resolution: settings.resolution, fps: settings.fps, mirrorOutput: settings.mirrorOutput,
                     speechTap: settings.voiceFollow)
    }
}

// MARK: - 預覽與 Overlay

private struct PreviewStack: View {
    @EnvironmentObject private var camera: CameraService
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var prompter: TeleprompterModel
    let companion: CompanionModel
    let phase: RecordingViewModel.Phase
    let text: String
    let isMerging: Bool
    /// 橫放時字和圖示要轉的角度（±90）；直放是 0。
    let angle: Double
    let size: CGSize

    /// 有稿件時，構圖框只在開始提詞前顯示供對位；提詞開始後淡出。
    private var showGuide: Bool {
        guard settings.showGuide else { return false }
        if settings.usesPrompter && (prompter.isPlaying || prompter.offset > 0) { return false }
        return true
    }

    var body: some View {
        ZStack(alignment: .top) {
            CameraPreviewView(camera: camera)

            if showGuide {
                FramingGuideView(faces: camera.faces, scale: CGFloat(settings.guideScale), angle: angle)
                    .turned(angle, width: size.width, height: size.height)
                    .transition(.opacity)
            }

            if settings.usesPrompter {
                // 橫放時提詞變成鏡頭旁邊的一直欄，欄寬放大一點，一行才放得下夠多字。
                let bandWidth = size.width * 0.84
                let bandHeight = size.height * (angle == 0 ? 0.32 : 0.40)
                TeleprompterView(
                    model: prompter,
                    text: text,
                    fontSize: CGFloat(settings.fontSize),
                    backgroundOpacity: settings.promptBackground
                )
                .turned(angle, width: bandWidth, height: bandHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.top, 8)
            }

            if settings.companionMode {
                let side = min(size.width * 0.34, 150)
                CompanionView(model: companion)
                    .turned(angle, width: side, height: side)
                    .padding(.top, 12)
                    .transition(.opacity)
            }

            if case .countdown(let remaining) = phase {
                Text("\(remaining)")
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    .rotationEffect(.degrees(angle))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if isMerging {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.large)
                    Text("正在把各段接起來…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                }
                .padding(22)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .rotationEffect(.degrees(angle))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let note = camera.interruptionText {
                Text(note)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.7), in: Capsule())
                    .rotationEffect(.degrees(angle))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showGuide)
    }
}

// MARK: - 計時與收音狀態

private struct StatusRow: View {
    @EnvironmentObject private var camera: CameraService
    @EnvironmentObject private var settings: SettingsStore
    let phase: RecordingViewModel.Phase
    let elapsed: TimeInterval
    let estimate: TimeInterval?
    /// 待機時才能切換提詞／陪伴。
    let canSwitchMode: Bool

    private var timeText: String {
        let now = Self.format(elapsed)
        guard let estimate, estimate >= 1 else { return now }
        return "\(now) / 約 \(Self.format(estimate))"
    }

    var body: some View {
        HStack(spacing: 10) {
            if phase == .recording || phase == .finishing {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.record)
                        .frame(width: 8, height: 8)
                    Text(timeText)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
            }

            MicIndicator(meter: camera.meter)
                .onLongPressGesture(minimumDuration: 1.0) {
                    settings.showDebug.toggle()
                }

            if canSwitchMode {
                Button {
                    settings.companionMode.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: settings.companionMode ? "person.wave.2.fill" : "text.alignleft")
                            .font(.caption)
                        Text(settings.companionMode ? "陪伴" : "提詞")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(settings.companionMode ? Color.black : Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(settings.companionMode ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.black.opacity(0.55)),
                                in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(settings.companionMode ? "切換到提詞模式" : "切換到陪伴模式")
            }
        }
    }

    static func format(_ time: TimeInterval) -> String {
        let total = Int(time)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// 簡單的收音狀態：音量條會動代表有收到聲音；完全沒訊號才提示。
private struct MicIndicator: View {
    @ObservedObject var meter: SpeechActivityMonitor

    private var fraction: CGFloat {
        // -60 dB…0 dB 對應到 0…1
        let clamped = min(0, max(-60, CGFloat(meter.level)))
        return (clamped + 60) / 60
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: meter.micStatus == .noSignal ? "mic.slash.fill" : "mic.fill")
                .font(.caption)
            if meter.micStatus == .noSignal {
                Text("沒有偵測到聲音")
                    .font(.caption.weight(.medium))
            } else {
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(width: 44, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Theme.good)
                            .frame(width: 44 * fraction, height: 4)
                    }
            }
        }
        .foregroundStyle(meter.micStatus == .noSignal ? Color.yellow : Color.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
        .contentShape(Capsule())
    }
}

// MARK: - 控制列

private struct ControlBar: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var viewModel: RecordingViewModel
    @ObservedObject var prompter: TeleprompterModel
    let angle: Double
    @Binding var showScript: Bool
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 0) {
            BarButton(title: "稿件", systemImage: "doc.text", angle: angle) {
                showScript = true
            }
            .disabled(viewModel.isBusy || settings.companionMode)
            .opacity(settings.companionMode ? 0 : (viewModel.isBusy ? 0.35 : 1))

            BarButton(title: prompter.isPlaying ? "暫停" : "提詞",
                      systemImage: prompter.isPlaying ? "pause.fill" : "play.fill", angle: angle) {
                viewModel.togglePrompter()
            }
            .opacity(settings.usesPrompter ? 1 : 0)
            .disabled(!settings.usesPrompter)

            RecordButton(phase: viewModel.phase) {
                viewModel.primaryTapped(
                    countdown: settings.countdown,
                    autoPrompt: settings.autoStartPrompter && settings.usesPrompter
                )
            }
            .frame(maxWidth: .infinity)
            .disabled(viewModel.pending != nil || viewModel.isMerging)
            .opacity(viewModel.pending != nil || viewModel.isMerging ? 0.35 : 1)

            BarButton(title: "回開頭", systemImage: "arrow.counterclockwise", angle: angle) {
                prompter.reset()
            }
            .opacity(settings.usesPrompter ? 1 : 0)
            .disabled(!settings.usesPrompter)

            BarButton(title: "設定", systemImage: "slider.horizontal.3", angle: angle) {
                showSettings = true
            }
            .disabled(viewModel.isBusy)
            .opacity(viewModel.isBusy ? 0.35 : 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 10)
    }
}

// MARK: - 分段列

/// 分段錄影時顯示在控制列上方：目前第幾段、切換段落、剛錄完時選留用或重錄。
private struct SegmentBar: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var viewModel: RecordingViewModel

    /// 這一段預估要講多久。
    private var estimateText: String {
        let seconds = ScriptSegments.estimatedSeconds(viewModel.currentText, charsPerMinute: settings.speechRate)
        return "約 " + ScriptSegments.formatDuration(seconds)
    }

    private var canStep: Bool {
        !viewModel.isBusy && viewModel.pending == nil
    }

    /// 留用這段之後是不是就全部錄完了。
    private var isLastMissing: Bool {
        let recorded = Set(viewModel.takes.keys).union([viewModel.currentIndex])
        return recorded.count == viewModel.segments.count
    }

    private var canGoBack: Bool {
        canStep && viewModel.currentIndex > 0
    }

    private var canGoForward: Bool {
        canStep && viewModel.currentIndex < viewModel.segments.count - 1
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Button {
                    viewModel.step(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 36)
                        .contentShape(Rectangle())
                }
                .disabled(!canGoBack)
                .opacity(canGoBack ? 1 : 0.3)

                HStack(spacing: 6) {
                    Text("第 \(viewModel.currentIndex + 1)／\(viewModel.segments.count) 段")
                        .font(.subheadline.weight(.semibold))
                    Text(estimateText)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .monospacedDigit()
                    if viewModel.currentHasTake && viewModel.pending == nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Theme.good)
                    }
                }

                Button {
                    viewModel.step(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 36)
                        .contentShape(Rectangle())
                }
                .disabled(!canGoForward)
                .opacity(canGoForward ? 1 : 0.3)
            }
            .foregroundStyle(.white)

            if viewModel.pending != nil {
                HStack(spacing: 10) {
                    Button {
                        viewModel.retakePending()
                    } label: {
                        Text("重錄這段")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    Button {
                        viewModel.acceptPending()
                    } label: {
                        Text(isLastMissing ? "留用並接成一支" : "留用，下一段")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            } else if viewModel.allRecorded && !viewModel.isBusy {
                Button {
                    viewModel.mergeAll()
                } label: {
                    Text("接成一支影片")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 10)
    }
}

private struct BarButton: View {
    let title: String
    let systemImage: String
    var angle: Double = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .frame(height: 24)
                Text(title)
                    .font(.caption2)
            }
            .rotationEffect(.degrees(angle))
            .animation(.easeInOut(duration: 0.25), value: angle)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RecordButton: View {
    let phase: RecordingViewModel.Phase
    let action: () -> Void

    private var isStopShape: Bool {
        switch phase {
        case .idle: return false
        default: return true
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 5)
                    .frame(width: 68, height: 68)
                RoundedRectangle(cornerRadius: isStopShape ? 7 : 27, style: .continuous)
                    .fill(Theme.record)
                    .frame(width: isStopShape ? 28 : 54, height: isStopShape ? 28 : 54)
            }
            .animation(.easeInOut(duration: 0.18), value: isStopShape)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isStopShape ? "停止" : "開始錄影")
    }
}
