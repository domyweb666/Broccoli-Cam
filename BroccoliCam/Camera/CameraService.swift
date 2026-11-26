import AVFoundation
import UIKit

/// 前鏡頭、預覽、錄影、格式、權限、中斷處理。
/// 所有 session 操作都在 sessionQueue，不在主執行緒做重工作。
/// 影格走 FramePipeline（逐格處理、預覽），寫檔走 FrameRecorder。
final class CameraService: NSObject, ObservableObject {
    enum Authorization {
        case unknown
        case authorized
        case denied
    }

    @Published private(set) var authorization: Authorization = .unknown
    @Published private(set) var isSessionRunning = false
    @Published private(set) var isRecording = false
    /// isRecording 講的是哪一個檔。比 isRecording 早更新（主執行緒）。
    private(set) var recordingURL: URL?
    @Published private(set) var availableResolutions: [VideoResolution] = [.hd1080]
    @Published private(set) var availableFPS: [VideoResolution: [Int]] = [.hd1080: [30]]
    /// 目前格式支援的防抖強度，一定含 .off。
    @Published private(set) var availableStabilizations: [StabilizationLevel] = [.off]
    @Published private(set) var activeFormatText = "—"
    @Published private(set) var interruptionText: String?
    /// 現在用哪支麥克風、幾聲道。
    @Published private(set) var micRoute = MicRoute()
    /// 麥克風剛插拔時跳的一句，幾秒後自己消失。
    @Published private(set) var micNotice: String?
    @Published private(set) var lastError: String?
    @Published private(set) var logLines: [String] = []

    let session = AVCaptureSession()
    let faces = FaceDetectionService()
    let meter = SpeechActivityMonitor()

    /// 這次錄影的第一格畫面，比 isRecording 變成 true 早了幾秒。
    /// 開防抖時影格會晚幾百毫秒才送到，用錄影時間推算影片裡的位置時要加上這個值。
    /// 在 isRecording 變成 true 之前就會更新（主執行緒）。
    private(set) var recordingLag: TimeInterval = 0

    /// 錄影檔完成（主執行緒回呼）。
    /// 第二個值有東西代表中途出過狀況，檔案只救回一部分。
    var onRecordingFinished: ((URL, String?) -> Void)?
    /// 錄影失敗：要寫的檔和原因（主執行緒回呼）。檔案可能還在。
    var onRecordingFailed: ((URL, String) -> Void)?
    /// 音量鍵或藍牙遙控器被按下（主執行緒回呼）。
    var onCaptureButton: (() -> Void)?

    /// 語音跟隨要聽的音訊。在音訊佇列上被呼叫，設定與讀取都有鎖。
    var audioSampleHandler: ((CMSampleBuffer) -> Void)? {
        get {
            audioTapLock.lock()
            defer { audioTapLock.unlock() }
            return storedAudioSampleHandler
        }
        set {
            audioTapLock.lock()
            storedAudioSampleHandler = newValue
            audioTapLock.unlock()
        }
    }

    private let sessionQueue = DispatchQueue(label: "org.domyweb.broccolicam.session")
    private let metadataQueue = DispatchQueue(label: "org.domyweb.broccolicam.metadata")
    private let analysisQueue = DispatchQueue(label: "org.domyweb.broccolicam.analysis", qos: .userInitiated)
    private let pipeline = FramePipeline()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    /// 音訊一律從這裡出來：錄影、音量、語音跟隨三家共用。
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private let audioQueue = DispatchQueue(label: "org.domyweb.broccolicam.audio")
    private let audioLevel = AudioLevelTap()
    private let audioTapLock = NSLock()
    private var storedAudioSampleHandler: ((CMSampleBuffer) -> Void)?
    private var audioPacketCount = 0
    /// 最近一包聲音的格式（除錯層用），audioTapLock 保護。
    private var lastAudioChannels = 0
    private var lastAudioRate: Double = 0
    /// 語音辨識一律拿單聲道、格式不變的聲音：雙聲道會混成一軌，錄到一半換麥也轉回原本的格式。只在 audioQueue 用。
    private let speechKeeper = AudioFormatKeeper(channels: 1)
    /// 挑麥克風、設音訊。只在 sessionQueue 用。
    private let router = AudioRouter()
    /// 錄影中接上、錄完才換的那支。sessionQueue 讀寫。
    private var micWaitingFor: String?
    /// 這段錄影開始時用的麥克風。sessionQueue 讀寫。
    private var recordingMicName: String?
    /// 上次看到在用的麥克風，換了才跳提示。sessionQueue 讀寫。
    private var lastSeenMicName: String?
    /// 錄影中換過麥克風的段落，錄完交給完成頁講。micNoteLock 保護。
    private let micNoteLock = NSLock()
    private var micNotes: [URL: String] = [:]
    private var micNoticeRun = 0
    private var videoDevice: AVCaptureDevice?
    private var isConfigured = false
    /// 現在該不該開著：start 之後、stop 之前。完成頁和校對頁開著時是 false。sessionQueue 讀寫。
    private var wantsRunning = false
    private var desiredResolution: VideoResolution = .hd1080
    private var desiredFPS = 30
    private var desiredStabilization: StabilizationLevel = .off
    private var mirrorOutput = false
    /// 目前格式實際的幀率，sessionQueue 讀寫。
    private var activeFPS = 30
    /// 上次要求的曝光補償，sessionQueue 讀寫。裝置讀回來的值會慢慢變、也會四捨五入，拿來比會一直重設。
    private var lastRequestedBias: Float?

    /// 第幾次開錄。畫面那邊等太久放棄了就換號，還在排隊的那次不會突然自己錄起來。
    private let startLock = NSLock()
    private var startRun = 0

    // 畫面優化。lookLock 保護這一組。
    private let lookLock = NSLock()
    private var look = LookParams.neutral
    private var lookEnabled = false
    /// 一鍵優化時把測光移到的位置（裝置座標）。nil 是中央。
    private var meteringPoint: CGPoint?
    /// 正在跑的一鍵優化是第幾次。nil 代表沒在跑，或已經被取消。
    private var optimizeRun: Int?
    private var optimizeCount = 0
    private var exposureApplyQueued = false

    // 主執行緒用
    private var metalPreviewOn = false
    private var onMetalPreview: ((Bool) -> Void)?
    /// 錄影期間向系統多要一點背景時間，來電或切走時檔案才收得完。
    private var recordingTask: UIBackgroundTaskIdentifier = .invalid
    private var lastFaceUIUpdate: CFTimeInterval = 0

    /// metadataQueue 用
    private var lastFaceUpdate: CFTimeInterval = 0
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    /// 依裝置問出正確的旋轉角度。iPhone 17 的前鏡頭感光元件裝的方向和舊機型差 90 度，
    /// 不能寫死 90 度。只在主執行緒建立與讀取。
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var captureObservation: NSKeyValueObservation?
    /// 影格連線的角度（一律是直式），sessionQueue 讀寫。
    private var captureRotationAngle: CGFloat = 90
    /// 上次交給 sessionQueue 的角度，主執行緒用。
    private var lastSentAngle: CGFloat = 90
    /// 最近一次手機橫放時，錄影角度和直式差幾度（±90）。主執行緒用。
    private var lastLandscapeTurn: Int?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    override init() {
        super.init()
        meter.levelProvider = { [weak self] in
            self?.audioLevel.current()
        }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(sessionWasInterrupted(_:)),
                       name: AVCaptureSession.wasInterruptedNotification, object: session)
        nc.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                       name: AVCaptureSession.interruptionEndedNotification, object: session)
        nc.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                       name: AVCaptureSession.runtimeErrorNotification, object: session)
        nc.addObserver(self, selector: #selector(audioRouteChanged(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(appEnteredBackground(_:)),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appWillEnterForeground(_:)),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
        // 要先讀過一次溫度狀態，系統才會發通知。
        updateThermalLimit()
        nc.addObserver(self, selector: #selector(thermalStateChanged(_:)),
                       name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        pipeline.onTooSlow = { [weak self] in
            self?.log("影格來不及處理，這段先略過降噪和柔膚")
        }
        router.onLog = { [weak self] text in
            self?.log(text)
        }
        refreshAuthorization()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 權限

    func refreshAuthorization() {
        let video = AVCaptureDevice.authorizationStatus(for: .video)
        let audio = AVCaptureDevice.authorizationStatus(for: .audio)
        let blocked: (AVAuthorizationStatus) -> Bool = { $0 == .denied || $0 == .restricted }
        if blocked(video) || blocked(audio) {
            authorization = .denied
        } else if video == .authorized && audio == .authorized {
            authorization = .authorized
        } else {
            authorization = .unknown
        }
    }

    func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    self.refreshAuthorization()
                }
            }
        }
    }

    // MARK: - Session 生命週期

    /// 啟動（或以新設定重新套用）相機。錄影中呼叫只會更新設定值，不會改格式。請在主執行緒呼叫。
    func start(resolution: VideoResolution, fps: Int, mirrorOutput: Bool,
               stabilization: StabilizationLevel = .off) {
        let coordinatorReady = rotationCoordinator != nil
        let heldSideways = UIDevice.current.orientation.isLandscape
        let knownAngle = currentCaptureAngle()
        lastSentAngle = knownAngle
        sessionQueue.async {
            self.wantsRunning = true
            self.desiredResolution = resolution
            self.desiredFPS = fps
            self.mirrorOutput = mirrorOutput
            self.desiredStabilization = stabilization
            if !self.isConfigured {
                self.configureSession()
            }
            guard self.isConfigured else { return }
            var angle = knownAngle
            if !coordinatorReady, !heldSideways, let probed = self.probePortraitAngle() {
                angle = probed
                DispatchQueue.main.async {
                    if self.rotationCoordinator == nil { self.lastSentAngle = probed }
                }
            }
            if !self.pipeline.isRecording {
                self.captureRotationAngle = angle
                self.session.beginConfiguration()
                self.applyFormat()
                self.updateConnections()
                self.session.commitConfiguration()
                // 換格式會把曝光補償和測光點洗掉，補回來。
                self.applyLookToDevice()
                // 完成頁、校對頁會把音訊切成播放，回來要切回錄影用。
                self.applyAudioRoute()
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            let running = self.session.isRunning
            DispatchQueue.main.async {
                self.isSessionRunning = running
                self.setUpRotationCoordinator()
                self.applyPreviewRotation()
                self.schedulePreviewRotationRetries()
                self.refreshMetalPreview()
                if running { self.meter.start() }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            self.wantsRunning = false
            // 先把檔案收好，再停相機。
            self.finishRecordingNow()
            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async {
                self.isSessionRunning = false
                self.meter.stop()
                self.faces.update(nil)
            }
        }
    }

    // MARK: - 麥克風

    /// 這支手機的系統有沒有 AirPods 高品質收音。
    static var supportsBluetoothHQ: Bool { AudioRouter.supportsBluetoothHQ }

    /// 換收音設定。錄影中只記下來，停下來才套用，不然錄到一半聲音會斷。
    func setMicPreferences(_ preferences: AudioRouter.Preferences) {
        sessionQueue.async {
            guard self.router.preferences != preferences else { return }
            self.router.preferences = preferences
            self.applyAudioRoute()
        }
    }

    /// 請在 sessionQueue 呼叫。把音訊設成錄影用、挑麥克風。相機沒在用（完成頁、校對頁開著）或錄影中不動。
    private func applyAudioRoute() {
        guard isConfigured, wantsRunning, !pipeline.isRecording else {
            publishMicRoute()
            return
        }
        router.activate()
        router.applyChoice(recording: false)
        micWaitingFor = nil
        publishMicRoute()
    }

    /// sessionQueue 呼叫。
    private func publishMicRoute() {
        let route = router.snapshot(waitingFor: micWaitingFor)
        DispatchQueue.main.async {
            if self.micRoute != route { self.micRoute = route }
        }
    }

    /// 跳一句麥克風的提示，幾秒後自己收掉。任何執行緒都能呼叫。
    private func showMicNotice(_ text: String) {
        log(text)
        DispatchQueue.main.async {
            self.micNoticeRun += 1
            let run = self.micNoticeRun
            self.micNotice = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if self.micNoticeRun == run { self.micNotice = nil }
            }
        }
    }

    /// 錄影中換過麥克風的話，那段的說明（拿一次就清掉）。主執行緒呼叫。
    func takeMicNote(for url: URL) -> String? {
        micNoteLock.lock()
        defer { micNoteLock.unlock() }
        return micNotes.removeValue(forKey: url)
    }

    private func noteMicChange(_ text: String, for url: URL) {
        micNoteLock.lock()
        if micNotes[url] == nil { micNotes[url] = text }
        micNoteLock.unlock()
    }

    /// 除錯層用的一行。
    private func bluetoothHQText() -> String {
        guard Self.supportsBluetoothHQ else { return "系統不支援" }
        return micRoute.bluetoothHQ ? "開" : "關"
    }

    // MARK: - 預覽

    /// 給預覽 view 掛圖層用。
    var previewRenderer: MetalPreviewRenderer { pipeline.renderer }

    /// 預覽 view 登記：需要（或不再需要）疊上處理過的畫面時會被呼叫。請在主執行緒呼叫。
    func attachMetalPreview(_ handler: @escaping (Bool) -> Void) {
        onMetalPreview = handler
        metalPreviewOn = pipeline.needsMetalPreview
        handler(metalPreviewOn)
    }

    /// 畫面把預覽淡到幾乎看不見（「不看自己」）時呼叫 true，回來時呼叫 false。請在主執行緒呼叫。
    /// 只停掉處理過的預覽（Metal）那層的繪製，錄影、臉部偵測、音量、音量鍵快門都照舊；
    /// 改回 false 後下一格影格就會重新畫。Metal 圖層本身不拿掉，回來時不用重新掛、不會黑一下。
    func setPreviewHidden(_ hidden: Bool) {
        pipeline.setPreviewHidden(hidden)
    }

    /// 有逐格處理或有開防抖才疊上處理過的畫面，不然直接看原生預覽。
    private func refreshMetalPreview() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let needed = self.pipeline.needsMetalPreview
            guard needed != self.metalPreviewOn else { return }
            self.metalPreviewOn = needed
            self.onMetalPreview?(needed)
        }
    }

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        rotationCoordinator = nil
        setUpRotationCoordinator()
        applyPreviewRotation()
    }

    /// 相機和預覽層都就緒後建立 RotationCoordinator，角度變了就重新套用。請在主執行緒呼叫。
    private func setUpRotationCoordinator() {
        guard rotationCoordinator == nil, let device = videoDevice, let layer = previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.applyPreviewRotation()
            }
        }
        captureObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.noteLandscapeTurn()
            }
        }
        log("旋轉協調器 預覽=\(Int(coordinator.videoRotationAngleForHorizonLevelPreview)) 錄影=\(Int(coordinator.videoRotationAngleForHorizonLevelCapture))")
    }

    /// 預覽應該轉幾度。沒有協調器時退回舊機型的 90 度。
    private func currentPreviewAngle() -> CGFloat {
        rotationCoordinator?.videoRotationAngleForHorizonLevelPreview ?? 90
    }

    /// 影格應該轉幾度。App 鎖直式，所以用預覽的角度，不跟著手機傾斜改變。
    private func currentCaptureAngle() -> CGFloat {
        guard let coordinator = rotationCoordinator else { return 90 }
        return coordinator.videoRotationAngleForHorizonLevelPreview
    }

    /// 預覽層還沒好之前，先問這支手機直拿時影格要轉幾度。
    /// iPhone 17 是 0 度，用預設的 90 度開錄會錄成側的。請在 sessionQueue 呼叫。
    private func probePortraitAngle() -> CGFloat? {
        guard let device = videoDevice else { return nil }
        let probe = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        let angle = probe.videoRotationAngleForHorizonLevelCapture
        // 拿著的角度不明時可能回橫的值，直式只會是這兩個。
        return angle == 0 || angle == 90 ? angle : nil
    }

    /// 手機橫放時錄影應該轉幾度：跟著手機實際的擺法（重力方向）。
    private func currentLandscapeAngle() -> CGFloat {
        guard let coordinator = rotationCoordinator else { return 90 }
        return coordinator.videoRotationAngleForHorizonLevelCapture
    }

    /// 橫式錄影時，直式影格還要再順時針轉幾度：+90、-90，或 0（問不到）。請在主執行緒呼叫。
    ///
    /// videoRotationAngle 是「感光元件的畫面要順時針轉幾度」。直式影格 = 轉了直式角度，
    /// 橫式成品 = 轉橫式角度，所以差值就是還要再轉的角度。
    /// 舊機型直式 90、橫式 180／0；iPhone 17 直式 0、橫式 90／270，差值都是 +90／-90。
    private func currentLandscapeTurn() -> Int {
        noteLandscapeTurn()
        // 手機快要平放時重力判斷和 UIDevice 的方向會不一致，用最近一次橫放的方向。
        return lastLandscapeTurn ?? 0
    }

    /// 現在是橫放的話，記下差幾度。
    private func noteLandscapeTurn() {
        let turn = Self.normalizedTurn(currentLandscapeAngle() - currentCaptureAngle())
        if turn == 90 || turn == -90 {
            lastLandscapeTurn = turn
        }
    }

    /// 收成 -90、0、90、180。
    private static func normalizedTurn(_ degrees: CGFloat) -> Int {
        let quarter = Int((degrees / 90).rounded())
        let steps = ((quarter % 4) + 4) % 4
        return steps == 3 ? -90 : steps * 90
    }

    /// 把預覽轉成直式。請在主執行緒呼叫。
    /// 預覽層的連線要等 session 設定完才會出現，所以會被多處重複呼叫：
    /// 掛上預覽層、session 啟動後、預覽 view 重新排版、中斷結束。
    func applyPreviewRotation() {
        syncCaptureAngle()
        guard let connection = previewLayer?.connection else {
            notePreviewRotation("預覽連線還沒建立")
            return
        }
        Self.apply(currentPreviewAngle(), to: connection)
        notePreviewRotation("預覽旋轉=\(Int(connection.videoRotationAngle))")
    }

    /// 影格連線的角度跟著預覽走。RotationCoordinator 要等預覽層和相機都好了才問得到，
    /// 第一次啟動時可能先用了預設的 90 度，這裡補正。
    private func syncCaptureAngle() {
        let angle = currentCaptureAngle()
        guard angle != lastSentAngle else { return }
        let previous = lastSentAngle
        lastSentAngle = angle
        sessionQueue.async {
            guard self.isConfigured, !self.pipeline.isRecording else {
                // 這次沒套到，記回原本的值，錄完會再補。
                DispatchQueue.main.async {
                    if self.lastSentAngle == angle { self.lastSentAngle = previous }
                }
                return
            }
            self.captureRotationAngle = angle
            self.updateConnections()
        }
    }

    /// session 剛啟動的頭幾秒再補套幾次，避免連線建立得比較晚而漏掉。
    private func schedulePreviewRotationRetries() {
        for delay in [0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.applyPreviewRotation()
            }
        }
    }

    private var lastPreviewRotationNote = ""

    /// 狀態有變才寫進紀錄，避免洗版。
    private func notePreviewRotation(_ text: String) {
        guard text != lastPreviewRotationNote else { return }
        lastPreviewRotationNote = text
        log(text)
    }

    /// 把連線轉到指定角度；不支援時不動。
    private static func apply(_ angle: CGFloat, to connection: AVCaptureConnection) {
        guard connection.isVideoRotationAngleSupported(angle) else { return }
        if connection.videoRotationAngle != angle {
            connection.videoRotationAngle = angle
        }
    }

    // MARK: - 設定

    private func configureSession() {
        session.beginConfiguration()
        // 音訊自己管：要能挑外接麥、要能錄雙聲道，相機自動設定的音訊做不到。
        // 音訊 session 等設定完、開相機前才切（start 裡的 applyAudioRoute）。
        session.automaticallyConfiguresApplicationAudioSession = false
        // 全程 709 SDR，不要被系統切到廣色域。
        session.automaticallyConfiguresCaptureDeviceForWideColor = false

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            session.commitConfiguration()
            fail("找不到前鏡頭")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                fail("無法加入相機輸入")
                return
            }
            session.addInput(input)
            videoDevice = camera
        } catch {
            session.commitConfiguration()
            fail("相機輸入錯誤：\(error.localizedDescription)")
            return
        }

        if let mic = AVCaptureDevice.default(for: .audio) {
            do {
                let input = try AVCaptureDeviceInput(device: mic)
                if session.canAddInput(input) {
                    session.addInput(input)
                } else {
                    log("無法加入麥克風輸入")
                }
            } catch {
                log("麥克風輸入錯誤：\(error.localizedDescription)")
            }
        } else {
            log("找不到麥克風")
        }

        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
        } else {
            session.commitConfiguration()
            fail("無法加入影格輸出")
            return
        }
        // 影格大小要跟格式一樣，不要被縮成預覽大小。
        videoDataOutput.automaticallyConfiguresOutputBufferDimensions = false
        videoDataOutput.deliversPreviewSizedOutputBuffers = false
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        choosePixelFormat()
        videoDataOutput.setSampleBufferDelegate(pipeline, queue: pipeline.videoQueue)

        if session.canAddOutput(audioDataOutput) {
            session.addOutput(audioDataOutput)
            audioDataOutput.setSampleBufferDelegate(self, queue: audioQueue)
        } else {
            log("無法加入音訊輸出，只能錄畫面")
        }

        // 臉部定位：相機內建的臉部中繼資料，不自己跑辨識。失敗時 App 仍可錄影。
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: metadataQueue)
            if metadataOutput.availableMetadataObjectTypes.contains(.face) {
                metadataOutput.metadataObjectTypes = [.face]
            } else {
                log("此裝置不支援臉部中繼資料")
            }
        } else {
            log("無法加入臉部偵測輸出")
        }

        session.commitConfiguration()
        isConfigured = true
        computeCapabilities(camera)
        log("相機設定完成")
        publishMicRoute()
    }

    /// 影格用 420v（和編碼器要的一樣，不用轉檔）。沒有就退而求其次。
    private func choosePixelFormat() {
        let available: [OSType] = videoDataOutput.availableVideoPixelFormatTypes
        let wanted: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA
        ]
        guard let type = wanted.first(where: { available.contains($0) }) ?? available.first else { return }
        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: type)]
    }

    private func computeCapabilities(_ device: AVCaptureDevice) {
        var map: [VideoResolution: [Int]] = [:]
        for resolution in VideoResolution.allCases {
            var list: [Int] = []
            for fps in [30, 60] where bestFormat(device: device, resolution: resolution, fps: fps) != nil {
                list.append(fps)
            }
            if !list.isEmpty {
                map[resolution] = list
            }
        }
        guard !map.isEmpty else {
            log("找不到 1080p／4K 格式，使用系統預設")
            return
        }
        let resolutions = VideoResolution.allCases.filter { map[$0] != nil }
        DispatchQueue.main.async {
            self.availableFPS = map
            self.availableResolutions = resolutions
        }
    }

    private func maxFrameRate(_ format: AVCaptureDevice.Format) -> Double {
        format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
    }

    /// 依實際可用格式挑選，不假設所有 iPhone 都有 4K／60。
    private func bestFormat(device: AVCaptureDevice, resolution: VideoResolution, fps: Int) -> AVCaptureDevice.Format? {
        let target = Double(fps)
        let candidates = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width == resolution.width, dims.height == resolution.height else { return false }
            let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            guard subType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    || subType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return false }
            return format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= target && target <= range.maxFrameRate
            }
        }
        return candidates.min { a, b in
            if a.isVideoBinned != b.isVideoBinned { return !a.isVideoBinned }
            return maxFrameRate(a) < maxFrameRate(b)
        }
    }

    private func applyFormat() {
        guard let device = videoDevice else { return }
        let attempts: [(VideoResolution, Int)] = [
            (desiredResolution, desiredFPS),
            (desiredResolution, 30),
            (.hd1080, desiredFPS),
            (.hd1080, 30)
        ]
        var chosen: (AVCaptureDevice.Format, Int)?
        for (resolution, fps) in attempts {
            if let format = bestFormat(device: device, resolution: resolution, fps: fps) {
                chosen = (format, fps)
                break
            }
        }
        // 格式由我們指定，不要讓 session 的 preset 又改回去。
        let preset: AVCaptureSession.Preset = chosen == nil ? .high : .inputPriority
        if session.sessionPreset != preset, session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
        }
        // 換格式會把曝光補償洗掉。
        lastRequestedBias = nil
        do {
            try device.lockForConfiguration()
            if let (format, fps) = chosen {
                if device.activeFormat != format {
                    device.activeFormat = format
                    pipeline.forgetFrameSize()
                }
                let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            // 用原生連續自動控制，不覆寫、不自製演算法。
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if device.activeColorSpace != .sRGB, device.activeFormat.supportedColorSpaces.contains(.sRGB) {
                device.activeColorSpace = .sRGB
            }
            device.unlockForConfiguration()
        } catch {
            log("格式設定失敗：\(error.localizedDescription)")
        }

        let active = device.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions(active.formatDescription)
        let fourCC = Self.fourCCString(CMFormatDescriptionGetMediaSubType(active.formatDescription))
        let actualFPS = chosen?.1 ?? Int(maxFrameRate(active))
        activeFPS = max(1, actualFPS)
        let text = "\(dims.width)x\(dims.height) @\(actualFPS)fps \(fourCC)（要求 \(desiredResolution.label)/\(desiredFPS)）"
        DispatchQueue.main.async {
            self.activeFormatText = text
        }
        log("格式 \(text)")
    }

    /// 影格連線的方向、鏡像、防抖。值沒變就不動，改了會讓畫面斷一下。錄影中不要呼叫。
    private func updateConnections() {
        guard let connection = videoDataOutput.connection(with: .video) else { return }
        Self.apply(captureRotationAngle, to: connection)
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            if connection.isVideoMirrored != mirrorOutput {
                connection.isVideoMirrored = mirrorOutput
            }
        }
        pipeline.setMirrored(connection.isVideoMirrored)
        applyStabilization(to: connection)
    }

    // MARK: - 防抖

    /// 設防抖並更新支援清單。設定裡選的強度這個格式不支援，就往下退。
    private func applyStabilization(to connection: AVCaptureConnection) {
        let standard = stabilizationMode(.standard, connection: connection)
        let strong = stabilizationMode(.strong, connection: connection)
        var levels: [StabilizationLevel] = [.off]
        if standard != nil { levels.append(.standard) }
        if strong != nil { levels.append(.strong) }

        let mode: AVCaptureVideoStabilizationMode
        switch desiredStabilization {
        case .off: mode = .off
        case .standard: mode = standard ?? .off
        case .strong: mode = strong ?? standard ?? .off
        }
        if connection.isVideoStabilizationSupported, connection.preferredVideoStabilizationMode != mode {
            connection.preferredVideoStabilizationMode = mode
            log("防抖 \(Self.stabilizationText(mode))")
        }
        pipeline.setStabilized(mode != .off)
        refreshMetalPreview()
        DispatchQueue.main.async {
            if self.availableStabilizations != levels {
                self.availableStabilizations = levels
            }
        }
    }

    /// 這個強度在目前格式上要用哪一種模式，不支援回 nil。
    private func stabilizationMode(_ level: StabilizationLevel,
                                   connection: AVCaptureConnection) -> AVCaptureVideoStabilizationMode? {
        guard connection.isVideoStabilizationSupported, let format = videoDevice?.activeFormat else { return nil }
        let candidates: [AVCaptureVideoStabilizationMode]
        switch level {
        case .off: candidates = [.off]
        case .standard: candidates = [.standard]
        case .strong: candidates = [.cinematicExtended, .cinematic]
        }
        return candidates.first { format.isVideoStabilizationModeSupported($0) }
    }

    private static func stabilizationText(_ mode: AVCaptureVideoStabilizationMode) -> String {
        if mode == .off { return "關" }
        if mode == .standard { return "標準" }
        if mode == .cinematic { return "電影" }
        if mode == .cinematicExtended { return "電影加強" }
        if mode == .auto { return "自動" }
        return "代碼 \(mode.rawValue)"
    }

    /// 設定裡選的強度在目前的格式上實際是哪一種。不支援就往下退，設定本身不動。
    func effectiveStabilization(_ wanted: StabilizationLevel) -> StabilizationLevel {
        if availableStabilizations.contains(wanted) { return wanted }
        if wanted == .strong, availableStabilizations.contains(.standard) { return .standard }
        return .off
    }

    // MARK: - 錄影

    /// 影格時間用的時鐘。
    private func captureTime() -> CMTime {
        #if targetEnvironment(simulator)
        // 模擬器的假相機自己編時間，和系統時鐘差很多，用最後一張影格往後推。
        if let now = pipeline.estimatedTime { return now }
        #endif
        return CMClockGetTime(session.synchronizationClock ?? CMClockGetHostTimeClock())
    }

    /// landscape：手機橫放，要錄成橫式 16:9。角度交給 RotationCoordinator 依手機實際的擺法決定。請在主執行緒呼叫。
    /// ready 在 sessionQueue 上呼叫，會等「這個檔已經記進清單」，回 false 就不錄。
    func startRecording(landscape: Bool, to url: URL, ready: @escaping () -> Bool) {
        // 一鍵優化跑到一半就開錄：不要讓它在錄影中動曝光。
        cancelOptimize()
        let run = nextStartRun()
        let turn = landscape ? currentLandscapeTurn() : 0
        if landscape {
            log("橫式錄影 再轉 \(turn) 度")
        }
        sessionQueue.async {
            guard self.isCurrentStart(run) else {
                self.log("開錄等太久，已經取消")
                return
            }
            guard self.isConfigured, self.session.isRunning, !self.session.isInterrupted else {
                self.log("相機尚未就緒，無法錄影")
                DispatchQueue.main.async { self.onRecordingFailed?(url, "相機還沒準備好，請再試一次") }
                return
            }
            guard !self.pipeline.isRecording else { return }
            guard ready() else {
                let text = "手機空間不夠，沒辦法開始錄"
                self.fail(text)
                DispatchQueue.main.async { self.onRecordingFailed?(url, text) }
                return
            }
            // 分析中動過的曝光和測光先還原。
            self.applyLookToDevice()
            do {
                let recorder = try self.makeRecorder(turn: turn, url: url)
                self.pipeline.setRecorder(recorder)
                recorder.start(at: self.captureTime())
            } catch {
                let text = "無法開始錄影：\(error.localizedDescription)"
                self.fail(text)
                DispatchQueue.main.async { self.onRecordingFailed?(url, text) }
            }
        }
    }

    /// 等太久，不錄這個檔了：還沒開始的取消，寫檔器已經建好的也收掉。
    func cancelStart(_ url: URL) {
        _ = nextStartRun()
        sessionQueue.async {
            guard let recorder = self.pipeline.recorder, recorder.isActive, recorder.url == url else { return }
            recorder.finishNow(at: self.captureTime())
        }
    }

    private func nextStartRun() -> Int {
        startLock.lock()
        defer { startLock.unlock() }
        startRun += 1
        return startRun
    }

    private func isCurrentStart(_ run: Int) -> Bool {
        startLock.lock()
        defer { startLock.unlock() }
        return startRun == run
    }

    func stopRecording() {
        // 按下去的那一刻就是結尾，晚到的影格（防抖）還會收到這個時間為止。
        let time = captureTime()
        sessionQueue.async {
            self.pipeline.recorder?.stop(at: time)
        }
    }

    /// 馬上把手上的檔案收好（中斷、進背景、相機要停）。任何執行緒都能呼叫；沒在錄就沒事。
    private func finishRecordingNow() {
        guard let recorder = pipeline.recorder, recorder.isActive else { return }
        log("錄影提前收尾")
        recorder.finishNow(at: captureTime())
    }

    /// 建立寫檔器。成品是正的影格，不靠 transform：直式 1080×1920，橫式 1920×1080。
    ///
    /// 鏡像時的轉向：影格 = 先轉直式角度、再左右鏡像。要的成品 = 先轉橫式角度、再左右鏡像。
    /// 鏡像前後夾住一個旋轉，等於反方向的旋轉（M·R(θ)·M = R(-θ)），所以鏡像時再轉的方向要反過來。
    private func makeRecorder(turn: Int, url: URL) throws -> FrameRecorder {
        let finalTurn = pipeline.isMirrored ? -turn : turn
        let upright = pipeline.frameSize ?? expectedFrameSize()
        let sideways = abs(finalTurn) == 90
        let width = Int(sideways ? upright.height : upright.width)
        let height = Int(sideways ? upright.width : upright.height)

        let channels = router.recordingChannels()
        let recorder = try FrameRecorder(
            url: url, width: width, height: height, turn: finalTurn,
            videoSettings: videoSettings(width: width, height: height),
            audioSettings: audioSettings(channels: channels),
            audioChannels: channels,
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(activeFPS)),
            // 畫面流程那邊 3 秒沒開始就放棄，這裡要比它早。
            startTimeout: 2.6,
            // 加強防抖的影格會晚更久才到。
            tailTimeout: desiredStabilization == .strong ? 2.0 : 1.0
        )
        recorder.onStarted = { [weak self] time in
            self?.recordingStarted(firstFrame: time, url: url)
        }
        recorder.onEnded = { [weak self, weak recorder] outcome in
            guard let self else { return }
            if let recorder {
                self.logCounts(of: recorder)
                self.pipeline.clearRecorder(recorder)
            }
            self.recordingEnded(outcome, url: url)
            // 錄影中改過的收音設定、錄影中才接上的麥克風，現在才套。
            self.sessionQueue.async {
                self.recordingMicName = nil
                self.applyAudioRoute()
            }
        }
        recordingMicName = router.currentInputName
        log("準備錄影 \(width)x\(height) 音軌\(recorder.hasAudio ? "有" : "無") \(channels) 聲道 · 麥克風 \(recordingMicName ?? "無")")
        return recorder
    }

    /// 還沒收到影格時，用格式推估直式大小。
    private func expectedFrameSize() -> CGSize {
        guard let format = videoDevice?.activeFormat else { return CGSize(width: 1080, height: 1920) }
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return CGSize(width: CGFloat(min(dims.width, dims.height)), height: CGFloat(max(dims.width, dims.height)))
    }

    private func videoSettings(width: Int, height: Int) -> [String: Any] {
        #if targetEnvironment(simulator)
        // 模擬器的相機是假的，問建議設定會直接閃退。
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        #else
        let codecs = videoDataOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mov)
        let codec: AVVideoCodecType = codecs.contains(.hevc) ? .hevc : .h264
        var settings: [String: Any] = [:]
        if codecs.contains(codec) {
            settings = videoDataOutput.recommendedVideoSettings(forVideoCodecType: codec,
                                                                assetWriterOutputFileType: .mov) ?? [:]
        }
        settings[AVVideoCodecKey] = codec
        settings[AVVideoWidthKey] = width
        settings[AVVideoHeightKey] = height
        return settings
        #endif
    }

    /// 音軌的設定，依序試，第一個能用的就用。沒有麥克風就回空的，只錄畫面。
    /// 系統建議的設定照現在的麥克風給，聲道數和要錄的不一樣（雙聲道合成單聲道）時改掉聲道。
    private func audioSettings(channels: Int) -> [[String: Any]] {
        guard audioDataOutput.connection(with: .audio) != nil else { return [] }
        var choices: [[String: Any]] = []
        #if !targetEnvironment(simulator)
        if let recommended = audioDataOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) {
            choices.append(Self.audioSettings(recommended, channels: channels))
        }
        #endif
        choices.append([
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: AudioFormatKeeper.channelLayoutData(channels: channels),
            AVEncoderBitRateKey: channels == 2 ? 192_000 : 128_000
        ])
        return choices
    }

    private static func audioSettings(_ recommended: [String: Any], channels: Int) -> [String: Any] {
        let given = (recommended[AVNumberOfChannelsKey] as? NSNumber)?.intValue ?? channels
        guard given != channels else { return recommended }
        var settings = recommended
        settings[AVNumberOfChannelsKey] = channels
        settings[AVChannelLayoutKey] = AudioFormatKeeper.channelLayoutData(channels: channels)
        // 總位元率跟著聲道數縮放；每聲道的位元率不用動。
        if let total = (settings[AVEncoderBitRateKey] as? NSNumber)?.intValue, given > 0 {
            settings[AVEncoderBitRateKey] = min(320_000, max(64_000, total * channels / given))
        }
        return settings
    }

    /// 第一格寫進去了。在寫檔器的鎖裡面被呼叫，只能丟到主執行緒。
    private func recordingStarted(firstFrame: CMTime, url: URL) {
        let lag: Double = (captureTime() - firstFrame).seconds
        log("開始錄影")
        DispatchQueue.main.async {
            self.recordingLag = lag.isFinite ? max(0, lag) : 0
            self.beginRecordingTask()
            self.recordingURL = url
            self.isRecording = true
        }
    }

    private func logCounts(of recorder: FrameRecorder) {
        let counts = recorder.currentCounts
        log("寫檔 \(counts.frames) 格，來不及 \(counts.notReady)，算圖失敗 \(counts.renderFailed)，聲音丟 \(counts.audioDropped)")
    }

    private func recordingEnded(_ outcome: FrameRecorder.Outcome, url: URL) {
        switch outcome {
        case .finished(let url, let note):
            if let note {
                log("錄影結束時有錯誤：\(note)")
            } else {
                log("錄影完成")
            }
            DispatchQueue.main.async {
                self.isRecording = false
                if let note { self.lastError = note }
                self.onRecordingFinished?(url, note)
                self.applyPreviewRotation()
                self.endRecordingTask()
            }
        case .failed(let message):
            log("錄影失敗：\(message)")
            DispatchQueue.main.async {
                self.isRecording = false
                self.lastError = message
                self.onRecordingFailed?(url, message)
                self.applyPreviewRotation()
                self.endRecordingTask()
            }
        }
    }

    /// 在前景不計時，進了背景才會用到。
    /// 主執行緒呼叫。
    private func beginRecordingTask() {
        guard recordingTask == .invalid else { return }
        recordingTask = UIApplication.shared.beginBackgroundTask(withName: "broccoli-recording") { [weak self] in
            self?.endRecordingTask()
        }
    }

    private func endRecordingTask() {
        DispatchQueue.main.async {
            guard self.recordingTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.recordingTask)
            self.recordingTask = .invalid
        }
    }

    // MARK: - 畫面優化

    /// 任何時候都能呼叫，錄影中也即時生效。
    /// 關掉或全是 0 時，曝光補償歸零、測光回中央。
    func setLook(_ params: LookParams, enabled: Bool) {
        let neutral = !enabled || params == LookParams.neutral
        lookLock.lock()
        look = params
        lookEnabled = enabled
        if neutral && optimizeRun == nil { meteringPoint = nil }
        lookLock.unlock()
        pipeline.setLook(params, enabled: enabled)
        refreshMetalPreview()
        queueExposureUpdate()
    }

    /// 按住比對用：只略過逐格處理，不動曝光補償。
    func setLookBypassed(_ on: Bool) {
        pipeline.setBypassed(on)
    }

    /// 一鍵優化的結果套上去之前呼叫：預覽從舊樣子用過場換成新樣子（QC-0012）。
    /// 只畫在預覽上，錄進影片的畫面不受影響。請在主執行緒、把新參數交給 setLook 之前呼叫。
    /// params、wasEnabled 是換之前的設定。.none 不做過場；錄影中不做。
    func beginLookTransition(from params: LookParams, wasEnabled: Bool, style: LookTransition) {
        guard !pipeline.isRecording,
              let duration = pipeline.beginTransition(from: params, wasEnabled: wasEnabled, style: style) else { return }
        // 原本沒開優化時看的是原生預覽，過場要先疊上處理過的那層。
        refreshMetalPreview()
        // 過場結束後，新的樣子不用逐格處理的話就換回原生預覽。
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
            self?.refreshMetalPreview()
        }
    }

    /// 停掉進行中的過場，直接顯示現在的設定（按還原、開關優化時用）。
    func cancelLookTransition() {
        pipeline.cancelTransition()
        refreshMetalPreview()
    }

    /// 拉滑桿時一秒會來很多次，排隊中就不重複排。
    private func queueExposureUpdate() {
        lookLock.lock()
        let queued = exposureApplyQueued
        exposureApplyQueued = true
        lookLock.unlock()
        guard !queued else { return }
        sessionQueue.async {
            self.lookLock.lock()
            self.exposureApplyQueued = false
            self.lookLock.unlock()
            self.applyLookToDevice()
        }
    }

    /// 把曝光補償和測光位置套到相機。請在 sessionQueue 呼叫。
    /// 一鍵優化進行中由優化流程控制曝光，這裡先不動，結束後會再套一次。
    private func applyLookToDevice() {
        lookLock.lock()
        let optimizing = optimizeRun != nil
        let active = lookEnabled && look != LookParams.neutral
        let bias = active ? look.exposure : 0
        let point: CGPoint? = active ? meteringPoint : nil
        lookLock.unlock()
        guard !optimizing else { return }
        applyExposure(bias: bias, point: point)
    }

    /// 請在 sessionQueue 呼叫。沒變就不鎖裝置。
    private func applyExposure(bias: Double, point: CGPoint?) {
        guard let device = videoDevice else { return }
        let target: Float = min(max(Float(bias), device.minExposureTargetBias), device.maxExposureTargetBias)
        let center = CGPoint(x: 0.5, y: 0.5)
        let spot: CGPoint = point ?? center
        let biasChanged = abs((lastRequestedBias ?? device.exposureTargetBias) - target) > 0.01
        let exposureMoves = device.isExposurePointOfInterestSupported
            && device.isExposureModeSupported(.continuousAutoExposure)
            && Self.isFar(device.exposurePointOfInterest, spot)
        let focusMoves = device.isFocusPointOfInterestSupported
            && device.isFocusModeSupported(.continuousAutoFocus)
            && Self.isFar(device.focusPointOfInterest, spot)
        guard biasChanged || exposureMoves || focusMoves else { return }
        do {
            try device.lockForConfiguration()
            // 位置要再設一次模式才會生效。
            if exposureMoves {
                device.exposurePointOfInterest = spot
                device.exposureMode = .continuousAutoExposure
            }
            if focusMoves {
                device.focusPointOfInterest = spot
                device.focusMode = .continuousAutoFocus
            }
            if biasChanged {
                device.setExposureTargetBias(target, completionHandler: nil)
                lastRequestedBias = target
            }
            device.unlockForConfiguration()
        } catch {
            log("曝光設定失敗：\(error.localizedDescription)")
        }
    }

    private static func isFar(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) > 0.01 || abs(a.y - b.y) > 0.01
    }

    /// 一鍵優化：對臉測光、等曝光穩定、分析，回傳參數。主執行緒呼叫、主執行緒回呼。
    /// 不套用，由呼叫端 setLook；smooth 由呼叫端補回。nil 代表沒有畫面可分析。
    func optimizeLook(completion: @escaping (LookResult?) -> Void) {
        guard isSessionRunning, pipeline.hasRecentFrame, !pipeline.isRecording else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        lookLock.lock()
        let busy = optimizeRun != nil
        if !busy {
            optimizeCount += 1
            optimizeRun = optimizeCount
        }
        let run = optimizeCount
        lookLock.unlock()
        guard !busy else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        // 分析要等曝光穩定，趁這段時間在背景把過場先畫一次（只有 App 開著後的第一次會真的做）。
        LookTransitionMask.prewarmOnce()
        // 臉在裝置座標的位置，用預覽層換算，方向、鏡像、機型差異都包含在裡面。
        var point: CGPoint?
        if let layer = previewLayer, let face = faces.faceRect {
            let converted = layer.captureDevicePointConverted(fromLayerPoint: CGPoint(x: face.midX, y: face.midY))
            if converted.x.isFinite, converted.y.isFinite {
                point = CGPoint(x: min(max(converted.x, 0), 1), y: min(max(converted.y, 0), 1))
            }
        }
        analysisQueue.async {
            let found = self.runOptimization(point: point, run: run)
            DispatchQueue.main.async {
                // 中途被取消（開錄、按了還原）就當作沒有結果。
                let result: LookResult? = self.isOptimizing(run) ? found : nil
                if let result {
                    self.log(String(format: "一鍵優化 臉=%@ 曝光=%.2f 色溫=%.0f 色調=%.0f 太暗=%@",
                                    result.hasFace ? "有" : "無", result.params.exposure,
                                    result.params.temperature, result.params.tint,
                                    result.stillTooDark ? "是" : "否"))
                } else {
                    self.log("一鍵優化沒有結果")
                }
                self.lookLock.lock()
                if self.optimizeRun == run { self.optimizeRun = nil }
                self.lookLock.unlock()
                // 呼叫端通常會在這裡面 setLook，那就直接接上剛剛的曝光，不會跳一下。
                completion(result)
                // 萬一呼叫端沒有採用，過一下把相機拉回目前存著的設定。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.queueExposureUpdate()
                }
            }
        }
    }

    /// 取消進行中的一鍵優化，曝光和測光回到分析前。沒在跑就沒事。
    func cancelOptimize() {
        lookLock.lock()
        let running = optimizeRun != nil
        optimizeRun = nil
        lookLock.unlock()
        guard running else { return }
        queueExposureUpdate()
    }

    /// 第 run 次分析還要不要繼續：沒被取消、也沒在錄影。
    private func isOptimizing(_ run: Int) -> Bool {
        lookLock.lock()
        let current = optimizeRun == run
        lookLock.unlock()
        return current && !pipeline.isRecording
    }

    /// 在 analysisQueue 跑，中間會等影格、等曝光穩定。只讀原始影格，逐格處理不影響分析。
    private func runOptimization(point: CGPoint?, run: Int) -> LookResult? {
        guard let device = sessionQueue.sync(execute: { self.videoDevice }),
              let first = pipeline.grabSample(after: nil, timeout: 1.5),
              let start = LookAnalyzer.measure(first) else { return nil }

        // 第一次：測光移到臉上，順便把曝光推過去。
        var exposure = LookAnalyzer.exposureBias(current: Double(device.exposureTargetBias), reading: start)
        guard var reading = settle(device, exposure: exposure, point: point, run: run) else { return nil }
        // 測光點換了，亮度會跟著變，差得多就再修一次。
        let refined = LookAnalyzer.exposureBias(current: exposure, reading: reading)
        if abs(refined - exposure) >= 0.2, let again = settle(device, exposure: refined, point: point, run: run) {
            exposure = refined
            reading = again
        }

        let size = pipeline.frameSize ?? CGSize(width: 1080, height: 1920)
        let context = LookContext(
            exposure: exposure,
            iso: Double(device.iso),
            maxISO: Double(device.activeFormat.maxISO),
            exposureOffset: Double(device.exposureTargetOffset),
            shortSide: Int(min(size.width, size.height))
        )
        guard isOptimizing(run) else { return nil }
        lookLock.lock()
        meteringPoint = point
        lookLock.unlock()
        return LookResult(params: LookAnalyzer.params(reading: reading, context: context),
                          hasFace: reading.hasFace,
                          stillTooDark: LookAnalyzer.isStillTooDark(reading: reading, context: context))
    }

    /// 套曝光，等穩定（最多 1.2 秒），再量一次。
    private func settle(_ device: AVCaptureDevice, exposure: Double, point: CGPoint?, run: Int) -> LookReading? {
        // 在 sessionQueue 裡再確認一次，和開錄排在同一條佇列，不會交錯。
        let applied: Bool = sessionQueue.sync {
            guard self.isOptimizing(run) else { return false }
            self.applyExposure(bias: exposure, point: point)
            return true
        }
        guard applied else { return nil }
        Thread.sleep(forTimeInterval: 0.3)
        var waited: TimeInterval = 0.3
        while waited < 1.2, device.isAdjustingExposure, isOptimizing(run) {
            Thread.sleep(forTimeInterval: 0.05)
            waited += 0.05
        }
        guard isOptimizing(run), let sample = pipeline.grabSample(after: captureTime(), timeout: 1.5) else { return nil }
        return LookAnalyzer.measure(sample)
    }

    /// 除錯層用的一行。
    private func lookText() -> String {
        lookLock.lock()
        let params = look
        let on = lookEnabled
        lookLock.unlock()
        guard on else { return "優化 關" }
        let bias: Float = videoDevice?.exposureTargetBias ?? 0
        return String(format: "優化 曝光%.2f(實際%.2f) 溫%.0f 調%.0f 亮%.0f 暗%.0f 對%.0f 飽%.0f 噪%.0f 銳%.0f 膚%.0f",
                      params.exposure, Double(bias), params.temperature, params.tint,
                      params.highlights, params.shadows, params.contrast, params.vibrance,
                      params.denoise, params.sharpen, params.smooth)
    }

    // MARK: - 通知

    @objc private func sessionWasInterrupted(_ note: Notification) {
        var text = "相機被中斷"
        if let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
           let reason = AVCaptureSession.InterruptionReason(rawValue: raw) {
            switch reason {
            case .videoDeviceNotAvailableInBackground:
                text = "App 在背景，相機暫停"
            case .audioDeviceInUseByAnotherClient:
                text = "麥克風被其他 App 或來電占用"
            case .videoDeviceInUseByAnotherClient:
                text = "相機被其他 App 占用"
            default:
                text = "相機被中斷（代碼 \(raw)）"
            }
        }
        log(text)
        // 中斷後不會再有影格，手上的檔案先收好。
        finishRecordingNow()
        DispatchQueue.main.async {
            self.interruptionText = text
        }
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        log("中斷結束")
        // 來電之類的中斷結束，音訊要重新拿回來。
        sessionQueue.async { self.applyAudioRoute() }
        DispatchQueue.main.async {
            self.interruptionText = nil
            self.applyPreviewRotation()
        }
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
        let code = error.map { " (\($0.code.rawValue))" } ?? ""
        let text = "執行期錯誤：\(error?.localizedDescription ?? "未知")\(code)"
        log(text)
        finishRecordingNow()
        DispatchQueue.main.async {
            self.lastError = text
        }
        if error?.code == .mediaServicesWereReset {
            sessionQueue.async {
                // 完成頁或校對頁開著就不叫起來，會把播放的音訊搶走。離開那一頁時畫面會自己再叫 start。
                if self.wantsRunning, !self.session.isRunning {
                    self.router.activate()
                    self.session.startRunning()
                    self.applyAudioRoute()
                }
                let running = self.session.isRunning
                DispatchQueue.main.async {
                    self.isSessionRunning = running
                }
            }
        }
    }

    @objc private func audioRouteChanged(_ note: Notification) {
        let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
        let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
        let previousInput = previous?.inputs.first
        let previousName = previousInput?.portName
        let previousKind = previousInput.map { MicKind($0.portType) } ?? .none
        sessionQueue.async {
            self.routeChanged(reason: reason, previousName: previousName, previousKind: previousKind)
        }
        DispatchQueue.main.async {
            self.meter.refreshRoute()
            self.log("音訊路由變更（\(Self.reasonText(reason))）：\(self.meter.route)")
        }
    }

    /// 插拔麥克風。sessionQueue 呼叫。
    private func routeChanged(reason: AVAudioSession.RouteChangeReason, previousName: String?, previousKind: MicKind) {
        guard isConfigured, wantsRunning else {
            publishMicRoute()
            return
        }
        guard pipeline.isRecording, let url = pipeline.recorder?.url else {
            // 沒在錄：直接照設定挑。換麥是非同步的，這次看不到新名字，下一次路由變更會看到，所以跟上次看到的比。
            applyAudioRoute()
            let now = router.currentInputName
            if let now, let seen = lastSeenMicName, now != seen {
                if router.currentKind == .bluetooth && !router.bluetoothHQActive {
                    showMicNotice("改用「\(now)」收音。藍牙麥克風是電話音質，要好音質請接 USB-C 接收器")
                } else {
                    showMicNotice("改用「\(now)」收音")
                }
            }
            if now != nil { lastSeenMicName = now }
            return
        }
        if let now = router.currentInputName { lastSeenMicName = now }
        // 錄影中：不主動換麥，免得聲音斷掉；外接麥掉了系統會自己退回手機麥克風，錄影照常。
        micWaitingFor = router.applyChoice(recording: true)
        let now = router.currentInputName ?? "沒有麥克風"
        if let started = recordingMicName, now != started {
            noteMicChange("錄到一半麥克風從「\(started)」換成「\(now)」，後面那段的音質會不一樣。", for: url)
        }
        if reason == .oldDeviceUnavailable, previousKind.isExternal, now != previousName {
            showMicNotice("「\(previousName ?? "外接麥克風")」斷線了，這段後面改用「\(now)」收音，錄影沒有中斷")
        } else if reason == .newDeviceAvailable, let waiting = micWaitingFor {
            showMicNotice("接上了「\(waiting)」，這段錄完就換它收音")
        }
        publishMicRoute()
    }

    private static func reasonText(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: return "接上新裝置"
        case .oldDeviceUnavailable: return "裝置拔掉"
        case .categoryChange: return "類別改變"
        case .override: return "強制切換"
        case .wakeFromSleep: return "喚醒"
        case .noSuitableRouteForCategory: return "沒有可用路線"
        case .routeConfigurationChange: return "路線設定改變"
        default: return "其他"
        }
    }

    @objc private func appEnteredBackground(_ note: Notification) {
        // 背景不能用 GPU，也不會再有影格。
        pipeline.setGPUAllowed(false)
        // 剛開錄就被切走時，第一格的通知可能還沒跑，這裡先要到背景時間再收尾。
        if pipeline.isRecording { beginRecordingTask() }
        finishRecordingNow()
    }

    @objc private func appWillEnterForeground(_ note: Notification) {
        pipeline.setGPUAllowed(true)
    }

    @objc private func thermalStateChanged(_ note: Notification) {
        updateThermalLimit()
    }

    /// 過熱就先不做降噪和柔膚，其他參數照舊。
    private func updateThermalLimit() {
        let state = ProcessInfo.processInfo.thermalState
        let hot = state == .serious || state == .critical
        pipeline.setHeavySkipped(hot)
        if hot && pipeline.usesHeavyFilters {
            log("手機過熱，先略過降噪和柔膚")
        }
    }

    // MARK: - 除錯

    func log(_ message: String) {
        let line = "\(Self.timeFormatter.string(from: Date())) \(message)"
        DispatchQueue.main.async {
            self.logLines.append(line)
            if self.logLines.count > 40 {
                self.logLines.removeFirst(self.logLines.count - 40)
            }
        }
    }

    private func fail(_ message: String) {
        log(message)
        DispatchQueue.main.async {
            self.lastError = message
        }
    }

    /// 除錯資訊層顯示與複製用。請在主執行緒呼叫。
    func debugSnapshot() -> String {
        var lines: [String] = []
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        lines.append("花椰菜相機 \(version) (\(build))")
        lines.append("裝置 \(Self.machineIdentifier) · iOS \(UIDevice.current.systemVersion)")
        lines.append("Session \(session.isRunning ? "執行中" : "已停止") · 錄影 \(isRecording ? "是" : "否")")
        lines.append("格式 \(activeFormatText)")
        if let connection = videoDataOutput.connection(with: .video) {
            let size = pipeline.frameSize ?? .zero
            lines.append("影格 \(Int(size.width))x\(Int(size.height)) 旋轉=\(Int(connection.videoRotationAngle)) 鏡像=\(connection.isVideoMirrored ? "是" : "否")")
            lines.append("防抖 要求=\(Self.stabilizationText(connection.preferredVideoStabilizationMode)) 實際=\(Self.stabilizationText(connection.activeVideoStabilizationMode))")
        }
        let frames = pipeline.currentCounts
        let preview = pipeline.renderer.counts
        lines.append("影格 收到 \(frames.frames) 丟 \(frames.late) · 預覽 \(metalPreviewOn ? "處理過" : "原生") 畫 \(preview.drawn) 略過 \(preview.skipped)")
        if let last = pipeline.lastTime {
            lines.append(String(format: "影格時間 比時鐘晚 %.0f 毫秒", (captureTime() - last).seconds * 1000))
        }
        if let recorder = pipeline.recorder {
            let written = recorder.currentCounts
            lines.append("寫檔 \(written.frames) 格 來不及 \(written.notReady) 算圖失敗 \(written.renderFailed) 聲音丟 \(written.audioDropped) · 音軌\(recorder.hasAudio ? "有" : "無")")
        }
        lines.append(lookText())
        if let connection = previewLayer?.connection {
            lines.append("預覽 旋轉=\(Int(connection.videoRotationAngle)) 支援90=\(connection.isVideoRotationAngleSupported(90) ? "是" : "否")")
        } else {
            lines.append("預覽 沒有連線")
        }
        if let coordinator = rotationCoordinator {
            lines.append("協調器 預覽=\(Int(coordinator.videoRotationAngleForHorizonLevelPreview)) 錄影=\(Int(coordinator.videoRotationAngleForHorizonLevelCapture))")
        } else {
            lines.append("協調器 未建立")
        }
        audioTapLock.lock()
        let packets = audioPacketCount
        let bufferChannels = lastAudioChannels
        let bufferRate = lastAudioRate
        audioTapLock.unlock()
        lines.append("音訊 收到 \(packets) 包 · 實收 \(bufferChannels) 聲道 \(String(format: "%.0f", bufferRate)) Hz")
        lines.append("音訊路由 \(meter.route)")
        let mic = micRoute
        lines.append("麥克風 \(mic.name)（\(mic.kind.label)）· 系統 \(mic.inputChannels) 聲道 \(String(format: "%.0f", mic.sampleRate)) Hz · 錄成\(mic.recordsStereo ? "立體聲" : "單聲道")\(mic.isPhoneQuality ? " · 電話音質" : "")")
        if let waiting = mic.waitingFor {
            lines.append("麥克風 錄完會換成 \(waiting)")
        }
        let names = mic.available.map { $0.name }.joined(separator: "、")
        lines.append("可用麥克風 \(names.isEmpty ? "無" : names)")
        let perChannel = audioLevel.currentChannels()
        if perChannel.count >= 2 {
            lines.append(String(format: "左右音量 左 %.1f dB · 右 %.1f dB", perChannel[0], perChannel[1]))
        }
        lines.append("AirPods 收音 \(bluetoothHQText())")
        let signal: String
        switch meter.micStatus {
        case .ok: signal = "正常"
        case .noSignal: signal = "無訊號"
        case .unknown: signal = "未知"
        }
        lines.append(String(format: "音量 %.1f dB · 收音%@ · %@", meter.level, signal, meter.isSpeaking ? "說話中" : "停頓"))
        if let face = faces.faceRect {
            lines.append(String(format: "臉部 x=%.0f y=%.0f w=%.0f h=%.0f", face.minX, face.minY, face.width, face.height))
        } else {
            lines.append("臉部 無")
        }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "正常"
        case .fair: thermal = "微熱"
        case .serious: thermal = "過熱"
        case .critical: thermal = "嚴重過熱"
        @unknown default: thermal = "未知"
        }
        lines.append("溫度狀態 \(thermal)")
        lines.append("中斷 \(interruptionText ?? "無")")
        lines.append("最近錯誤 \(lastError ?? "無")")
        lines.append("— 紀錄 —")
        lines.append(contentsOf: logLines.suffix(14))
        return lines.joined(separator: "\n")
    }

    private static let machineIdentifier: String = {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }()

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }
}

// MARK: - 音訊

extension CameraService: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        audioLevel.consume(sampleBuffer)
        pipeline.recorder?.appendAudio(sampleBuffer)
        let basic = CMSampleBufferGetFormatDescription(sampleBuffer)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        audioTapLock.lock()
        audioPacketCount += 1
        if let basic {
            lastAudioChannels = Int(basic.mChannelsPerFrame)
            lastAudioRate = basic.mSampleRate
        }
        let handler = storedAudioSampleHandler
        audioTapLock.unlock()
        // 語音辨識要單聲道、格式固定的聲音。
        if let handler, let mono = speechKeeper.process(sampleBuffer) {
            handler(mono)
        }
    }
}

// MARK: - 臉部中繼資料

extension CameraService: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        // 柔膚要跟著臉走，每秒約 10 次；畫面提示另外節流。
        let now = CACurrentMediaTime()
        guard now - lastFaceUpdate > 0.09 else { return }
        lastFaceUpdate = now

        var largest: AVMetadataObject?
        for object in metadataObjects where object.type == .face {
            if let current = largest {
                if object.bounds.width * object.bounds.height > current.bounds.width * current.bounds.height {
                    largest = object
                }
            } else {
                largest = object
            }
        }

        DispatchQueue.main.async {
            let layer = self.previewLayer
            var rect: CGRect?
            if let face = largest, let converted = layer?.transformedMetadataObject(for: face) {
                rect = converted.bounds
            }
            if let layer, let rect {
                self.pipeline.setFace(self.frameRect(rect, in: layer))
            }
            // UI 更新節流到每秒約 3 次，避免提示閃爍。
            guard now - self.lastFaceUIUpdate > 0.33 else { return }
            self.lastFaceUIUpdate = now
            self.faces.update(rect)
        }
    }

    /// 預覽層座標 → 影格座標（0…1，原點左上）。預覽層的換算已經處理好方向和裝置差異，
    /// 這裡只差「預覽是鏡像、影格不一定是」。
    /// 開防抖時影格外圍會被裁掉一圈，臉的位置會差幾個百分點，柔膚和測光都容得下。
    private func frameRect(_ rect: CGRect, in layer: AVCaptureVideoPreviewLayer) -> CGRect? {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        let video: CGRect = layer.layerRectConverted(fromMetadataOutputRect: whole).standardized
        guard video.width > 1, video.height > 1 else { return nil }
        let width: CGFloat = rect.width / video.width
        let height: CGFloat = rect.height / video.height
        var x: CGFloat = (rect.minX - video.minX) / video.width
        let y: CGFloat = (rect.minY - video.minY) / video.height
        let previewMirrored = layer.connection?.isVideoMirrored ?? true
        if previewMirrored != pipeline.isMirrored {
            x = 1 - x - width
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
