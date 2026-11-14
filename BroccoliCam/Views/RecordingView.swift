import SwiftUI

/// 拍攝主畫面：9:16 前鏡頭預覽、提詞、構圖框、錄影控制。
struct RecordingView: View {
    @EnvironmentObject private var camera: CameraService
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = RecordingViewModel()

    @State private var showScript = false
    @State private var showSettings = false

    var body: some View {
        GeometryReader { geo in
            let previewHeight = min(geo.size.width * 16 / 9, geo.size.height)
            let previewWidth = previewHeight * 9 / 16

            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                PreviewStack(
                    prompter: viewModel.prompter,
                    phase: viewModel.phase,
                    text: viewModel.currentText,
                    isMerging: viewModel.isMerging,
                    size: CGSize(width: previewWidth, height: previewHeight)
                )
                .frame(width: previewWidth, height: previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(spacing: 10) {
                    Spacer()
                    StatusRow(phase: viewModel.phase, elapsed: viewModel.elapsed, estimate: estimate)
                    if viewModel.isSegmented {
                        SegmentBar(viewModel: viewModel)
                    }
                    ControlBar(
                        viewModel: viewModel,
                        prompter: viewModel.prompter,
                        showScript: $showScript,
                        showSettings: $showSettings
                    )
                }
                .padding(.bottom, 6)

                if settings.showDebug {
                    DebugOverlayView()
                        .padding(.top, previewHeight * 0.34)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            viewModel.attach(camera, settings: settings)
            viewModel.updateScript(settings.script)
            viewModel.prompter.speed = CGFloat(settings.speed)
            UIApplication.shared.isIdleTimerDisabled = true
            startCamera()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
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
        .onChange(of: settings.speed) { _, speed in
            viewModel.prompter.speed = CGFloat(speed)
        }
        .onChange(of: camera.availableFPS) { _, map in
            // 第一次取得裝置能力後，修正存下來但此裝置不支援的設定。
            if map[settings.resolution] == nil {
                settings.resolution = .hd1080
            } else if let list = map[settings.resolution], !list.contains(settings.fps) {
                settings.fps = list.first ?? 30
            }
        }
        .onChange(of: showScript) { _, _ in updateHardwareEnabled() }
        .onChange(of: showSettings) { _, _ in updateHardwareEnabled() }
        .alert("接片沒有成功", isPresented: mergeErrorShown) {
            Button("好") {}
        } message: {
            Text(viewModel.mergeError ?? "")
        }
        .sheet(isPresented: $showScript, onDismiss: {
            viewModel.updateScript(settings.script)
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
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    /// 目前這段（或整篇）稿件預估要講多久；沒有稿件時不顯示。
    private var estimate: TimeInterval? {
        guard settings.hasScript else { return nil }
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
        camera.start(resolution: settings.resolution, fps: settings.fps, mirrorOutput: settings.mirrorOutput)
    }
}

// MARK: - 預覽與 Overlay

private struct PreviewStack: View {
    @EnvironmentObject private var camera: CameraService
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var prompter: TeleprompterModel
    let phase: RecordingViewModel.Phase
    let text: String
    let isMerging: Bool
    let size: CGSize

    /// 有稿件時，構圖框只在開始提詞前顯示供對位；提詞開始後淡出。
    private var showGuide: Bool {
        guard settings.showGuide else { return false }
        if settings.hasScript && (prompter.isPlaying || prompter.offset > 0) { return false }
        return true
    }

    var body: some View {
        ZStack(alignment: .top) {
            CameraPreviewView(camera: camera)

            if showGuide {
                FramingGuideView(faces: camera.faces, scale: CGFloat(settings.guideScale))
                    .transition(.opacity)
            }

            if settings.hasScript {
                TeleprompterView(
                    model: prompter,
                    text: text,
                    fontSize: CGFloat(settings.fontSize),
                    backgroundOpacity: settings.promptBackground
                )
                .frame(width: size.width * 0.84, height: size.height * 0.32)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.top, 8)
            }

            if case .countdown(let remaining) = phase {
                Text("\(remaining)")
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 8)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let note = camera.interruptionText {
                Text(note)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.7), in: Capsule())
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
    @Binding var showScript: Bool
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 0) {
            BarButton(title: "稿件", systemImage: "doc.text") {
                showScript = true
            }
            .disabled(viewModel.isBusy)
            .opacity(viewModel.isBusy ? 0.35 : 1)

            BarButton(title: prompter.isPlaying ? "暫停" : "提詞",
                      systemImage: prompter.isPlaying ? "pause.fill" : "play.fill") {
                viewModel.togglePrompter()
            }
            .opacity(settings.hasScript ? 1 : 0)
            .disabled(!settings.hasScript)

            RecordButton(phase: viewModel.phase) {
                viewModel.primaryTapped(
                    countdown: settings.countdown,
                    autoPrompt: settings.autoStartPrompter && settings.hasScript
                )
            }
            .frame(maxWidth: .infinity)
            .disabled(viewModel.pending != nil || viewModel.isMerging)
            .opacity(viewModel.pending != nil || viewModel.isMerging ? 0.35 : 1)

            BarButton(title: "回開頭", systemImage: "arrow.counterclockwise") {
                prompter.reset()
            }
            .opacity(settings.hasScript ? 1 : 0)
            .disabled(!settings.hasScript)

            BarButton(title: "設定", systemImage: "slider.horizontal.3") {
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
    @ObservedObject var viewModel: RecordingViewModel

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
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    Button {
                        viewModel.acceptPending()
                    } label: {
                        Text(isLastMissing ? "留用並接成一支" : "留用，下一段")
                            .font(.subheadline.weight(.semibold))
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
