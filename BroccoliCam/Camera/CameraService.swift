import AVFoundation
import UIKit

/// 前鏡頭、預覽、錄影、格式、權限、中斷處理。
/// 所有 session 操作都在 sessionQueue，不在主執行緒做重工作。
final class CameraService: NSObject, ObservableObject {
    enum Authorization {
        case unknown
        case authorized
        case denied
    }

    @Published private(set) var authorization: Authorization = .unknown
    @Published private(set) var isSessionRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var availableResolutions: [VideoResolution] = [.hd1080]
    @Published private(set) var availableFPS: [VideoResolution: [Int]] = [.hd1080: [30]]
    @Published private(set) var activeFormatText = "—"
    @Published private(set) var interruptionText: String?
    @Published private(set) var lastError: String?
    @Published private(set) var logLines: [String] = []

    let session = AVCaptureSession()
    let faces = FaceDetectionService()
    let meter = SpeechActivityMonitor()

    /// 錄影檔完成（主執行緒回呼）。
    var onRecordingFinished: ((URL) -> Void)?
    /// 錄影失敗（主執行緒回呼）。
    var onRecordingFailed: (() -> Void)?
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
    private let movieOutput = AVCaptureMovieFileOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    /// 語音跟隨用的音訊分流。只有設定打開時才掛上去，沒開就和原本的錄影管線完全一樣。
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private let audioQueue = DispatchQueue(label: "org.domyweb.broccolicam.audio")
    private let audioTapLock = NSLock()
    private var storedAudioSampleHandler: ((CMSampleBuffer) -> Void)?
    private var audioTapCount = 0
    private var audioTapAttached = false
    private var videoDevice: AVCaptureDevice?
    private var isConfigured = false
    private var desiredResolution: VideoResolution = .hd1080
    private var desiredFPS = 30
    private var mirrorOutput = false
    private var lastFaceUpdate: CFTimeInterval = 0
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    /// 依裝置問出正確的旋轉角度。iPhone 17 的前鏡頭感光元件裝的方向和舊機型差 90 度，
    /// 不能寫死 90 度。只在主執行緒建立與讀取。
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    /// 錄影要用的角度，主執行緒更新、sessionQueue 讀取。
    private var captureRotationAngle: CGFloat = 90

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    override init() {
        super.init()
        meter.levelProvider = { [weak self] in
            self?.currentAudioLevel()
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

    /// 啟動（或以新設定重新套用）相機。錄影中呼叫只會更新設定值，不會改格式。
    func start(resolution: VideoResolution, fps: Int, mirrorOutput: Bool, speechTap: Bool = false) {
        let angle = currentCaptureAngle()
        sessionQueue.async {
            self.captureRotationAngle = angle
            self.desiredResolution = resolution
            self.desiredFPS = fps
            self.mirrorOutput = mirrorOutput
            if !self.isConfigured {
                self.configureSession()
            }
            guard self.isConfigured else { return }
            if !self.movieOutput.isRecording {
                self.applySpeechTap(speechTap)
                self.applyFormat()
                self.updateConnections()
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
                if running { self.meter.start() }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
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
        log("旋轉協調器 預覽=\(Int(coordinator.videoRotationAngleForHorizonLevelPreview)) 錄影=\(Int(coordinator.videoRotationAngleForHorizonLevelCapture))")
    }

    /// 預覽應該轉幾度。沒有協調器時退回舊機型的 90 度。
    private func currentPreviewAngle() -> CGFloat {
        rotationCoordinator?.videoRotationAngleForHorizonLevelPreview ?? 90
    }

    /// 錄影應該轉幾度。App 鎖直式，所以用預覽的角度，不跟著手機傾斜改變。
    private func currentCaptureAngle() -> CGFloat {
        guard let coordinator = rotationCoordinator else { return 90 }
        return coordinator.videoRotationAngleForHorizonLevelPreview
    }

    /// 手機橫放時錄影應該轉幾度：跟著手機實際的擺法（重力方向）。
    private func currentLandscapeAngle() -> CGFloat {
        guard let coordinator = rotationCoordinator else { return 90 }
        return coordinator.videoRotationAngleForHorizonLevelCapture
    }

    /// 把預覽轉成直式。請在主執行緒呼叫。
    /// 預覽層的連線要等 session 設定完才會出現，所以會被多處重複呼叫：
    /// 掛上預覽層、session 啟動後、預覽 view 重新排版、中斷結束。
    func applyPreviewRotation() {
        guard let connection = previewLayer?.connection else {
            notePreviewRotation("預覽連線還沒建立")
            return
        }
        Self.apply(currentPreviewAngle(), to: connection)
        notePreviewRotation("預覽旋轉=\(Int(connection.videoRotationAngle))")
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

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        } else {
            session.commitConfiguration()
            fail("無法加入錄影輸出")
            return
        }

        // 臉部定位：相機內建的臉部中繼資料，不另接影格輸出。失敗時 App 仍可錄影。
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
    }

    /// 掛上或拿掉語音跟隨用的音訊分流。請在 sessionQueue 呼叫，錄影中不要動。
    private func applySpeechTap(_ wanted: Bool) {
        guard wanted != audioTapAttached else { return }
        session.beginConfiguration()
        if wanted {
            if session.canAddOutput(audioDataOutput) {
                session.addOutput(audioDataOutput)
                audioDataOutput.setSampleBufferDelegate(self, queue: audioQueue)
                audioTapAttached = true
                log("語音分流已掛上")
            } else {
                log("無法加入語音分流輸出")
            }
        } else {
            audioDataOutput.setSampleBufferDelegate(nil, queue: nil)
            session.removeOutput(audioDataOutput)
            audioTapAttached = false
            log("語音分流已拿掉")
        }
        session.commitConfiguration()
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
        do {
            try device.lockForConfiguration()
            if let (format, fps) = chosen {
                if device.activeFormat != format {
                    device.activeFormat = format
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
            device.unlockForConfiguration()
        } catch {
            log("格式設定失敗：\(error.localizedDescription)")
        }

        let active = device.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions(active.formatDescription)
        let fourCC = Self.fourCCString(CMFormatDescriptionGetMediaSubType(active.formatDescription))
        let actualFPS = chosen?.1 ?? Int(maxFrameRate(active))
        let text = "\(dims.width)x\(dims.height) @\(actualFPS)fps \(fourCC)（要求 \(desiredResolution.label)/\(desiredFPS)）"
        DispatchQueue.main.async {
            self.activeFormatText = text
        }
        log("格式 \(text)")
    }

    private func updateConnections() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        Self.apply(captureRotationAngle, to: connection)
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrorOutput
        }
    }

    // MARK: - 錄影

    /// landscape：手機橫放，要錄成橫式 16:9。角度交給 RotationCoordinator 依手機實際的擺法決定。
    func startRecording(landscape: Bool = false) {
        let angle = landscape ? currentLandscapeAngle() : currentCaptureAngle()
        if landscape {
            log("橫式錄影 角度=\(Int(angle))")
        }
        sessionQueue.async {
            self.captureRotationAngle = angle
            guard self.isConfigured, self.session.isRunning else {
                self.log("相機尚未就緒，無法錄影")
                DispatchQueue.main.async { self.onRecordingFailed?() }
                return
            }
            guard !self.movieOutput.isRecording else { return }
            self.updateConnections()
            if let connection = self.movieOutput.connection(with: .video),
               self.movieOutput.availableVideoCodecTypes.contains(.hevc) {
                self.movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
            }
            let name = "broccoli-\(Int(Date().timeIntervalSince1970)).mov"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        sessionQueue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
        }
    }

    // MARK: - 音量

    /// 錄影輸出音訊連線的平均音量（dB）。沒有連線時回傳 nil。
    private func currentAudioLevel() -> Float? {
        guard let connection = movieOutput.connection(with: .audio) else { return nil }
        let channels = connection.audioChannels
        guard !channels.isEmpty else { return nil }
        return channels.map { $0.averagePowerLevel }.max()
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
        DispatchQueue.main.async {
            self.interruptionText = text
        }
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        log("中斷結束")
        DispatchQueue.main.async {
            self.interruptionText = nil
            self.applyPreviewRotation()
        }
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
        let text = "執行期錯誤：\(error?.localizedDescription ?? "未知")"
        log(text)
        DispatchQueue.main.async {
            self.lastError = text
        }
        if error?.code == .mediaServicesWereReset {
            sessionQueue.async {
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                let running = self.session.isRunning
                DispatchQueue.main.async {
                    self.isSessionRunning = running
                }
            }
        }
    }

    @objc private func audioRouteChanged(_ note: Notification) {
        DispatchQueue.main.async {
            self.meter.refreshRoute()
            self.log("音訊路由變更：\(self.meter.route)")
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
        if let connection = movieOutput.connection(with: .video) {
            lines.append("輸出 旋轉=\(Int(connection.videoRotationAngle)) 鏡像=\(connection.isVideoMirrored ? "是" : "否")")
        }
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
        let tapCount = audioTapCount
        audioTapLock.unlock()
        lines.append("語音分流 收到 \(tapCount) 包")
        lines.append("音訊路由 \(meter.route)")
        let mic: String
        switch meter.micStatus {
        case .ok: mic = "正常"
        case .noSignal: mic = "無訊號"
        case .unknown: mic = "未知"
        }
        lines.append(String(format: "音量 %.1f dB · 收音%@ · %@", meter.level, mic, meter.isSpeaking ? "說話中" : "停頓"))
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

// MARK: - 錄影回呼

extension CameraService: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        log("開始錄影")
        DispatchQueue.main.async {
            self.isRecording = true
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        var usable = true
        var message: String?
        if let error = error as NSError? {
            // 被中斷時檔案仍可能是完整可用的。
            usable = (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
            message = "錄影結束時有錯誤：\(error.localizedDescription)"
        }
        if let message {
            log(message)
        } else {
            log("錄影完成")
        }
        DispatchQueue.main.async {
            self.isRecording = false
            if usable {
                self.onRecordingFinished?(outputFileURL)
            } else {
                self.lastError = message
                try? FileManager.default.removeItem(at: outputFileURL)
                self.onRecordingFailed?()
            }
        }
    }
}

// MARK: - 語音分流

extension CameraService: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        audioTapLock.lock()
        audioTapCount += 1
        let handler = storedAudioSampleHandler
        audioTapLock.unlock()
        handler?(sampleBuffer)
    }
}

// MARK: - 臉部中繼資料

extension CameraService: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        // UI 更新節流到每秒約 3 次，避免提示閃爍。
        let now = CACurrentMediaTime()
        guard now - lastFaceUpdate > 0.33 else { return }
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
            guard let face = largest,
                  let layer = self.previewLayer,
                  let converted = layer.transformedMetadataObject(for: face) else {
                self.faces.update(nil)
                return
            }
            self.faces.update(converted.bounds)
        }
    }
}
