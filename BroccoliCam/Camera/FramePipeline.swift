import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import QuartzCore

/// 影格處理：收 AVCaptureVideoDataOutput 的影格，套 LookParams，交給錄影和預覽。
/// 影格一律在 videoQueue 處理；設定值從別的執行緒進來，用鎖交接。
///
/// 影格已經由連線轉成直式（角度跟著 RotationCoordinator，iPhone 17 和舊機型差 90 度都在那裡處理掉）。
final class FramePipeline: NSObject {
    struct Counts {
        var frames = 0
        /// 處理不及，被相機丟掉的影格
        var late = 0
    }

    let videoQueue = DispatchQueue(label: "org.domyweb.broccolicam.video", qos: .userInitiated,
                                   autoreleaseFrequency: .workItem)
    let renderer = MetalPreviewRenderer()

    /// 一個在等原始影格的人。
    private final class SampleRequest {
        let after: CMTime?
        let semaphore = DispatchSemaphore(value: 0)
        var sample: LookSample?

        init(after: CMTime?) {
            self.after = after
        }
    }

    /// 別的執行緒會改的設定。
    private struct Settings {
        var look = LookParams.neutral
        var lookEnabled = false
        var bypassed = false
        var stabilized = false
        var mirrored = false
        /// App 在背景不能用 GPU。
        var gpuAllowed = true
        /// 過熱，降噪和柔膚先不做。
        var heavySkipped = false
        /// 錄影中算不完，這一段剩下的時間降噪和柔膚都不做。
        var tooSlow = false

        var skipsHeavy: Bool { heavySkipped || tooSlow }

        /// 這組設定會動到畫面（按住比對的時候也算，才不會在原生預覽和處理過的預覽之間跳來跳去）。
        var changesPixels: Bool { lookEnabled && !look.needsNoPixelWork }
        var needsMetal: Bool { CameraGPU.isAvailable && (stabilized || changesPixels) }
    }

    /// 臉的目標位置（0…1，原點左上，影格座標）和最後看到的時間。
    private struct FaceTarget {
        var rect: CGRect
        var seenAt: CFTimeInterval
    }

    private let lock = NSLock()
    // 以下都在 lock 裡面讀寫
    private var settings = Settings()
    private var faceTarget: FaceTarget?
    private var currentRecorder: FrameRecorder?
    private var requests: [SampleRequest] = []
    private var counts = Counts()
    private var lastFrameSize: CGSize = .zero
    /// 錄影中每一秒統計一次來不及的影格。
    private var paceStart: CFTimeInterval = 0
    private var paceFrames = 0
    private var paceLate = 0
    private var lastFrameAt: CFTimeInterval = 0
    private var lastFrameTime: CMTime = .invalid

    // 以下只在 videoQueue 用
    /// 第一次用到才建（要算幾張色表），不拖慢開 App。
    private lazy var filter = LookFilter()
    private var smoothedFace: CGRect?
    private var faceStrength: CGFloat = 0

    /// 錄影中算不完、開始略過降噪和柔膚（videoQueue 回呼，只能做「丟到別的佇列」）。
    var onTooSlow: (() -> Void)?

    /// 臉不見多久之後才開始淡出柔膚（秒）。
    private static let faceHold: CFTimeInterval = 1.2

    // MARK: - 設定（任何執行緒）

    private func update(_ change: (inout Settings) -> Void) {
        lock.lock()
        change(&settings)
        lock.unlock()
    }

    private var snapshot: Settings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    func setLook(_ params: LookParams, enabled: Bool) {
        update { settings in
            settings.look = params
            settings.lookEnabled = enabled
        }
    }

    func setBypassed(_ on: Bool) {
        update { $0.bypassed = on }
    }

    func setStabilized(_ on: Bool) {
        update { $0.stabilized = on }
    }

    func setMirrored(_ on: Bool) {
        update { $0.mirrored = on }
    }

    func setGPUAllowed(_ on: Bool) {
        update { $0.gpuAllowed = on }
    }

    func setHeavySkipped(_ on: Bool) {
        update { $0.heavySkipped = on }
    }

    var isMirrored: Bool { snapshot.mirrored }
    /// 需不需要用處理過的畫面當預覽。
    var needsMetalPreview: Bool { snapshot.needsMetal }
    /// 現在開著的參數裡有沒有過熱時會略過的項目。
    var usesHeavyFilters: Bool {
        let now = snapshot
        return now.lookEnabled && LookFilter.usesHeavy(now.look)
    }

    /// 臉的位置。rect 是 0…1、原點左上的影格座標；nil 代表這次沒看到。
    func setFace(_ rect: CGRect?) {
        guard let rect else { return }
        lock.lock()
        faceTarget = FaceTarget(rect: rect, seenAt: CACurrentMediaTime())
        lock.unlock()
    }

    /// 影格的大小（直式）。還沒收到影格是 nil。
    var frameSize: CGSize? {
        lock.lock()
        defer { lock.unlock() }
        return lastFrameSize.width > 0 ? lastFrameSize : nil
    }

    /// 換格式了，舊的大小不能再用來開錄影檔。
    func forgetFrameSize() {
        lock.lock()
        lastFrameSize = .zero
        lock.unlock()
    }

    /// 最後一張影格的時間，除錯層用。還沒收到是 nil。
    var lastTime: CMTime? {
        lock.lock()
        defer { lock.unlock() }
        return lastFrameTime.isNumeric ? lastFrameTime : nil
    }

    #if targetEnvironment(simulator)
    /// 現在大概是影格時間的什麼時候。
    var estimatedTime: CMTime? {
        lock.lock()
        defer { lock.unlock() }
        guard lastFrameTime.isNumeric else { return nil }
        let passed: Double = CACurrentMediaTime() - lastFrameAt
        return lastFrameTime + CMTime(seconds: passed, preferredTimescale: 90000)
    }
    #endif

    var currentCounts: Counts {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    /// 最近一秒內有沒有影格進來。
    var hasRecentFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastFrameAt > 0 && CACurrentMediaTime() - lastFrameAt < 1
    }

    // MARK: - 錄影（任何執行緒）

    var recorder: FrameRecorder? {
        lock.lock()
        defer { lock.unlock() }
        return currentRecorder
    }

    /// 還在收影格。收尾寫檔的期間不算。
    var isRecording: Bool {
        recorder?.isActive ?? false
    }

    func setRecorder(_ next: FrameRecorder) {
        lock.lock()
        currentRecorder = next
        settings.tooSlow = false
        // 剛開錄的第一秒本來就會掉幾格，不算。
        paceStart = CACurrentMediaTime() + 1
        paceFrames = 0
        paceLate = 0
        lock.unlock()
    }

    /// 這支錄完了，放掉。中間如果已經換成新的一支就不動。
    func clearRecorder(_ old: FrameRecorder) {
        lock.lock()
        if currentRecorder === old {
            currentRecorder = nil
            settings.tooSlow = false
        }
        lock.unlock()
    }

    /// 每進來（或丟掉）一格記一次，一秒結算：來不及超過 5% 而且開著吃重的處理，就先不做那些。
    /// 一段錄影裡不再自動打開，免得畫面一下有一下沒有。
    private func notePace(late: Bool) {
        lock.lock()
        let now = CACurrentMediaTime()
        guard currentRecorder != nil, !settings.tooSlow, now >= paceStart else {
            lock.unlock()
            return
        }
        if late {
            paceLate += 1
        } else {
            paceFrames += 1
        }
        guard now - paceStart >= 1 else {
            lock.unlock()
            return
        }
        let total = paceFrames + paceLate
        let slow = total >= 10 && Double(paceLate) > Double(total) * 0.05
        paceStart = now
        paceFrames = 0
        paceLate = 0
        let skip = slow && settings.lookEnabled && LookFilter.usesHeavy(settings.look)
        if skip { settings.tooSlow = true }
        lock.unlock()
        if skip { onTooSlow?() }
    }

    // MARK: - 取一張原始影格（分析用）

    /// 等下一張（晚於 after 的）原始影格，縮小後回傳。會擋住呼叫的執行緒，不可以在主執行緒或 videoQueue 呼叫。
    func grabSample(after: CMTime?, timeout: TimeInterval) -> LookSample? {
        let request = SampleRequest(after: after)
        lock.lock()
        requests.append(request)
        lock.unlock()
        if request.semaphore.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock()
            requests.removeAll { $0 === request }
            lock.unlock()
            return nil
        }
        return request.sample
    }

    private func takeRequests(at time: CMTime) -> [SampleRequest] {
        lock.lock()
        defer { lock.unlock() }
        guard !requests.isEmpty else { return [] }
        var ready: [SampleRequest] = []
        var waiting: [SampleRequest] = []
        for request in requests {
            if let after = request.after, time <= after {
                waiting.append(request)
            } else {
                ready.append(request)
            }
        }
        requests = waiting
        return ready
    }

    private func serveRequests(_ pixelBuffer: CVPixelBuffer, at time: CMTime, gpuAllowed: Bool) {
        let ready = takeRequests(at: time)
        guard !ready.isEmpty else { return }
        let sample: LookSample? = gpuAllowed ? makeSample(pixelBuffer) : nil
        for request in ready {
            request.sample = sample
            request.semaphore.signal()
        }
    }

    /// 縮到長邊約 256，讀成 RGB。畫進 BGRA 的緩衝區再讀，第一列一定是畫面最上面。
    private func makeSample(_ pixelBuffer: CVPixelBuffer) -> LookSample? {
        guard let context = CameraGPU.context else { return nil }
        let fullWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let fullHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard fullWidth >= 16, fullHeight >= 16 else { return nil }
        let scale: CGFloat = min(1, 256 / max(fullWidth, fullHeight))
        let width = max(8, Int((fullWidth * scale).rounded()))
        let height = max(8, Int((fullHeight * scale).rounded()))

        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: NSNumber(value: true)
        ]
        var made: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary, &made)
        guard status == kCVReturnSuccess, let buffer = made else { return nil }

        let transform = CGAffineTransform(scaleX: CGFloat(width) / fullWidth, y: CGFloat(height) / fullHeight)
        let small: CIImage = CameraGPU.image(pixelBuffer)
            .clampedToExtent()
            .transformed(by: transform, highQualityDownsample: true)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.render(small.cropped(to: bounds), to: buffer, bounds: bounds, colorSpace: CameraGPU.colorSpace)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        var index = 0
        for y in 0..<height {
            let row = bytes + y * rowBytes
            for x in 0..<width {
                let pixel = row + x * 4
                pixels[index] = pixel[2]
                pixels[index + 1] = pixel[1]
                pixels[index + 2] = pixel[0]
                index += 3
            }
        }
        return LookSample(pixels: pixels, width: width, height: height, face: recentFace())
    }

    private func recentFace() -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        guard let target = faceTarget, CACurrentMediaTime() - target.seenAt < Self.faceHold else { return nil }
        return target.rect
    }

    // MARK: - 每一格（videoQueue）

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time: CMTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))

        lock.lock()
        counts.frames += 1
        lastFrameSize = size
        lastFrameAt = CACurrentMediaTime()
        lastFrameTime = time
        let now: Settings = settings
        let recorder: FrameRecorder? = currentRecorder
        lock.unlock()

        notePace(late: false)
        let canDraw: Bool = now.gpuAllowed && CameraGPU.isAvailable
        serveRequests(pixelBuffer, at: time, gpuAllowed: canDraw)
        updateFace()

        let filtering: Bool = canDraw && now.changesPixels
            && LookFilter.hasWork(now.look, skipHeavy: now.skipsHeavy)
        // 按住比對只影響預覽，錄下來的不能跟著變。
        let compareOnly: Bool = filtering && now.bypassed

        // 已經算好、可以直接拿去預覽的那張（原點在 0,0、直立）。
        var finished: CIImage?
        if let recorder, let ticket = recorder.ticket(at: time) {
            let sameSize = Int(size.width) == ticket.width && Int(size.height) == ticket.height
            if !filtering && ticket.turn == 0 && sameSize {
                // 不用處理就原封不動寫進去：零 GPU，畫質和相機給的一樣。
                recorder.append(pixelBuffer, at: time)
                finished = CameraGPU.image(pixelBuffer)
            } else if canDraw, let output = render(pixelBuffer, ticket: ticket, settings: now, filtering: filtering) {
                recorder.append(output, at: time)
                // 橫式錄影的成品是轉過的，預覽要轉回直立。
                finished = compareOnly ? nil : Self.turned(CameraGPU.image(output), by: -ticket.turn)
            } else {
                recorder.noteRenderFailure()
            }
        }

        guard canDraw, now.needsMetal, let target = renderer.availableSize() else { return }
        let image: CIImage
        if let finished {
            image = finished
        } else {
            image = previewImage(pixelBuffer, size: size, target: target, settings: now,
                                 filtering: filtering && !now.bypassed)
        }
        // 預覽一律是鏡像（和原生預覽一樣）。輸出已經鏡像就不用再翻。
        renderer.submit(image, mirrored: !now.mirrored)
    }

    /// 沒在錄影時的預覽：先縮到預覽框的大小再套濾鏡，4K 和小窗都不用算滿整張。
    private func previewImage(_ pixelBuffer: CVPixelBuffer, size: CGSize, target: CGSize,
                              settings: Settings, filtering: Bool) -> CIImage {
        let source = CameraGPU.image(pixelBuffer)
        guard filtering else { return source }
        let shortSide: CGFloat = min(size.width, size.height)
        let targetShort: CGFloat = min(target.width, target.height)
        let wanted: CGFloat = min(1, max(0.2, targetShort / shortSide))
        // 差不多大就不縮，省一道取樣。
        let factor: CGFloat = wanted > 0.9 ? 1 : wanted
        guard factor < 1 else {
            return filtered(source, settings: settings)
        }
        let extent = CGRect(x: 0, y: 0, width: (size.width * factor).rounded(.down),
                            height: (size.height * factor).rounded(.down))
        let small: CIImage = source
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            .cropped(to: extent)
        return filtered(small, settings: settings)
    }

    private func filtered(_ image: CIImage, settings: Settings) -> CIImage {
        let extent: CGRect = image.extent
        let scale: CGFloat = min(extent.width, extent.height) / 1080
        return filter.apply(settings.look, to: image, face: face(in: extent.size), scale: scale,
                            skipHeavy: settings.skipsHeavy)
    }

    /// 錄影用：套處理、轉到成品方向、畫進寫檔器的緩衝區。
    private func render(_ pixelBuffer: CVPixelBuffer, ticket: FrameRecorder.Ticket,
                        settings: Settings, filtering: Bool) -> CVPixelBuffer? {
        guard let context = CameraGPU.context else { return nil }
        var made: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, ticket.pool, &made)
        guard status == kCVReturnSuccess, let output = made else { return nil }

        let source = CameraGPU.image(pixelBuffer)
        var image: CIImage = source
        if filtering {
            image = filtered(image, settings: settings)
        }
        image = Self.turned(image, by: ticket.turn)
        let bounds = CGRect(x: 0, y: 0, width: ticket.width, height: ticket.height)
        image = Self.filled(image, in: bounds)

        // 色彩標籤跟原始影格完全一樣，同一支影片裡處理過和沒處理過的影格才會無縫。
        // 先標再畫：Core Image 靠標籤決定 RGB 轉 YCbCr 用哪個矩陣。
        Self.copyColorTags(from: pixelBuffer, to: output)
        context.render(image, to: output, bounds: bounds, colorSpace: CameraGPU.colorSpace)
        Self.copyColorTags(from: pixelBuffer, to: output)
        return output
    }

    // MARK: - 臉

    /// 位置慢慢跟上、出現和消失慢慢變化，柔膚才不會跳。
    private func updateFace() {
        lock.lock()
        let target: FaceTarget? = faceTarget
        lock.unlock()
        let visible: Bool
        if let target {
            visible = CACurrentMediaTime() - target.seenAt < Self.faceHold
        } else {
            visible = false
        }
        if visible, let target {
            if let current = smoothedFace, faceStrength > 0 {
                smoothedFace = Self.blend(current, target.rect, 0.2)
            } else {
                smoothedFace = target.rect
            }
            faceStrength = min(1, faceStrength + 0.06)
        } else {
            faceStrength = max(0, faceStrength - 0.06)
        }
    }

    private func face(in size: CGSize) -> LookFace? {
        guard let rect = smoothedFace, faceStrength > 0 else { return nil }
        let width: CGFloat = rect.width * size.width
        let height: CGFloat = rect.height * size.height
        // 轉成 Core Image 的座標：原點在左下。
        let x: CGFloat = rect.minX * size.width
        let y: CGFloat = (1 - rect.maxY) * size.height
        return LookFace(rect: CGRect(x: x, y: y, width: width, height: height), strength: faceStrength)
    }

    private static func blend(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t,
               y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t,
               height: a.height + (b.height - a.height) * t)
    }

    // MARK: - 影像工具

    /// 順時針轉 degrees 度，結果的原點在 (0, 0)。
    /// CGImagePropertyOrientation.right 的意思就是「要順時針轉 90 度才會正」。
    static func turned(_ image: CIImage, by degrees: Int) -> CIImage {
        let orientation: CGImagePropertyOrientation
        switch degrees {
        case 90: orientation = .right
        case -90: orientation = .left
        case 180, -180: orientation = .down
        default: return image
        }
        let rotated: CIImage = image.oriented(orientation)
        let origin: CGPoint = rotated.extent.origin
        if origin == CGPoint.zero { return rotated }
        return rotated.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    /// 尺寸不一樣時等比例填滿、置中裁掉（正常不會發生，保險用）。
    private static func filled(_ image: CIImage, in bounds: CGRect) -> CIImage {
        let extent: CGRect = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        if abs(extent.width - bounds.width) < 1 && abs(extent.height - bounds.height) < 1 { return image }
        let scale: CGFloat = max(bounds.width / extent.width, bounds.height / extent.height)
        let moveX: CGFloat = (bounds.width - extent.width * scale) / 2 - extent.minX * scale
        let moveY: CGFloat = (bounds.height - extent.height * scale) / 2 - extent.minY * scale
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: moveX, ty: moveY)
        return image.transformed(by: transform).cropped(to: bounds)
    }

    /// 原始影格沒有標就標成 709。
    private static func copyColorTags(from source: CVPixelBuffer, to target: CVPixelBuffer) {
        let tags: [(key: CFString, fallback: CFString)] = [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        ]
        for tag in tags {
            let value: CFTypeRef = CVBufferCopyAttachment(source, tag.key, nil) ?? tag.fallback
            CVBufferSetAttachment(target, tag.key, value, .shouldPropagate)
        }
    }
}

// MARK: - 影格回呼

extension FramePipeline: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        handle(sampleBuffer)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        lock.lock()
        counts.late += 1
        lock.unlock()
        notePace(late: true)
    }
}
