import AVFoundation
import BackgroundTasks
import Combine
import CoreVideo
import Darwin
import UIKit

enum CaptionBurnError: LocalizedError {
    case cannotRead
    case cannotWrite
    case noSpace
    case noSound
    case stoppedBySystem
    case broken

    var errorDescription: String? {
        switch self {
        case .cannotRead: return "原片讀不出來，燒不了。"
        case .cannotWrite: return "檔案寫不進去。"
        case .noSpace: return "手機空間不夠，請清出空間再燒一次。"
        case .noSound: return "聲音沒辦法寫進影片。"
        case .stoppedBySystem: return "被系統停掉了，請重燒。原片沒有動。"
        case .broken: return "燒出來的檔案不完整，請再燒一次。"
        }
    }
}

/// 把字幕燒進影片。直接從各段原片輸出成一支，不先接再燒，少壓一次。
@MainActor
final class CaptionExporter: ObservableObject {
    enum State: Equatable {
        case idle
        case running(Double)
        case done(URL)
        case failed(String)
        case cancelled
    }

    @Published private(set) var state: State = .idle
    /// 太燙，先停著（state 還是 running）。涼了會自己繼續，也可以叫 continueAt1080 或 keepGoing。
    /// 4K 到 .serious 就停，1080p 到 .critical 才停。
    @Published private(set) var isHot = false
    /// 這次實際輸出的解析度。選了 4K 但來源不是 4K、或中途改 1080p，都會變成 hd1080。
    @Published private(set) var resolution: CaptionResolution = .hd1080

    var isBusy: Bool {
        if case .running = state { return true }
        return false
    }

    private struct Request {
        let video: CaptionVideo
        let lines: [CaptionLine]
        let style: CaptionStyle
        let resolution: CaptionResolution
        let output: URL
    }

    private enum StopReason {
        case user
        case system
        /// 換一組設定重來。
        case replaced
    }

    private var current: Request?
    private var queued: Request?
    private var stopReason: StopReason?
    private var job: CaptionBurnJob?
    private var runID = UUID()
    private var keeper: CaptionBurnKeeper?
    private var observers: [NSObjectProtocol] = []
    private var idleTimerWasDisabled = false
    private var wentToBackground = false
    /// 使用者說這個程度的燙沒關係。
    private var toleratedHeat = -1
    #if targetEnvironment(simulator)
    private var fakeHeat = false
    private var fakeHeatUsed = false
    #endif

    // MARK: - 對外

    /// 輸出到 output（已經有檔案會換掉，但成功才換）。正在燒的時候再叫一次，就停掉舊的、用新的設定從頭燒。
    func start(video: CaptionVideo, lines: [CaptionLine], style: CaptionStyle,
               resolution: CaptionResolution, output: URL) {
        let request = Request(video: video, lines: lines, style: style, resolution: resolution, output: output)
        if isBusy {
            // 太燙時按「改 1080p 繼續」會走到這裡，同一個溫度不要再停一次。
            if isHot { toleratedHeat = heatLevel }
            queued = request
            stopReason = .replaced
            job?.cancel()
            return
        }
        toleratedHeat = -1
        wentToBackground = false
        #if targetEnvironment(simulator)
        fakeHeat = false
        fakeHeatUsed = false
        #endif
        prepareToRun()
        current = request
        state = .running(0)
        Task { await self.runAll(from: request) }
    }

    func cancel() {
        guard isBusy else { return }
        queued = nil
        stopReason = .user
        job?.cancel()
    }

    /// 太燙時改用 1080p 從頭燒。
    func continueAt1080() {
        guard isBusy, let current else { return }
        start(video: current.video, lines: current.lines, style: current.style,
              resolution: .hd1080, output: current.output)
    }

    /// 太燙也照原本的解析度繼續。
    func keepGoing() {
        guard isBusy else { return }
        toleratedHeat = heatLevel
        applyHeat()
    }

    // MARK: - 流程

    private func prepareToRun() {
        stopReason = nil
        queued = nil
        idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let keeper = CaptionBurnKeeper { [weak self] in
            self?.stopBySystem()
        }
        self.keeper = keeper
        keeper.start()

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyHeat() }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wentToBackground = true }
            }
        ]
    }

    private func runAll(from first: Request) async {
        var request: Request = first
        var result: State = .idle
        while true {
            current = request
            runID = UUID()
            isHot = false
            result = await burn(request)
            guard let next = queued else { break }
            queued = nil
            stopReason = nil
            request = next
            state = .running(0)
        }

        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        // 先放開系統的背景任務再改狀態，畫面收到結果時這邊已經收乾淨。
        if case .done = result {
            keeper?.finish(success: true)
        } else {
            keeper?.finish(success: false)
        }
        keeper = nil
        UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
        isHot = false
        current = nil
        stopReason = nil
        state = result
    }

    private func burn(_ request: Request) async -> State {
        let folder: URL = request.output.deletingLastPathComponent()
        let temp: URL = folder.appendingPathComponent(Self.tempPrefix + UUID().uuidString + ".mov")
        do {
            try await request.video.prepare()
            try checkStop()
            let media = try request.video.media()
            let wanted: CaptionResolution = media.is4K ? request.resolution : .hd1080
            resolution = wanted
            let size: CGSize = try request.video.pixelSize(wanted)
            let bitRate: Int = CaptionBurnJob.bitRate(for: media, size: size)

            try makeRoom(in: folder, at: temp, bytes: Self.estimate(bitRate: bitRate, media: media))

            let overlay = CaptionOverlay()
            overlay.set(lines: request.lines, style: request.style)
            let id: UUID = runID
            let job = CaptionBurnJob(media: media, size: size, bitRate: bitRate, overlay: overlay,
                                     output: temp) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.moved(to: fraction, of: id)
                }
            }
            self.job = job
            applyHeat()
            try await job.run()
            self.job = nil
            try checkStop()
            try await Self.verify(temp, duration: media.duration.seconds)
            try checkStop()
            try Self.swap(temp, into: request.output)
            return .done(request.output)
        } catch {
            job = nil
            try? FileManager.default.removeItem(at: temp)
            return outcome(of: error)
        }
    }

    private func checkStop() throws {
        if stopReason != nil { throw CancellationError() }
    }

    private func outcome(of error: Error) -> State {
        switch stopReason {
        case .user, .replaced: return .cancelled
        case .system: return .failed(CaptionBurnError.stoppedBySystem.localizedDescription)
        case nil: return .failed(describe(error))
        }
    }

    private func stopBySystem() {
        guard isBusy, stopReason != .user else { return }
        queued = nil
        stopReason = .system
        job?.cancel()
    }

    private func moved(to fraction: Double, of id: UUID) {
        guard id == runID, case .running(let shown) = state, fraction > shown else { return }
        state = .running(min(1, fraction))
        keeper?.report(fraction)
        #if targetEnvironment(simulator)
        if fraction >= 0.3, !fakeHeatUsed, UserDefaults.standard.bool(forKey: "debugBurnHeat") {
            fakeHeatUsed = true
            fakeHeat = true
            applyHeat()
        }
        #endif
    }

    // MARK: - 過熱

    private var heatLevel: Int {
        #if targetEnvironment(simulator)
        if fakeHeat { return ProcessInfo.ThermalState.serious.rawValue }
        #endif
        return ProcessInfo.processInfo.thermalState.rawValue
    }

    private func applyHeat() {
        guard let job else { return }
        let limit: ProcessInfo.ThermalState = resolution == .uhd4K ? .serious : .critical
        var tooHot: Bool = heatLevel >= limit.rawValue && heatLevel > toleratedHeat
        #if targetEnvironment(simulator)
        // 模擬器的素材不會是 4K，測畫面用，1080p 也停。
        if fakeHeat { tooHot = heatLevel > toleratedHeat }
        #endif
        job.setPaused(tooHot)
        if isHot != tooHot { isHot = tooHot }
    }

    // MARK: - 檔案

    /// 沒寫完的檔用這個開頭。上次燒到一半被滑掉的，下次燒之前清掉。
    private static let tempPrefix = ".burning-"

    private func makeRoom(in folder: URL, at temp: URL, bytes: Int64) throws {
        let files = FileManager.default
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw CaptionBurnError.cannotWrite
        }
        let names: [String] = (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(Self.tempPrefix) {
            try? files.removeItem(at: folder.appendingPathComponent(name))
        }
        #if targetEnvironment(simulator)
        if UserDefaults.standard.bool(forKey: "debugBurnNoSpace") { throw CaptionBurnError.noSpace }
        #endif
        try Self.reserve(bytes, at: temp)
    }

    /// 畫面加聲音，再抓一成和 50 MB 的餘裕。
    private static func estimate(bitRate: Int, media: CaptionVideo.Media) -> Int64 {
        let bits: Double = (Double(bitRate) + 256_000) * media.duration.seconds
        return Int64(bits / 8 * 1.1) + 50_000_000
    }

    /// 跟系統要一塊這麼大的空間看給不給，要到就還回去。比讀剩餘空間的數字準，真的不夠才會說不夠。
    private static func reserve(_ bytes: Int64, at url: URL) throws {
        let file: Int32 = Darwin.open(url.path, O_CREAT | O_RDWR, 0o600)
        guard file >= 0 else {
            throw errno == ENOSPC ? CaptionBurnError.noSpace : CaptionBurnError.cannotWrite
        }
        var wanted = fstore_t(fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE,
                              fst_offset: 0, fst_length: off_t(bytes), fst_bytesalloc: 0)
        let isFull: Bool = fcntl(file, F_PREALLOCATE, &wanted) == -1 && errno == ENOSPC
        Darwin.close(file)
        // 寫檔器要自己建檔，不能留著。
        Darwin.unlink(url.path)
        if isFull { throw CaptionBurnError.noSpace }
    }

    /// 換上去之前先確認打得開、長度對。
    private static func verify(_ url: URL, duration: Double) async throws {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .video)
        let length: CMTime = try await asset.load(.duration)
        guard !tracks.isEmpty, length.isNumeric, length.seconds > duration - 0.5 else {
            throw CaptionBurnError.broken
        }
    }

    private static func swap(_ temp: URL, into output: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: output.path) {
            _ = try files.replaceItemAt(output, withItemAt: temp)
        } else {
            try files.moveItem(at: temp, to: output)
        }
    }

    private func describe(_ error: Error) -> String {
        if let known = error as? CaptionBurnError { return known.localizedDescription }
        if let known = error as? CaptionVideoError { return known.localizedDescription }
        if Self.isOutOfSpace(error as NSError) { return CaptionBurnError.noSpace.localizedDescription }
        let code: AVError.Code? = (error as? AVError)?.code
        if code == .operationInterrupted || code == .mediaServicesWereReset || wentToBackground {
            return CaptionBurnError.stoppedBySystem.localizedDescription
        }
        return "沒有燒成功：\(error.localizedDescription)"
    }

    private static func isOutOfSpace(_ error: NSError) -> Bool {
        if error.domain == AVFoundationErrorDomain, error.code == AVError.Code.diskFull.rawValue { return true }
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) { return true }
        guard let inner = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return isOutOfSpace(inner)
    }
}

// MARK: - 一次燒錄

/// 暫停與取消。
private final class CaptionBurnGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false

    /// 暫停中會等在這裡。取消了回 false。
    func pass() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while paused && !cancelled { condition.wait() }
        return !cancelled
    }

    var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    func setPaused(_ value: Bool) {
        condition.lock()
        paused = value
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }
}

/// 一條軌：寫檔器要多少就給多少。所有動作都在自己的佇列上，停下來之後一定不會再寫。
private final class CaptionBurnPump: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue: DispatchQueue
    private let step: () throws -> Bool
    // 以下只在 queue 用；error 在 run 回來之後才讀。
    private var ended = false
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var error: Error?

    /// step 寫一格，沒有了回 false。
    init(writer: AVAssetWriter, input: AVAssetWriterInput, name: String, step: @escaping () throws -> Bool) {
        self.writer = writer
        self.input = input
        self.step = step
        queue = DispatchQueue(label: "org.domyweb.broccolicam.burn.\(name)", qos: .userInitiated)
    }

    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.ended {
                    continuation.resume()
                    return
                }
                self.waiting = continuation
                self.input.requestMediaDataWhenReady(on: self.queue) {
                    self.feed()
                }
            }
        }
    }

    func stop() {
        queue.async { self.end() }
    }

    private func feed() {
        while !ended && input.isReadyForMoreMediaData {
            let more: Bool = autoreleasepool {
                do {
                    return try step()
                } catch {
                    self.error = error
                    return false
                }
            }
            if !more { end() }
        }
    }

    private func end() {
        guard !ended else { return }
        ended = true
        if writer.status == .writing { input.markAsFinished() }
        waiting?.resume()
        waiting = nil
    }
}

/// 讀原片、疊字幕、寫成一支。一個物件只燒一次。
private final class CaptionBurnJob: @unchecked Sendable {
    private let media: CaptionVideo.Media
    private let size: CGSize
    private let bitRate: Int
    private let overlay: CaptionOverlay
    private let output: URL
    private let onProgress: @Sendable (Double) -> Void
    private let gate = CaptionBurnGate()
    private let lock = NSLock()
    private var pumps: [CaptionBurnPump] = []

    /// onProgress 在寫檔的佇列上叫。
    init(media: CaptionVideo.Media, size: CGSize, bitRate: Int, overlay: CaptionOverlay, output: URL,
         onProgress: @escaping @Sendable (Double) -> Void) {
        self.media = media
        self.size = size
        self.bitRate = bitRate
        self.overlay = overlay
        self.output = output
        self.onProgress = onProgress
    }

    func setPaused(_ value: Bool) {
        gate.setPaused(value)
    }

    func cancel() {
        gate.cancel()
        // 寫檔器可能正好不要資料，叫醒每一條讓它收尾。
        stopPumps()
    }

    private func stopPumps() {
        let all: [CaptionBurnPump] = lock.withLock { pumps }
        for pump in all { pump.stop() }
    }

    func run() async throws {
        let reader = try AVAssetReader(asset: media.composition)
        guard let videoTrack = try await media.composition.loadTracks(withMediaType: .video).first else {
            throw CaptionBurnError.cannotRead
        }
        let frames = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: Self.bufferAttributes(size: nil))
        // 有字的那格會先複製才改，原本的不會被動到。
        frames.alwaysCopiesSampleData = false
        guard reader.canAdd(frames) else { throw CaptionBurnError.cannotRead }
        reader.add(frames)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = try addVideo(to: writer)
        let attributes: [String: Any] = Self.bufferAttributes(size: size)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
                                                           sourcePixelBufferAttributes: attributes)
        writer.add(videoInput)
        let sound = try await addSound(from: reader, to: writer)

        guard writer.startWriting() else { throw writer.error ?? CaptionBurnError.cannotWrite }
        guard let pool = adaptor.pixelBufferPool ?? Self.makePool(attributes) else {
            writer.cancelWriting()
            throw CaptionBurnError.cannotWrite
        }
        guard reader.startReading() else {
            let reason: Error = reader.error ?? CaptionBurnError.cannotRead
            writer.cancelWriting()
            throw reason
        }
        writer.startSession(atSourceTime: .zero)

        var made: [CaptionBurnPump] = [
            CaptionBurnPump(writer: writer, input: videoInput, name: "video",
                            step: videoStep(frames, adaptor: adaptor, writer: writer, pool: pool))
        ]
        if let sound {
            made.append(CaptionBurnPump(writer: writer, input: sound.input, name: "audio",
                                        step: soundStep(sound.source, input: sound.input, writer: writer)))
        }
        let all: [CaptionBurnPump] = made
        lock.withLock { pumps = all }
        // 建好之前就被取消的話，在這裡補停。
        if gate.isCancelled { stopPumps() }
        await runPumps(all, writer: writer)

        // 兩條都停了，這之後不會有人再讀寫。
        do {
            try check(all, reader: reader, writer: writer)
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        // 最後一格留到整支結束，長度才和原片一樣。
        writer.endSession(atSourceTime: media.duration)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CaptionBurnError.cannotWrite }
        if gate.isCancelled { throw CancellationError() }
        onProgress(1)
    }

    private func runPumps(_ all: [CaptionBurnPump], writer: AVAssetWriter) async {
        // 寫檔器中途壞掉時不會再來要資料，定時看一下，不然會永遠等下去。
        let watchdog = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if writer.status == .failed || writer.status == .cancelled {
                    self?.stopPumps()
                    return
                }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for pump in all {
                group.addTask {
                    await pump.run()
                    // 一條壞了，另一條也不用寫了。
                    if pump.error != nil { self.stopPumps() }
                }
            }
        }
        watchdog.cancel()
    }

    private func check(_ all: [CaptionBurnPump], reader: AVAssetReader, writer: AVAssetWriter) throws {
        if gate.isCancelled { throw CancellationError() }
        for pump in all {
            if let error = pump.error { throw error }
        }
        if writer.status != .writing { throw writer.error ?? CaptionBurnError.cannotWrite }
        // 讀到一半壞掉，看起來會像讀完。
        if reader.status == .failed { throw reader.error ?? CaptionBurnError.cannotRead }
    }

    // MARK: 畫面

    private func videoStep(_ frames: AVAssetReaderTrackOutput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
                           writer: AVAssetWriter, pool: CVPixelBufferPool) -> () throws -> Bool {
        let maker = CaptionFrameMaker(size: size, placements: media.placements, overlay: overlay, isPreview: false)
        let total: Double = max(0.001, media.duration.seconds)
        let gate = self.gate
        let onProgress = self.onProgress
        var last: CMTime = .invalid
        var shown: Double = 0
        return {
            guard gate.pass() else { return false }
            guard let sample = frames.copyNextSampleBuffer() else { return false }
            guard let source = CMSampleBufferGetImageBuffer(sample) else { return true }
            var time: CMTime = CMSampleBufferGetPresentationTimeStamp(sample)
            guard time.isNumeric else { return true }
            time = CMTimeMaximum(time, .zero)
            // 段和段的接縫可能有同一個時間的兩格，寫檔器不收倒退的時間。
            if last.isNumeric, time <= last { return true }

            let frame = try maker.frame(from: source, at: time.seconds) {
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
                return buffer
            }
            guard adaptor.append(frame, withPresentationTime: time) else {
                throw writer.error ?? CaptionBurnError.cannotWrite
            }
            last = time
            // 檔案收尾還要一點時間，先不到 100%。
            let fraction: Double = min(0.99, time.seconds / total)
            if fraction - shown >= 0.005 {
                shown = fraction
                onProgress(fraction)
            }
            return true
        }
    }

    private func addVideo(to writer: AVAssetWriter) throws -> AVAssetWriterInput {
        #if targetEnvironment(simulator)
        // 模擬器不一定有 HEVC 編碼器。
        let codecs: [AVVideoCodecType] = [.h264]
        #else
        let codecs: [AVVideoCodecType] = [.hevc, .h264]
        #endif
        for codec in codecs {
            let settings: [String: Any] = videoSettings(codec)
            guard writer.canApply(outputSettings: settings, forMediaType: .video) else { continue }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { return input }
        }
        throw CaptionBurnError.cannotWrite
    }

    private func videoSettings(_ codec: AVVideoCodecType) -> [String: Any] {
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoExpectedSourceFrameRateKey: media.fps,
            AVVideoMaxKeyFrameIntervalDurationKey: 2
        ]
        let color: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: color
        ]
    }

    /// 1080p 30 格約 14 Mbps、60 格約 24，4K 30 格約 41、60 格約 71。
    /// 沒有縮小的時候，給到原片的 1.3 倍就夠了，再多只是檔案大。
    static func bitRate(for media: CaptionVideo.Media, size: CGSize) -> Int {
        let pixels: Double = Double(size.width * size.height) * Double(media.fps)
        let target: Double = 14_000_000 * pow(pixels / 62_208_000, 0.78)
        let isSameSize: Bool = abs(size.width - media.size.width) < 2
        guard isSameSize, media.sourceBitRate > 0 else { return Int(target) }
        return Int(min(target, max(6_000_000, media.sourceBitRate * 1.3)))
    }

    private static func bufferAttributes(size: CGSize?) -> [String: Any] {
        var attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: CaptionFrameMaker.pixelFormat),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: NSNumber(value: true)
        ]
        if let size {
            attributes[kCVPixelBufferWidthKey as String] = NSNumber(value: Int(size.width))
            attributes[kCVPixelBufferHeightKey as String] = NSNumber(value: Int(size.height))
        }
        return attributes
    }

    private static func makePool(_ attributes: [String: Any]) -> CVPixelBufferPool? {
        var made: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &made)
        return status == kCVReturnSuccess ? made : nil
    }

    // MARK: 聲音

    private struct Sound {
        let source: AVAssetReaderOutput
        let input: AVAssetWriterInput
    }

    private func soundStep(_ source: AVAssetReaderOutput, input: AVAssetWriterInput,
                           writer: AVAssetWriter) -> () throws -> Bool {
        let gate = self.gate
        return {
            guard gate.pass() else { return false }
            guard let sample = source.copyNextSampleBuffer() else { return false }
            guard input.append(sample) else { throw writer.error ?? CaptionBurnError.cannotWrite }
            return true
        }
    }

    private func addSound(from reader: AVAssetReader, to writer: AVAssetWriter) async throws -> Sound? {
        guard let info = media.audio else { return nil }
        let tracks: [AVAssetTrack] = try await media.composition.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { return nil }

        if info.canPassThrough {
            let formats: [CMFormatDescription] = try await track.load(.formatDescriptions)
            let source = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            source.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: formats.first)
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(source), writer.canAdd(input) {
                reader.add(source)
                writer.add(input)
                return Sound(source: source, input: input)
            }
        }

        // 有裁切或好幾段時，壓縮過的聲音切不準接縫，解開重壓才不會有爆音、也不會慢慢偏掉。
        // 用混音的讀法，中間沒有聲音的地方會補成無聲。
        let decoded: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: info.sampleRate,
            AVNumberOfChannelsKey: info.channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let encoded: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: info.sampleRate,
            AVNumberOfChannelsKey: info.channels,
            AVEncoderBitRateKey: info.channels == 1 ? 128_000 : 192_000
        ]
        let source = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: decoded)
        source.alwaysCopiesSampleData = false
        guard reader.canAdd(source), writer.canApply(outputSettings: encoded, forMediaType: .audio) else {
            throw CaptionBurnError.noSound
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: encoded)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw CaptionBurnError.noSound }
        reader.add(source)
        writer.add(input)
        return Sound(source: source, input: input)
    }
}

// MARK: - 切到背景

/// 系統給的、可以在背景繼續做的任務。
@MainActor
private protocol CaptionContinuedBurn: AnyObject {
    /// 系統真的開始了、也還沒收回去。
    var isRunning: Bool { get }
    func report(_ fraction: Double)
    func finish(success: Bool)
}

/// 切出去之後盡量做完。iOS 26 有系統的進度列可以一直做；舊系統只有短短一段時間。
@MainActor
private final class CaptionBurnKeeper {
    private let onExpire: () -> Void
    private var continued: CaptionContinuedBurn?
    private var assertion: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []

    init(onExpire: @escaping () -> Void) {
        self.onExpire = onExpire
    }

    func start() {
        #if compiler(>=6.2) && !targetEnvironment(simulator)
        if #available(iOS 26.0, *) {
            continued = CaptionContinuedTask.begin { [weak self] in
                self?.onExpire()
            }
        }
        #endif
        let center = NotificationCenter.default
        observers = [
            // 要在真的進背景之前先要到時間，進去才要可能來不及。
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hold() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.release() }
            }
        ]
    }

    func report(_ fraction: Double) {
        continued?.report(fraction)
    }

    func finish(success: Bool) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        continued?.finish(success: success)
        continued = nil
        release()
    }

    private func hold() {
        guard assertion == .invalid else { return }
        assertion = UIApplication.shared.beginBackgroundTask(withName: "burn") { [weak self] in
            self?.timeIsUp()
        }
    }

    private func release() {
        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
    }

    private func timeIsUp() {
        // 系統的進度列還在做就不用停。
        if continued?.isRunning != true { onExpire() }
        // 不還回去會被系統整個關掉。
        release()
    }
}

#if compiler(>=6.2) && !targetEnvironment(simulator)
/// iOS 26 的背景任務，系統會顯示進度列。iPhone 在背景不給用顯示晶片，所以不要求。
@available(iOS 26.0, *)
@MainActor
private final class CaptionContinuedTask: CaptionContinuedBurn {
    private let identifier: String
    private let onExpire: () -> Void
    private var task: BGContinuedProcessingTask?
    private var ended = false
    private var fraction: Double = 0

    var isRunning: Bool { task != nil && !ended }

    /// 系統現在不給就回 nil，照舊系統的方式做。
    static func begin(onExpire: @escaping () -> Void) -> CaptionContinuedTask? {
        // 同一個名字只能登記一次，每次燒都用新的。Info.plist 裡登記的是 burn.*。
        let bundle: String = Bundle.main.bundleIdentifier ?? "org.domyweb.broccolicam"
        let name: String = "\(bundle).burn.\(UUID().uuidString)"
        let made = CaptionContinuedTask(identifier: name, onExpire: onExpire)
        let registered: Bool = BGTaskScheduler.shared.register(forTaskWithIdentifier: name,
                                                               using: DispatchQueue.main) { launched in
            MainActor.assumeIsolated { made.launched(launched) }
        }
        // 沒登記成功還送出去會閃退。
        guard registered else { return nil }
        let request = BGContinuedProcessingTaskRequest(identifier: name, title: "燒字幕", subtitle: "正在輸出影片")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return made
        } catch {
            return nil
        }
    }

    private init(identifier: String, onExpire: @escaping () -> Void) {
        self.identifier = identifier
        self.onExpire = onExpire
    }

    private func launched(_ started: BGTask) {
        guard !ended, let continuing = started as? BGContinuedProcessingTask else {
            started.setTaskCompleted(success: ended)
            return
        }
        task = continuing
        continuing.progress.totalUnitCount = 1000
        continuing.progress.completedUnitCount = Int64(fraction * 1000)
        // 哪個執行緒叫的不一定，標成 Sendable 再回主執行緒。
        continuing.expirationHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                self?.expired()
            }
        }
    }

    private func expired() {
        guard !ended else { return }
        ended = true
        task?.setTaskCompleted(success: false)
        task = nil
        onExpire()
    }

    func report(_ value: Double) {
        fraction = value
        task?.progress.completedUnitCount = Int64(value * 1000)
    }

    func finish(success: Bool) {
        guard !ended else { return }
        ended = true
        if let task {
            task.setTaskCompleted(success: success)
            self.task = nil
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
    }
}
#endif
