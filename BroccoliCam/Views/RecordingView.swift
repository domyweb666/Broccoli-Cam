import SwiftUI

/// 拍攝主畫面：9:16 前鏡頭預覽、提詞、構圖框、錄影控制。
struct RecordingView: View {
    @EnvironmentObject private var camera: CameraService
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: ScriptLibrary
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = RecordingViewModel()
    @StateObject private var orientation = OrientationMonitor()
    @StateObject private var companion = CompanionModel()
    @StateObject private var clipPlayer = CompanionClipPlayer()

    @State private var showScript = false
    @State private var showSettings = false
    @State private var showModes = false
    @State private var showLook = false

    // body 拆成好幾層（版面、狀態監聽、彈出視窗），一整串寫在一起編譯器會算不完。
    var body: some View {
        presented
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
    }

    /// 版面：預覽、控制列、側邊的快速開關、橫放時的側邊列、畫面優化面板。
    private var layout: some View {
        GeometryReader { geo in
            screen(in: geo.size)
        }
        .background {
            remoteCatcher
        }
    }

    private func screen(in screen: CGSize) -> some View {
        let previewHeight: CGFloat = min(screen.width * 16 / 9, screen.height)
        let preview = CGSize(width: previewHeight * 9 / 16, height: previewHeight)

        return ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            previewStack(preview, screenHeight: screen.height)

            // 要在開關和控制列底下，不然會蓋住、吃掉點擊。往下放一點，跳出來的提示才看得到。
            if settings.showDebug {
                DebugOverlayView()
                    .padding(.top, previewHeight * 0.44)
            }

            sideControls(preview, screenHeight: screen.height)

            bottomControls

            if uiAngle != 0 {
                sideStrip(previewHeight: previewHeight)
            }

            if showLook {
                lookPanel(height: screen.height * 0.38)
            }
        }
        .frame(width: screen.width, height: screen.height)
        .animation(.easeOut(duration: 0.25), value: showLook)
    }

    private func previewStack(_ preview: CGSize, screenHeight: CGFloat) -> some View {
        PreviewStack(
            prompter: viewModel.prompter,
            clipPlayer: clipPlayer,
            phase: viewModel.phase,
            text: viewModel.currentText,
            isPoint: viewModel.currentIsPoint,
            isMerging: viewModel.isMerging,
            angle: uiAngle,
            size: preview,
            bottomInset: controlsOverlap(screenHeight: screenHeight, previewHeight: preview.height),
            jumpNote: viewModel.jumpNote,
            onTapOffset: { offset in
                viewModel.jumpTo(utf16Offset: offset)
            },
            onPointScrolls: { value in
                viewModel.pointScrollsChanged(value)
            }
        )
        .frame(width: preview.width, height: preview.height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var bottomControls: some View {
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
        .accessibilityHidden(showLook)
    }

    /// 預覽兩側的快速開關和跳轉鍵。
    /// 直放：開關在左下（自己的小窗在右下），跳轉鍵在提詞右下方。
    /// 橫放：都排在使用者看到的上緣，下緣是計時和分段列。
    private func sideControls(_ preview: CGSize, screenHeight: CGFloat) -> some View {
        let sideways = uiAngle != 0
        let bandBottom: CGFloat = PromptBand.bottom(previewHeight: preview.height, angle: uiAngle)
        let bottom: CGFloat = sideways
            ? sidewaysOverlap(screenHeight: screenHeight, previewHeight: preview.height) + 10
            : controlsOverlap(screenHeight: screenHeight, previewHeight: preview.height) + 10
        // 跳轉鍵在直放時和開關分兩邊；橫放時排在同一側的上面，要多留一列。
        let room: CGFloat = preview.height - bandBottom - bottom - (sideways ? 60 : 0)
        let showsVoiceToggle: Bool = settings.usesPrompter && !viewModel.currentIsPoint
        // 顆數和 QuickToggles 裡實際排的用同一套規則算，大小才不會估錯。
        let toggleCount: Int = QuickToggles.count(showsVoice: showsVoiceToggle,
                                                  showsAll: settings.showAllQuickToggles,
                                                  stabilizationChoices: camera.availableStabilizations.count)
        let fullHeight: CGFloat = QuickToggles.fullHeight(side: 48, count: toggleCount, sideways: sideways)
        let side: CGFloat = room >= fullHeight ? 48 : 44
        let togglesOnRight = uiAngle > 0
        let keysOnRight = uiAngle >= 0

        return ZStack {
            // 檢查的小卡會長到開關那裡，留用或重錄之前先收起來。
            if !showLook, viewModel.pendingCheck == nil {
                QuickToggles(
                    isBusy: viewModel.isBusy,
                    showsVoice: showsVoiceToggle,
                    angle: uiAngle,
                    side: side,
                    onVoice: { viewModel.toggleVoiceFollow() },
                    onLook: { showLook = true }
                )
                .padding(.horizontal, 6)
                .padding(.bottom, bottom)
                .frame(width: preview.width, height: preview.height,
                       alignment: togglesOnRight ? .bottomTrailing : .bottomLeading)
                .transition(.opacity)
            }

            // 重點整張看得到的話，只有分段錄影要換段時才用得到跳轉鍵。
            if settings.usesPrompter, viewModel.currentScrolls || viewModel.isSegmented {
                JumpKeys(angle: uiAngle, side: side, sideBySide: showsListener) { forward in
                    viewModel.jump(forward: forward)
                }
                .padding(.horizontal, 8)
                .padding(.top, bandBottom + 8)
                .frame(width: preview.width, height: preview.height,
                       alignment: keysOnRight ? .topTrailing : .topLeading)
            }
        }
        .frame(width: preview.width, height: preview.height)
    }

    private func lookPanel(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LookPanel(
                isBusy: viewModel.isBusy,
                isRecording: viewModel.phase == .recording,
                onClose: { showLook = false }
            )
            .frame(height: height)
        }
        .transition(.move(edge: .bottom))
    }

    /// 藍牙踏板、翻頁器。有東西蓋在主畫面上的時候放掉，才不會搶走打字。
    private var remoteCatcher: some View {
        RemoteKeyCatcher(isActive: remoteActive) { key in
            guard let action = settings.remoteBindings.action(for: key) else { return }
            viewModel.perform(action)
        }
        .frame(width: 1, height: 1)
        .accessibilityHidden(true)
    }

    private var remoteActive: Bool {
        if showScript || showSettings || showModes { return false }
        return !viewModel.hasWindow
    }

    /// 橫放：計時、收音、分段列轉 90 度，沿著使用者看到的下緣排，避開提詞那一側。
    private func sideStrip(previewHeight: CGFloat) -> some View {
        let topInset: CGFloat = previewHeight * 0.40 + 20
        let length: CGFloat = max(200, min(previewHeight - topInset - 110, 440))
        let thickness: CGFloat = viewModel.isSegmented ? 150 + cardHeight + extraHeight : 44
        let edge: Alignment = uiAngle > 0 ? .leading : .trailing
        return statusAndSegments
            .frame(width: length)
            .rotationEffect(.degrees(uiAngle))
            .frame(width: thickness, height: length)
            .padding(.top, topInset)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: edge)
    }

    /// 狀態監聽：方向、哪些視窗開著。
    private var observed: some View {
        scriptObserved
            .onChange(of: orientation.angle) { _, _ in
                viewModel.deviceAngle = deviceAngle
                // 橫過來過一次就知道了，比例小標不用再多寫提示。
                if deviceAngle != 0, !settings.landscapeHintDone { settings.landscapeHintDone = true }
            }
            .onChange(of: settings.autoLandscape) { _, _ in
                viewModel.deviceAngle = deviceAngle
            }
            .onChange(of: showScript) { _, _ in updateHardwareEnabled() }
            .onChange(of: showSettings) { _, _ in updateHardwareEnabled() }
            .onChange(of: showModes) { _, _ in updateHardwareEnabled() }
            .onChange(of: viewModel.phase) { _, phase in
                // 面板會蓋住停止鈕；一鍵優化跑到一半就開錄也在這裡停掉。
                guard phase != .idle else { return }
                showLook = false
                camera.cancelOptimize()
            }
            .onChange(of: viewModel.pending != nil) { _, waiting in
                // 剛錄完一段，留用／重錄的按鈕在面板底下，把面板收起來。
                if waiting { showLook = false }
            }
    }

    /// 和稿子、提詞有關的監聽。
    private var scriptObserved: some View {
        formatObserved
            .onChange(of: settings.promptAmount) { _, _ in
                viewModel.promptAmountChanged()
                askSpeechIfNeeded()
            }
            .onChange(of: showsListener) { _, _ in
                // 只多一個人或少一個人，段落和稿子都不動。
                updateCompanion()
            }
            .onChange(of: settings.micPreferences) { _, preferences in
                camera.setMicPreferences(preferences)
            }
            .onChange(of: settings.script) { _, _ in
                // 腳本頁開著時不跟著打字更新，不然改一個字已錄的各段就作廢，關掉那一頁再一次算。
                if !showScript { viewModel.updateScript(settings.activeScript) }
            }
            .onChange(of: settings.segmentedRecording) { _, _ in
                // 設定頁已經問過會不會刪掉已錄的。
                viewModel.updateScript(settings.activeScript, force: true)
            }
            .onChange(of: settings.voiceFollow) { _, _ in
                viewModel.applyVoiceFollowSetting()
            }
            .onChange(of: settings.speed) { _, speed in
                viewModel.prompter.speed = CGFloat(speed)
            }
    }

    /// 影片格式和畫面優化的監聽。
    private var formatObserved: some View {
        lifecycleObserved
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
            .onChange(of: settings.stabilization) { _, _ in startCamera() }
            .onChange(of: camera.availableFPS) { _, map in
                fixFormat(map)
            }
            .onChange(of: settings.look) { _, _ in applyLook() }
            .onChange(of: settings.lookEnabled) { _, _ in applyLook() }
    }

    /// 出現、消失、前後景。
    private var lifecycleObserved: some View {
        layout
            .onAppear(perform: appeared)
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
                companion.stop()
                clipPlayer.stop()
            }
            .onChange(of: scenePhase) { _, phase in
                sceneChanged(phase)
            }
            .onChange(of: settings.takeCheck) { _, _ in
                viewModel.syncChecks()
            }
    }

    private func appeared() {
        viewModel.attach(camera, settings: settings)
        viewModel.updateScript(settings.activeScript)
        viewModel.prompter.speed = CGFloat(settings.speed)
        viewModel.deviceAngle = deviceAngle
        UIApplication.shared.isIdleTimerDisabled = true
        camera.setMicPreferences(settings.micPreferences)
        startCamera()
        updateCompanion()
        askSpeechIfNeeded()
    }

    private func sceneChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // 播放視窗、完成頁、校對頁自己會停相機，關掉才叫起來。
            if viewModel.review == nil && !viewModel.isCaptionEditing && viewModel.checkPlayback == nil {
                startCamera()
            }
            clipPlayer.resume()
            viewModel.checker.hold(.background, false)
            viewModel.syncChecks()
        case .background:
            // 在背景辨識會被系統收走，回來再聽。
            viewModel.checker.hold(.background, true)
            viewModel.interrupt()
            camera.stop()
        default:
            break
        }
    }

    /// 第一次取得裝置能力後，修正存下來但此裝置不支援的設定。
    private func fixFormat(_ map: [VideoResolution: [Int]]) {
        if map[settings.resolution] == nil {
            settings.resolution = .hd1080
        } else if let list = map[settings.resolution], !list.contains(settings.fps) {
            settings.fps = list.first ?? 30
        }
    }

    /// 上次留下來的段落或影片，開 App 時問。
    private var recoveryAlerts: some View {
        observed
            .alert("上次有一支影片還沒儲存", isPresented: recoveryShown(.video)) {
                // 一定要有 cancel，不然系統會自己多加一顆「取消」。
                Button("看影片", role: .cancel) { viewModel.openRecoveredVideo() }
                Button("刪掉", role: .destructive) { viewModel.deleteRecoveredVideo() }
            }
            .alert("上次還有 \(viewModel.recoveredCount) 段沒接完", isPresented: recoveryShown(.takes)) {
                Button("接著錄", role: .cancel) { viewModel.resumeRecoveredTakes() }
                Button("刪掉", role: .destructive) { viewModel.deleteRecoveredTakes() }
            }
    }

    /// 聽檢查出來的那一處。
    private var checkPresented: some View {
        recoveryAlerts
            .sheet(item: $viewModel.checkPlayback, onDismiss: {
                // 播放器收掉了才把相機叫起來，音訊才換得回去。
                startCamera()
                viewModel.playbackClosed()
            }) { playback in
                TakePlaybackView(playback: playback, retakeTitle: "重錄這段",
                                 onRetake: { viewModel.requestRetake(playback.file) })
            }
    }

    /// 彈出視窗：提示、腳本、設定、完成頁。
    private var presented: some View {
        checkPresented
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
        .alert("錄影有狀況", isPresented: recordingErrorShown) {
            Button("好") {}
        } message: {
            Text(viewModel.recordingError ?? "")
        }
        .alert(scriptChangeTitle, isPresented: scriptChangeShown) {
            Button(scriptChangeAction, role: .destructive) { viewModel.acceptScriptChange() }
            Button("保留已錄的", role: .cancel) { viewModel.declineScriptChange() }
        }
        .sheet(isPresented: $showScript, onDismiss: {
            // 打字是延遲併入的，先寫回去再切段，不然會漏最後幾個字。
            library.flush()
            viewModel.updateScript(settings.activeScript)
            viewModel.prompter.reset()
            askSpeechIfNeeded()
        }) {
            ScriptListView()
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            viewModel.reconsiderScript()
            // 字幕一行的字數、語音辨識的權限都可能在裡面變了。
            viewModel.syncChecks()
        }) {
            SettingsView(hasTakes: hasTakes, onCaptionEditing: { open in captionEditing(open) })
        }
        .sheet(isPresented: $showModes, onDismiss: { viewModel.reconsiderScript() }) {
            ModeSheet()
        }
        .fullScreenCover(item: $viewModel.review, onDismiss: {
            startCamera()
            viewModel.reviewDismissed()
            viewModel.reconsiderScript()
        }) { video in
            VideoReviewView(
                video: video,
                checker: viewModel.checker,
                hearing: { file in viewModel.hearing(of: file) },
                onHeard: { hearing, file in viewModel.adoptHearing(hearing, for: file) },
                onRetake: { file in viewModel.requestRetake(file) },
                onSaved: { viewModel.reviewSaved(video) },
                onDiscard: { viewModel.reviewDiscarded(video) },
                onDiscardAll: { viewModel.discardTakes(of: video) }
            )
        }
    }

    /// 計時、收音狀態和分段列。直放時在控制列上方，橫放時轉 90 度放到側邊。
    @ViewBuilder
    private var statusAndSegments: some View {
        VStack(spacing: 10) {
            StatusRow(phase: viewModel.phase, elapsed: viewModel.elapsed, estimate: estimate,
                      canSwitchMode: !viewModel.isBusy && viewModel.pending == nil,
                      sideways: uiAngle != 0,
                      showModes: $showModes)
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

    private var recordingErrorShown: Binding<Bool> {
        Binding(
            get: { viewModel.recordingError != nil },
            set: { shown in
                if !shown { viewModel.recordingError = nil }
            }
        )
    }

    /// 兩顆按鈕都會自己清掉，這裡不用再動。
    private func recoveryShown(_ kind: RecordingViewModel.Recovery) -> Binding<Bool> {
        Binding(
            get: { viewModel.recovery == kind },
            set: { _ in }
        )
    }

    /// 兩顆按鈕都會自己清掉，這裡不用再動。
    private var scriptChangeShown: Binding<Bool> {
        Binding(
            get: { viewModel.scriptChange != nil },
            set: { _ in }
        )
    }

    private var scriptChangeAction: String {
        viewModel.scriptChange?.action ?? "換稿"
    }

    private var scriptChangeTitle: String {
        "\(scriptChangeAction)會刪掉已錄的 \(viewModel.scriptChange?.count ?? 0) 段"
    }

    /// 聆聽者現在會不會畫出來。橫放又有字的時候沒有放的位置，不用一直解碼。
    private var showsListener: Bool {
        settings.hasListener && !(settings.usesPrompter && uiAngle != 0)
    }

    private func updateCompanion() {
        if showsListener {
            companion.start(meter: camera.meter)
            clipPlayer.start(model: companion)
        } else {
            companion.stop()
            clipPlayer.stop()
        }
    }

    /// 底下的狀態列、分段列、控制列蓋進預覽區多少。視訊通話的自己小窗要放在這之上。
    private func controlsOverlap(screenHeight: CGFloat, previewHeight: CGFloat) -> CGFloat {
        let controls: CGFloat = 130 + (viewModel.isSegmented ? 110 + extraHeight : 0)
        return max(0, controls - (screenHeight - previewHeight))
    }

    /// 剛錄完那一段的小卡多高。
    private var cardHeight: CGFloat {
        guard let entry = viewModel.pendingCheck else { return 0 }
        return TakeCheckCard.height([entry], maxRows: TakeCheckCard.compactRows) + 8
    }

    /// 「第 2 段有 1 處」和「聲音會送到 Apple 辨識」多佔的高度。分段列原本就留了一列按鈕的位置。
    private var extraHeight: CGFloat {
        let hasButtons: Bool = viewModel.allRecorded || viewModel.pending != nil
        var rows: CGFloat = hasButtons ? 54 : 0
        if !viewModel.checkFlags.isEmpty { rows += 52 }
        if viewModel.showsCheckSending { rows += 26 }
        return max(0, rows - 54)
    }

    /// 目前這段（或整篇）稿件預估要講多久；沒有稿件時不顯示。
    private var estimate: TimeInterval? {
        // 提綱是用自己的話講，照字數估不準。
        guard settings.usesPrompter, settings.promptAmount != .outline, !viewModel.currentIsPoint else { return nil }
        return ScriptSegments.estimatedSeconds(viewModel.currentText, charsPerMinute: settings.speechRate)
    }

    /// 橫放時預覽底下只有控制列，狀態列在側邊。
    private func sidewaysOverlap(screenHeight: CGFloat, previewHeight: CGFloat) -> CGFloat {
        max(0, 100 - (screenHeight - previewHeight))
    }

    /// 有已經錄好、還沒接起來的段落。改分段設定會讓它們作廢。
    private var hasTakes: Bool {
        !viewModel.takes.isEmpty || viewModel.pending != nil
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
        viewModel.hardwareEnabled = !(showScript || showSettings || showModes)
    }

    /// 有稿子要唸、又開著語音跟隨，先把辨識權限問完，不要等按了錄影才跳出來。
    private func askSpeechIfNeeded() {
        guard settings.voiceFollow, settings.usesPrompter, SpeechFollower.isUndetermined else { return }
        SpeechFollower.requestAuthorization { granted in
            // 之前錄的沒有權限檢查，現在可以了。
            if granted { viewModel.syncChecks() }
        }
    }

    /// 從設定打開或關掉字幕校對頁。校對頁自己會停相機，關掉再叫起來。
    private func captionEditing(_ open: Bool) {
        viewModel.isCaptionEditing = open
        // 校對頁可能要辨識，檢查先讓開。
        viewModel.checker.hold(.captions, open)
        if !open { startCamera() }
    }

    private func startCamera() {
        camera.start(resolution: settings.resolution, fps: settings.fps, mirrorOutput: settings.mirrorOutput,
                     stabilization: settings.stabilization)
        applyLook()
    }

    private func applyLook() {
        camera.setLook(settings.look, enabled: settings.lookEnabled)
    }
}

/// 提詞區塊的大小。預覽和旁邊的跳轉鍵都要知道它到哪裡。
private enum PromptBand {
    static let top: CGFloat = 8

    /// 橫放時提詞變成鏡頭旁邊的一直欄，欄寬放大一點，一行才放得下夠多字。
    static func height(previewHeight: CGFloat, angle: Double) -> CGFloat {
        previewHeight * (angle == 0 ? 0.32 : 0.40)
    }

    static func bottom(previewHeight: CGFloat, angle: Double) -> CGFloat {
        top + height(previewHeight: previewHeight, angle: angle)
    }
}

// MARK: - 預覽與 Overlay

private struct PreviewStack: View {
    @EnvironmentObject private var camera: CameraService
    @EnvironmentObject private var settings: SettingsStore
    /// 捲動位置、唸到哪都不發布，這裡只會在播放、跟讀、開始了沒這幾個很少變的狀態變了才重算。
    @ObservedObject var prompter: TeleprompterModel
    let clipPlayer: CompanionClipPlayer
    let phase: RecordingViewModel.Phase
    let text: String
    /// 目前這段是提綱的重點。
    let isPoint: Bool
    let isMerging: Bool
    /// 橫放時字和圖示要轉的角度（±90）；直放是 0。
    let angle: Double
    let size: CGSize
    /// 控制列蓋進預覽區的高度，視訊通話的自己小窗放在這之上。
    let bottomInset: CGFloat
    /// 跳轉後短暫顯示的字；nil 就不顯示。
    let jumpNote: String?
    /// 點提詞的某一行。
    let onTapOffset: (Int) -> Void
    /// 重點是不是放不下、要捲。
    let onPointScrolls: (Bool) -> Void

    @StateObject private var selfView = SelfViewModel()

    /// 聆聽者的擺法；沒有聆聽者是 nil。
    /// 有字的時候字要貼著鏡頭，聆聽者只能墊在字的底下，所以只用滿版的兩種；橫放沒有滿版，就不顯示。
    /// 沒有字、橫放時只有圓形頭像和頂部小窗對得上視線（鏡頭在側邊），其他擺法改用頂部小窗。
    private var layout: CompanionLayout? {
        guard settings.hasListener else { return nil }
        let chosen = settings.companionLayout
        if settings.usesPrompter {
            guard angle == 0 else { return nil }
            return chosen == .alignFirst ? .alignFirst : .fullCall
        }
        if angle != 0 && chosen != .circle {
            return .topCard
        }
        return chosen
    }

    /// 已經按下錄影、倒數結束。
    private var isRolling: Bool {
        switch phase {
        case .starting, .recording, .finishing: return true
        case .idle, .countdown: return false
        }
    }

    /// 正在錄，而且選了不看自己。按了停止就看得到。
    private var hidesSelf: Bool {
        phase == .recording && settings.hideSelf
    }

    /// 現在看不到自己。
    private var selfHidden: Bool {
        hidesSelf && selfView.isHidden
    }

    /// 淡掉、淡回來都慢慢來；停止錄影立刻回來。
    private var selfFade: Animation? {
        hidesSelf ? .easeInOut(duration: 0.5) : nil
    }

    /// 自己的畫面在預覽區裡的位置。一律是完整的 9:16，頭在裡面的位置就是錄出來的位置。
    private var cameraRect: CGRect {
        let full = CGRect(origin: .zero, size: size)
        switch layout {
        case .fullCall?:
            return selfWindowRect
        case .alignFirst?:
            return isRolling ? selfWindowRect : full
        case .fullFrame?:
            let available = size.height - bottomInset - 8
            let height = available * 0.64
            let width = height * 9 / 16
            return CGRect(x: (size.width - width) / 2, y: available - height, width: width, height: height)
        default:
            return full
        }
    }

    /// 視訊通話時，自己縮成右下角的 9:16 小窗。
    private var selfWindowRect: CGRect {
        let width = size.width * 0.28
        let height = width * 16 / 9
        return CGRect(x: size.width - 12 - width, y: size.height - bottomInset - 12 - height,
                      width: width, height: height)
    }

    /// 聆聽者放在哪裡、怎麼裁。
    private struct CompanionPlacement {
        /// 轉正之前的大小。
        var size: CGSize
        var center: CGPoint
        var radius: CGFloat
        var crop: CompanionView.Crop = .top
        /// 墊在自己的畫面底下（滿版）。
        var isBackdrop = false
    }

    private func placement(_ layout: CompanionLayout) -> CompanionPlacement {
        switch layout {
        case .circle, .topCard:
            let isCircle = layout == .circle
            let width: CGFloat = isCircle ? min(size.width * 0.34, 150) : min(size.width * 0.30, 128)
            let height: CGFloat = isCircle ? width : width * 16 / 9
            // 橫放時整個轉 90 度，佔的高度是原本的寬。
            let visualHeight = angle == 0 ? height : width
            return CompanionPlacement(size: CGSize(width: width, height: height),
                                      center: CGPoint(x: size.width / 2, y: 12 + visualHeight / 2),
                                      radius: isCircle ? width / 2 : 16,
                                      crop: isCircle ? .face : .top)
        case .eyeStrip:
            let height = size.height * Self.eyeStripHeight
            return CompanionPlacement(size: CGSize(width: size.width * 0.62, height: height),
                                      center: CGPoint(x: size.width / 2, y: 8 + height / 2),
                                      radius: 20, crop: .eyes)
        case .fullFrame:
            let cam = cameraRect
            let height = max(1, cam.minY - 16)
            return CompanionPlacement(size: CGSize(width: cam.width, height: height),
                                      center: CGPoint(x: size.width / 2, y: 8 + height / 2),
                                      radius: 14)
        case .fullCall, .alignFirst:
            return CompanionPlacement(size: size, center: CGPoint(x: size.width / 2, y: size.height / 2),
                                      radius: 0, isBackdrop: true)
        }
    }

    /// 眼神條的高度（佔畫面高度的比例）。
    private static let eyeStripHeight: CGFloat = 0.12

    /// 提詞已經開始了。
    private var prompting: Bool {
        // 重點不會捲，開錄就算開始了。
        if settings.usesPrompter && isPoint { return isRolling }
        // 不讀 offset：它每一格都在變、沒有發布，讀了也不會跟著重畫。hasStarted 只在 0 和大於 0 之間切換時發布。
        return settings.usesPrompter && (prompter.isPlaying || prompter.hasStarted)
    }

    /// 有稿件時，頭像框只在開始提詞前顯示供對位；提詞開始後淡出。
    private var showHeadGuide: Bool {
        settings.guideStyle == .head && !prompting
    }

    private var showGridGuide: Bool {
        settings.guideStyle == .grid
    }

    /// 九宮格在提詞開始後留著，濃淡降一半。
    private var gridStrength: Double {
        prompting ? settings.guideOpacity / 2 : settings.guideOpacity
    }

    /// 頭像框上方要讓開多少（佔畫面高度的比例）。
    private var guideTopReserve: CGFloat {
        let usual: CGFloat = 0.06
        guard let layout, size.height > 0 else { return usual }
        switch layout {
        case .eyeStrip:
            return Self.eyeStripHeight + 0.02
        case .circle, .topCard:
            // 橫放時聆聽者在使用者看到的左側中間，離置中的頭像框還有一段，不會蓋到，不用往下讓。
            guard angle == 0 else { return usual }
            let place = placement(layout)
            return (place.center.y + place.size.height / 2 + 8) / size.height
        case .fullCall, .fullFrame, .alignFirst:
            // 自己的畫面和聆聽者沒有上下重疊。
            return usual
        }
    }

    var body: some View {
        layers
            .onChange(of: hidesSelf) { _, on in
                if on {
                    selfView.start(faces: camera.faces)
                } else {
                    selfView.stop()
                }
            }
            .onChange(of: cameraRect.size, initial: true) { _, value in
                selfView.frame = value
            }
            .onChange(of: angle, initial: true) { _, value in
                selfView.upright = value == 0
            }
            // 看不到自己的時候，相機就不畫處理過的預覽，省 GPU。停止錄影時 hidesSelf 變 false，這裡也會叫回來。
            .task(id: selfHidden) { [hidden = selfHidden] in
                guard hidden else {
                    camera.setPreviewHidden(false)
                    return
                }
                // 等淡出跑完再停，不然淡出那半秒畫面會定住。中途又淡回來，這個 task 會被取消。
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !Task.isCancelled { camera.setPreviewHidden(true) }
            }
            .onDisappear {
                selfView.stop()
                camera.setPreviewHidden(false)
            }
    }

    private var layers: some View {
        ZStack(alignment: .top) {
            cameraLayer

            if let layout {
                companionLayer(placement(layout))
            }

            guideLayers

            if settings.usesPrompter {
                promptLayers
            }

            jumpNoteLayer

            noticeLayers
        }
        .animation(.easeInOut(duration: 0.3), value: showHeadGuide)
        .animation(.easeInOut(duration: 0.3), value: showGridGuide)
        .animation(.easeInOut(duration: 0.3), value: gridStrength)
    }

    /// 構圖線，畫在自己的畫面上。
    @ViewBuilder
    private var guideLayers: some View {
        let cam = cameraRect
        if showHeadGuide {
            FramingGuideView(faces: camera.faces, scale: CGFloat(settings.guideScale), angle: angle,
                             topReserve: guideTopReserve, strength: settings.guideOpacity)
                .turned(angle, width: cam.width, height: cam.height)
                .position(x: cam.midX, y: cam.midY)
                .opacity(selfHidden ? 0 : 1)
                .animation(selfFade, value: selfHidden)
                .transition(.opacity)
                .zIndex(2)
        }
        if showGridGuide {
            GridGuideView(strength: gridStrength)
                .frame(width: cam.width, height: cam.height)
                .position(x: cam.midX, y: cam.midY)
                .opacity(selfHidden ? 0 : 1)
                .animation(selfFade, value: selfHidden)
                .transition(.opacity)
                .zIndex(2)
        }
    }

    @ViewBuilder
    private var promptLayers: some View {
        if isPoint {
            pointLayer
        } else {
            prompterLayer
        }
    }

    private var pointLayer: some View {
        PromptPointView(model: prompter, text: text, fontSize: CGFloat(settings.fontSize),
                        backgroundOpacity: settings.promptBackground,
                        onTapOffset: onTapOffset, onScrolls: onPointScrolls)
            .turned(angle, width: size.width * 0.84,
                    height: PromptBand.height(previewHeight: size.height, angle: angle))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.top, PromptBand.top)
            .zIndex(3)
    }

    private var prompterLayer: some View {
        TeleprompterView(
            model: prompter,
            text: text,
            fontSize: CGFloat(settings.fontSize),
            backgroundOpacity: settings.promptBackground,
            onTapOffset: onTapOffset
        )
        .turned(angle, width: size.width * 0.84, height: PromptBand.height(previewHeight: size.height, angle: angle))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.top, PromptBand.top)
        .zIndex(3)
    }

    /// 跳轉後的小膠囊，畫面中央偏上。橫放時「上」是手機的右邊（90）或左邊（-90），而且要讓開提詞那一欄。
    private var jumpNoteLayer: some View {
        let x: CGFloat = angle == 0 ? 0.5 : (angle > 0 ? 0.72 : 0.28)
        let y: CGFloat = angle == 0 ? 0.40 : 0.64
        return ZStack {
            if let jumpNote {
                Text(jumpNote)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.65), in: Capsule())
                    .transition(.opacity)
            }
        }
        .rotationEffect(.degrees(angle))
        .animation(.easeInOut(duration: 0.2), value: jumpNote)
        .position(x: size.width * x, y: size.height * y)
        .allowsHitTesting(false)
        .zIndex(5)
    }

    /// 倒數、接片中、相機中斷。
    @ViewBuilder
    private var noticeLayers: some View {
        if case .countdown(let remaining) = phase {
            Text("\(remaining)")
                .font(.system(size: 120, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 8)
                .rotationEffect(.degrees(angle))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(6)
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
            .zIndex(6)
        }

        if camera.interruptionText == nil, let note = camera.micNotice {
            Label(note, systemImage: "mic.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 40)
                .rotationEffect(.degrees(angle))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .zIndex(6)
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
                .zIndex(6)
        }
    }

    /// 前鏡頭預覽從頭到尾是同一個 view，換擺法只改外框。前後順序用 zIndex 調，不搬動 view。
    private var cameraLayer: some View {
        let cam = cameraRect
        let isFull = cam.size == size
        let shape = RoundedRectangle(cornerRadius: isFull ? 0 : 14, style: .continuous)
        return CameraPreviewView(camera: camera)
            .frame(width: cam.width, height: cam.height)
            .clipShape(shape)
            .overlay(shape.stroke(Color.white.opacity(isFull ? 0 : 0.3), lineWidth: 1))
            // 預覽層不拆也不藏，臉的位置要繼續算。完全透明的 view 系統會當成看不到，
            // 音量鍵和遙控器的快門就收不到，所以留一點點。
            .opacity(selfHidden ? 0.012 : 1)
            .animation(selfFade, value: selfHidden)
            .position(x: cam.midX, y: cam.midY)
            .zIndex(1)
    }

    private func companionLayer(_ place: CompanionPlacement) -> some View {
        let shape = RoundedRectangle(cornerRadius: place.radius, style: .circular)
        return CompanionView(player: clipPlayer, crop: place.crop)
            .frame(width: place.size.width, height: place.size.height)
            .clipShape(shape)
            .overlay(shape.stroke(Color.white.opacity(place.isBackdrop ? 0 : 0.2), lineWidth: 1))
            .rotationEffect(.degrees(angle))
            .position(place.center)
            .allowsHitTesting(false)
            .zIndex(place.isBackdrop ? 0 : 4)
    }
}

// MARK: - 計時與收音狀態

private struct StatusRow: View {
    @EnvironmentObject private var camera: CameraService
    @EnvironmentObject private var settings: SettingsStore
    let phase: RecordingViewModel.Phase
    let elapsed: TimeInterval
    let estimate: TimeInterval?
    /// 待機時才能切換看多少字、有沒有人聽。
    let canSwitchMode: Bool
    /// 手機現在橫放，會錄 16:9。
    let sideways: Bool
    @Binding var showModes: Bool
    @State private var showRatioInfo = false

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

            MicIndicator(meter: camera.meter, route: camera.micRoute)
                .onLongPressGesture(minimumDuration: 1.0) {
                    settings.showDebug.toggle()
                }

            if canSwitchMode {
                Button {
                    showModes = true
                } label: {
                    modeLabel
                }
                .buttonStyle(.plain)
                .accessibilityLabel(modeName)

                ratioChip
            }
        }
        .alert(ratioTitle, isPresented: $showRatioInfo) {
            if settings.autoLandscape {
                Button("好") {}
            } else {
                Button("打開") { settings.autoLandscape = true }
                Button("先不要", role: .cancel) {}
            }
        } message: {
            Text(ratioMessage)
        }
    }

    // MARK: - 比例

    /// 現在會錄成什麼比例。還不知道可以橫著拍的人，多一句「橫拿錄 16:9」。
    private var ratioChip: some View {
        let hint: Bool = !sideways && settings.autoLandscape && !settings.landscapeHintDone
        return Button {
            settings.landscapeHintDone = true
            showRatioInfo = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: sideways ? "rectangle" : "rectangle.portrait")
                Text(sideways ? "16:9" : "9:16")
                    .fontWeight(.medium)
                if hint {
                    Text("橫拿錄 16:9")
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.55), in: Capsule())
            .contentShape(Rectangle().inset(by: -10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sideways ? "目前錄橫式 16:9" : "目前錄直式 9:16，手機橫過來可以錄 16:9")
    }

    private var ratioTitle: String {
        if sideways { return "現在錄橫式 16:9" }
        return settings.autoLandscape ? "想錄橫的 16:9？" : "橫式錄影關掉了"
    }

    private var ratioMessage: String {
        if sideways { return "手機直放就回到直式 9:16。" }
        if settings.autoLandscape {
            return "把手機橫過來架好，錄出來就是 16:9，適合放 YouTube。提詞會變成貼著鏡頭的一直欄。"
        }
        return "打開之後，手機橫過來架就會錄 16:9。設定裡的「手機橫放時錄橫式影片」也可以開關。"
    }

    /// 看多少字；有聆聽者就亮起來。
    private var modeLabel: some View {
        let listening: Bool = settings.hasListener
        let fill: Color = listening ? Theme.accent : Color.black.opacity(0.55)
        return HStack(spacing: 5) {
            Image(systemName: settings.promptAmount.symbol)
            if listening {
                Image(systemName: "person.wave.2.fill")
            }
            Text(settings.promptAmount.label)
                .fontWeight(.medium)
        }
        .font(.caption)
        .foregroundStyle(listening ? Color.black : Color.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(fill, in: Capsule())
        .contentShape(Rectangle().inset(by: -10))
    }

    private var modeName: String {
        "選擇模式，目前是\(settings.promptAmount.label)，\(settings.hasListener ? "有人聽" : "沒有人聽")"
    }

    static func format(_ time: TimeInterval) -> String {
        let total = Int(time)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// 簡單的收音狀態：音量條會動代表有收到聲音；完全沒訊號才提示。
private struct MicIndicator: View {
    @ObservedObject var meter: SpeechActivityMonitor
    /// 外接麥才在旁邊寫名字；藍牙是電話音質，用黃字提醒。
    let route: MicRoute

    private var accessibilityText: String {
        let source = route.kind.isExternal ? "收音用\(route.name)" : "收音用手機麥克風"
        let quality = route.isPhoneQuality ? "，藍牙是電話音質" : ""
        return meter.micStatus == .noSignal ? "\(source)，沒有偵測到聲音" : source + quality
    }

    private var fraction: CGFloat {
        // -60 dB…0 dB 對應到 0…1
        let clamped = min(0, max(-60, CGFloat(meter.level)))
        return (clamped + 60) / 60
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: meter.micStatus == .noSignal ? "mic.slash.fill" : (route.kind.isExternal ? "mic.badge.plus" : "mic.fill"))
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
                if let badge = route.badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 120)
                        .foregroundStyle(route.isPhoneQuality ? Color.yellow : Color.white)
                }
            }
        }
        .foregroundStyle(meter.micStatus == .noSignal ? Color.yellow : Color.white)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
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

    private var isOff: Bool {
        settings.promptAmount == PromptAmount.none
    }

    /// 有字而且會捲。重點是靜止的，播放和回開頭用不到。
    private var scrolls: Bool {
        settings.usesPrompter && !viewModel.currentIsPoint
    }

    /// 放不下的重點是用手捲的，也要能一下回到開頭。
    private var rewinds: Bool {
        settings.usesPrompter && viewModel.currentScrolls
    }

    var body: some View {
        HStack(spacing: 0) {
            BarButton(title: "腳本", systemImage: "doc.text", angle: angle) {
                showScript = true
            }
            .disabled(viewModel.isBusy || isOff)
            .opacity(isOff ? 0 : (viewModel.isBusy ? 0.35 : 1))
            // 看不見的鍵也不要讓旁白念到。位置照留，左右的鍵才不會移位。
            .accessibilityHidden(isOff)

            BarButton(title: prompter.isPlaying ? "暫停" : "提詞",
                      systemImage: prompter.isPlaying ? "pause.fill" : "play.fill", angle: angle) {
                viewModel.togglePrompter()
            }
            .opacity(scrolls ? 1 : 0)
            .disabled(!scrolls)
            .accessibilityHidden(!scrolls)

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
            .opacity(rewinds ? 1 : 0)
            .disabled(!rewinds)
            .accessibilityHidden(!rewinds)

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

    /// 提綱是用自己的話講，照字數估不準。
    private var showsEstimate: Bool {
        settings.promptAmount != .outline && !viewModel.currentIsPoint
    }

    private var canStep: Bool {
        !viewModel.isBusy && viewModel.pending == nil
    }

    /// 留用這段之後是不是就全部錄完了。
    private var isLastMissing: Bool {
        let recorded = Set(viewModel.takes.keys).union([viewModel.currentIndex])
        return recorded.count == viewModel.pieces.count
    }

    private var canGoBack: Bool {
        canStep && viewModel.currentIndex > 0
    }

    private var canGoForward: Bool {
        canStep && viewModel.currentIndex < viewModel.pieces.count - 1
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
                    Text("第 \(viewModel.currentIndex + 1)／\(viewModel.pieces.count) 段")
                        .font(.subheadline.weight(.semibold))
                    if showsEstimate {
                        Text(estimateText)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                            .monospacedDigit()
                    }
                    if viewModel.currentHasTake && viewModel.pending == nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Theme.good)
                    }
                    if let note = viewModel.currentCheckNote {
                        // 錄好了的勾不可以讓人以為檢查過。
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.yellow)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)

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

            if let entry = viewModel.pendingCheck {
                TakeCheckCard(entries: [entry], sendsAudioOut: viewModel.checker.sendsAudioOut,
                              maxRows: TakeCheckCard.compactRows) { _, issue in
                    viewModel.openPendingCheck(issue)
                }
            }

            if viewModel.showsCheckSending {
                HStack(spacing: 8) {
                    Text("檢查中")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                    CaptionNetworkLine()
                }
            }

            flags

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

    /// 留用了但檢查出東西的段落，點了跳過去聽。
    @ViewBuilder
    private var flags: some View {
        let list: [TakeCheckFlag] = viewModel.checkFlags
        if !list.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(list) { flag in
                        Button {
                            viewModel.openSegmentCheck(flag.index)
                        } label: {
                            flagLabel(flag)
                        }
                    }
                }
            }
            .frame(height: 44)
        }
    }

    private func flagLabel(_ flag: TakeCheckFlag) -> some View {
        Label(flag.text, systemImage: "exclamationmark.circle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.yellow)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
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
