import AVFoundation
import CoreImage
import CoreVideo
import UIKit
import VideoToolbox

enum CaptionVideoError: LocalizedError {
    case noVideo
    case notPrepared
    case cannotDraw

    var errorDescription: String? {
        switch self {
        case .noVideo: return "影片讀不到畫面。"
        case .notPrepared: return "影片還沒準備好。"
        case .cannotDraw: return "字幕畫不到畫面上。"
        }
    }
}

/// 一支要上字幕的影片：各段接在同一條時間軸，播放時字幕即時疊上。
/// 預覽和燒錄用同一個 CaptionFrameMaker，看到的就是會燒的。
///
/// 執行緒：prepare、update 哪裡都能叫；playerItem 在主執行緒。會變的東西用鎖交接。
final class CaptionVideo: @unchecked Sendable {
    /// 準備好的東西，建好就不再改。
    struct Media {
        let composition: AVMutableComposition
        let trackID: CMPersistentTrackID
        let duration: CMTime
        let offsets: [Double]
        let durations: [Double]
        let placements: [CaptionFrameMaker.Placement]
        /// 轉正之後的大小。
        let size: CGSize
        let is4K: Bool
        let fps: Int
        /// 來源畫面的位元率（每秒幾個位元），讀不到是 0。
        let sourceBitRate: Double
        let audio: Audio?
    }

    struct Audio {
        let sampleRate: Double
        let channels: Int
        /// 整支沒裁、只有一段 AAC，可以原封不動搬過去。
        let canPassThrough: Bool
    }

    let isLandscape: Bool
    private let clips: [VideoStitcher.Clip]
    /// 預覽用的字幕。燒錄用自己的一份，燒到一半改字不會混在一起。
    private let overlay = CaptionOverlay()
    private let lock = NSLock()
    private var loaded: Media?
    private var refreshQueued = false
    @MainActor private weak var currentItem: AVPlayerItem?

    init(clips: [(url: URL, start: Double?, end: Double?)], isLandscape: Bool) {
        self.clips = clips.map { VideoStitcher.Clip(url: $0.url, start: $0.start, end: $0.end) }
        self.isLandscape = isLandscape
    }

    // MARK: - 準備

    private var current: Media? {
        lock.withLock { loaded }
    }

    /// 準備好了才有。燒錄用。
    func media() throws -> Media {
        guard let media = current else { throw CaptionVideoError.notPrepared }
        return media
    }

    /// 總長（秒）。還沒 prepare 是 0。
    var duration: Double { current?.duration.seconds ?? 0 }
    /// 各段在整支影片裡的起點和長度（秒）。還沒 prepare 是空的。
    var offsets: [Double] { current?.offsets ?? [] }
    var durations: [Double] { current?.durations ?? [] }
    /// 每一段都是 4K 才算，才給選 4K 輸出。
    var is4K: Bool { current?.is4K ?? false }

    /// 輸出的大小。不放大；寬高一律偶數。
    func pixelSize(_ resolution: CaptionResolution) throws -> CGSize {
        let media: Media = try self.media()
        return Self.outputSize(of: media, resolution: resolution)
    }

    private static func outputSize(of media: Media, resolution: CaptionResolution) -> CGSize {
        let target: CGFloat = resolution == .uhd4K && media.is4K ? 2160 : 1080
        let short: CGFloat = min(media.size.width, media.size.height)
        let scale: CGFloat = min(1, target / max(1, short))
        return CGSize(width: even(media.size.width * scale), height: even(media.size.height * scale))
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(16, (value / 2).rounded() * 2)
    }

    func prepare() async throws {
        if current != nil { return }
        let built = try await VideoStitcher.composition(clips)
        guard let track = try await built.composition.loadTracks(withMediaType: .video).first else {
            throw CaptionVideoError.noVideo
        }
        let duration: CMTime = try await built.composition.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else { throw CaptionVideoError.noVideo }

        var placements: [CaptionFrameMaker.Placement] = []
        var size = CGSize.zero
        var is4K = true
        var fps: Float = 0
        var bitRate: Double = 0
        var rates: [Double] = []
        var channels = 0
        var audioClips = 0
        var isAAC = true
        var isTrimmed = false

        for (index, clip) in clips.enumerated() {
            let asset = AVURLAsset(url: clip.url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw CaptionVideoError.noVideo
            }
            let natural: CGSize = try await video.load(.naturalSize)
            let transform: CGAffineTransform = try await video.load(.preferredTransform)
            let range: CMTimeRange = try await video.load(.timeRange)
            let frameRate: Float = try await video.load(.nominalFrameRate)
            let dataRate: Float = try await video.load(.estimatedDataRate)
            fps = max(fps, frameRate)
            bitRate = max(bitRate, Double(dataRate))
            placements.append(CaptionFrameMaker.Placement(start: built.offsets[index], transform: transform))

            let turned: CGRect = CGRect(origin: .zero, size: natural).applying(transform)
            let upright = CGSize(width: abs(turned.width), height: abs(turned.height))
            if upright.width * upright.height > size.width * size.height { size = upright }
            if max(upright.width, upright.height) < 3840 { is4K = false }
            // 一個 600 分之一秒的誤差不算裁。
            if range.duration.seconds - built.durations[index] > 0.005 { isTrimmed = true }

            guard let sound = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            audioClips += 1
            let formats: [CMFormatDescription] = try await sound.load(.formatDescriptions)
            for format in formats {
                guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { continue }
                rates.append(basic.mSampleRate)
                channels = max(channels, Int(basic.mChannelsPerFrame))
                if basic.mFormatID != kAudioFormatMPEG4AAC { isAAC = false }
            }
        }
        guard size.width >= 16, size.height >= 16 else { throw CaptionVideoError.noVideo }

        var audio: Audio?
        if audioClips > 0 {
            // 各段一樣就照原本的取樣率，不一樣統一成 48k。
            let same: Bool = Set(rates).count == 1 && (rates[0] == 44100 || rates[0] == 48000)
            audio = Audio(sampleRate: same ? rates[0] : 48000,
                          channels: min(2, max(1, channels)),
                          canPassThrough: clips.count == 1 && !isTrimmed && isAAC)
        }
        let rounded: Int = fps > 0 ? Int(fps.rounded()) : 30
        let media = Media(composition: built.composition, trackID: track.trackID, duration: duration,
                          offsets: built.offsets, durations: built.durations, placements: placements,
                          size: size, is4K: is4K, fps: min(120, max(1, rounded)),
                          sourceBitRate: bitRate, audio: audio)
        lock.withLock {
            // 同時準備兩次的話，留先好的那一份。
            if loaded == nil { loaded = media }
        }
    }

    // MARK: - 播放

    /// 給播放器用的。預覽一律 1080p，4K 來源播起來才不會卡；字級照寬度比例，和 4K 成品一樣。
    @MainActor
    func playerItem() async throws -> AVPlayerItem {
        try await prepare()
        let media: Media = try self.media()
        let item = AVPlayerItem(asset: media.composition)
        item.videoComposition = makeVideoComposition(media)
        currentItem = item
        return item
    }

    private func makeVideoComposition(_ media: Media) -> AVVideoComposition {
        let size = Self.outputSize(of: media, resolution: .hd1080)
        let maker = CaptionFrameMaker(size: size, placements: media.placements, overlay: overlay, isPreview: true)
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = CaptionCompositor.self
        composition.renderSize = size
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(media.fps))
        // 每一格的時間照來源，錄影時掉過格也不會重新排。
        composition.sourceTrackIDForFrameTiming = media.trackID
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        composition.instructions = [
            CaptionInstruction(timeRange: CMTimeRange(start: .zero, duration: media.duration),
                               trackID: media.trackID, maker: maker)
        ]
        return composition
    }

    /// 換字幕或樣式。播放中下一格就生效，暫停中會把停著的這一格重畫。
    func update(lines: [CaptionLine], style: CaptionStyle) {
        guard overlay.set(lines: lines, style: style) else { return }
        let needsQueue: Bool = lock.withLock {
            if refreshQueued { return false }
            refreshQueued = true
            return true
        }
        // 連續改好幾個地方只重畫一次。
        guard needsQueue else { return }
        Task { @MainActor in
            self.lock.withLock { self.refreshQueued = false }
            self.refresh()
        }
    }

    /// 停著的時候播放器不會再要新的一格，要換一份新的 videoComposition 才會重畫。
    /// 播放中不換，換了會頓一下。
    @MainActor
    func refresh() {
        guard let media = current, let item = currentItem else { return }
        if let timebase = item.timebase, CMTimebaseGetRate(timebase) != 0 { return }
        item.videoComposition = makeVideoComposition(media)
    }
}

// MARK: - 字幕

/// 現在有哪些字幕。改的人和畫的人在不同執行緒，用鎖交接。
final class CaptionOverlay: @unchecked Sendable {
    private struct Entry: Equatable {
        let start: Double
        let end: Double
        let text: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var style = CaptionStyle()

    /// 隱藏的、空的不會畫。沒有變化回 false。
    @discardableResult
    func set(lines: [CaptionLine], style newStyle: CaptionStyle) -> Bool {
        let fresh: [Entry] = lines
            .filter { !$0.isHidden && !$0.text.isEmpty && $0.end > $0.start }
            .sorted { $0.start < $1.start }
            .map { Entry(start: $0.start, end: $0.end, text: $0.text) }
        return lock.withLock {
            if fresh == entries && newStyle == style { return false }
            entries = fresh
            style = newStyle
            return true
        }
    }

    /// 這個時間要畫哪一句。句子不該重疊，重疊了就畫後開始的那句。
    func caption(at seconds: Double) -> (text: String, style: CaptionStyle)? {
        // 影格時間和句子時間各自四捨五入過，差不到一毫秒算同一刻。
        let time = seconds + 0.0008
        return lock.withLock {
            guard let entry = entries.last(where: { $0.start <= time && time < $0.end }) else { return nil }
            return (entry.text, style)
        }
    }
}

// MARK: - 一格

/// 進背景之後不能用顯示晶片，用了影格會壞掉。
final class CaptionGPUAccess: @unchecked Sendable {
    static let shared = CaptionGPUAccess()

    private let lock = NSLock()
    private var inBackground = false

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                           queue: nil) { [weak self] _ in
            self?.set(true)
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                           queue: nil) { [weak self] _ in
            self?.set(false)
        }
    }

    private func set(_ value: Bool) {
        lock.withLock { inBackground = value }
    }

    var isAllowed: Bool {
        CameraGPU.isAvailable && !lock.withLock { inBackground }
    }
}

/// 把一格來源變成一格成品：轉正、縮到輸出大小、疊字幕。一個物件只能在一條佇列上用。
///
/// - 不用轉、大小一樣、沒有字：原本那格直接交出去，一個像素都不動。
/// - 不用轉、大小一樣、有字：複製一份，只改字的範圍。
/// - 要縮或要轉：Core Image 一次合成（709，跟 CameraGPU 同一套）。在背景不能用顯示晶片，改走系統的縮放。
final class CaptionFrameMaker {
    struct Placement {
        /// 從整支影片的第幾秒開始。
        let start: Double
        /// 原片的方向與鏡像（原點左上）。
        let transform: CGAffineTransform

        var isUpright: Bool {
            abs(transform.a - 1) < 0.001 && abs(transform.d - 1) < 0.001
                && abs(transform.b) < 0.001 && abs(transform.c) < 0.001
        }
    }

    let size: CGSize
    private let width: Int
    private let height: Int
    private let placements: [Placement]
    private let overlay: CaptionOverlay
    private let isPreview: Bool
    private var transfer: VTPixelTransferSession?

    init(size: CGSize, placements: [Placement], overlay: CaptionOverlay, isPreview: Bool) {
        self.size = size
        self.width = Int(size.width)
        self.height = Int(size.height)
        self.placements = placements
        self.overlay = overlay
        self.isPreview = isPreview
        // 要在前景就開始聽，之後才知道進了背景。
        _ = CaptionGPUAccess.shared
    }

    deinit {
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
    }

    static let pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    /// 回來的可能就是 source 本身。newBuffer 給一個 size 大小、420v 的緩衝區。
    func frame(from source: CVPixelBuffer, at seconds: Double,
               newBuffer: () -> CVPixelBuffer?) throws -> CVPixelBuffer {
        var bitmap: CaptionBitmap?
        if let caption = overlay.caption(at: seconds) {
            bitmap = CaptionRenderer.bitmap(text: caption.text, style: caption.style, canvas: size)
        }
        let placement: Placement = self.placement(at: seconds)
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        let isPlain: Bool = placement.isUpright && CVPixelBufferGetPixelFormatType(source) == Self.pixelFormat
        let isSameSize: Bool = sourceWidth == width && sourceHeight == height

        if isPlain, isSameSize, bitmap == nil { return source }
        guard let output = newBuffer() else { throw CaptionVideoError.cannotDraw }
        Self.copyColorTags(from: source, to: output)

        if isPlain, isSameSize, Self.copyPixels(from: source, to: output) {
            if let bitmap, !bitmap.blend(onto: output) { throw CaptionVideoError.cannotDraw }
            return output
        }

        if CaptionGPUAccess.shared.isAllowed, draw(source, placement: placement, bitmap: bitmap, to: output) {
            Self.copyColorTags(from: source, to: output)
            return output
        }
        // 縮放要等比例，長寬比不一樣會變形，就不走這條。
        let isSameShape: Bool = abs(sourceWidth * height - sourceHeight * width) <= 4 * (width + height)
        if placement.isUpright, isSameShape, scale(source, to: output) {
            Self.copyColorTags(from: source, to: output)
            if let bitmap, !bitmap.blend(onto: output) { throw CaptionVideoError.cannotDraw }
            return output
        }
        throw CaptionVideoError.cannotDraw
    }

    private func placement(at seconds: Double) -> Placement {
        let time = seconds + 0.0008
        if let found = placements.last(where: { $0.start <= time }) ?? placements.first { return found }
        return Placement(start: 0, transform: .identity)
    }

    // MARK: 顯示晶片

    private func draw(_ source: CVPixelBuffer, placement: Placement, bitmap: CaptionBitmap?,
                      to output: CVPixelBuffer) -> Bool {
        guard let context = CameraGPU.context else { return false }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var image: CIImage = placed(CameraGPU.image(source), placement: placement, in: bounds)
        if let bitmap {
            image = bitmap.image.composited(over: image)
        }
        let destination = CIRenderDestination(pixelBuffer: output)
        destination.colorSpace = CameraGPU.colorSpace
        do {
            // 用 task 才知道有沒有畫成功；剛好切到背景時會失敗，交給下一條路。
            let task = try context.startTask(toRender: image.cropped(to: bounds), from: bounds,
                                             to: destination, at: .zero)
            _ = try task.waitUntilCompleted()
            return true
        } catch {
            return false
        }
    }

    /// 轉正、等比例縮到輸出大小、置中。比例不同才會有黑邊。
    private func placed(_ image: CIImage, placement: Placement, in bounds: CGRect) -> CIImage {
        let extent: CGRect = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        var move = CGAffineTransform.identity
        var upright: CGSize = extent.size
        if !placement.isUpright {
            // 影片的 transform 是原點左上的座標，Core Image 是左下，前後各翻一次。
            let turned: CGRect = CGRect(origin: .zero, size: extent.size).applying(placement.transform)
            upright = turned.size
            let toTop = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: extent.height)
            let toOrigin = CGAffineTransform(translationX: -turned.minX, y: -turned.minY)
            let toBottom = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: turned.height)
            move = toTop.concatenating(placement.transform).concatenating(toOrigin).concatenating(toBottom)
        }
        let scaleX: CGFloat = bounds.width / upright.width
        let scaleY: CGFloat = bounds.height / upright.height
        // 差不到一個像素就填滿，不留一條黑線。
        let fit: CGFloat = min(scaleX, scaleY)
        let fills: Bool = abs(upright.width * fit - bounds.width) < 2 && abs(upright.height * fit - bounds.height) < 2
        let x: CGFloat = fills ? scaleX : fit
        let y: CGFloat = fills ? scaleY : fit
        let target = CGRect(x: ((bounds.width - upright.width * x) / 2).rounded(),
                            y: ((bounds.height - upright.height * y) / 2).rounded(),
                            width: upright.width * x, height: upright.height * y)
        let resize = CGAffineTransform(a: x, b: 0, c: 0, d: y, tx: target.minX, ty: target.minY)
        let result: CIImage = image
            .clampedToExtent()
            .transformed(by: move.concatenating(resize), highQualityDownsample: !isPreview)
            .cropped(to: fills ? bounds : target)
        guard !fills else { return result }
        return result.composited(over: CIImage(color: .black).cropped(to: bounds))
    }

    // MARK: 不用顯示晶片

    private func scale(_ source: CVPixelBuffer, to output: CVPixelBuffer) -> Bool {
        if transfer == nil {
            var made: VTPixelTransferSession?
            let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &made)
            guard status == noErr, let made else { return false }
            VTSessionSetProperty(made, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
            transfer = made
        }
        guard let transfer else { return false }
        return VTPixelTransferSessionTransferImage(transfer, from: source, to: output) == noErr
    }

    private static func copyPixels(from source: CVPixelBuffer, to output: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(output) == CVPixelBufferGetPixelFormatType(source),
              CVPixelBufferGetPlaneCount(source) == 2, CVPixelBufferGetPlaneCount(output) == 2,
              CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        for plane in 0..<2 {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let to = CVPixelBufferGetBaseAddressOfPlane(output, plane) else { return false }
            let fromRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let toRow = CVPixelBufferGetBytesPerRowOfPlane(output, plane)
            let rows = min(CVPixelBufferGetHeightOfPlane(source, plane), CVPixelBufferGetHeightOfPlane(output, plane))
            let bytes = min(fromRow, toRow)
            for row in 0..<rows {
                memcpy(to + row * toRow, from + row * fromRow, bytes)
            }
        }
        return true
    }

    /// 原片標什麼就標什麼，沒標就是 709。先標再畫：Core Image 靠標籤決定 RGB 轉 YCbCr 用哪個矩陣。
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

    /// 全黑。
    static func clear(_ buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(buffer) == pixelFormat,
              CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for (plane, value) in [(0, Int32(16)), (1, Int32(128))] {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            memset(base, value, rowBytes * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
    }
}

// MARK: - 播放器的合成

/// 把要用的東西帶給合成器。合成器是系統建的，只能從這裡拿。
final class CaptionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    /// 字幕會隨時間變，每一格都要問。
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let trackID: CMPersistentTrackID
    let maker: CaptionFrameMaker

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, maker: CaptionFrameMaker) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.maker = maker
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
        super.init()
    }
}

/// 播放時一格一格合成。只給預覽用，燒錄自己讀影格，不經過這裡。
final class CaptionCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: CaptionFrameMaker.pixelFormat,
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: CaptionFrameMaker.pixelFormat,
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    /// 系統會一次要好幾格，排隊一格一格做。
    private let queue = DispatchQueue(label: "org.domyweb.broccolicam.caption", qos: .userInitiated,
                                      autoreleaseFrequency: .workItem)
    private let lock = NSLock()
    private var cancelling = false

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            self.compose(asyncVideoCompositionRequest)
        }
    }

    /// 規定要等到排著的都回覆了才能返回。
    func cancelAllPendingVideoCompositionRequests() {
        lock.withLock { cancelling = true }
        queue.sync {}
        lock.withLock { cancelling = false }
    }

    private func compose(_ request: AVAsynchronousVideoCompositionRequest) {
        if lock.withLock({ cancelling }) {
            request.finishCancelledRequest()
            return
        }
        guard let instruction = request.videoCompositionInstruction as? CaptionInstruction else {
            request.finish(with: CaptionVideoError.cannotDraw)
            return
        }
        guard let source = request.sourceFrame(byTrackID: instruction.trackID) else {
            // 頭尾剛好沒有影格，給黑的，不要讓整支播不了。
            guard let blank = request.renderContext.newPixelBuffer() else {
                request.finish(with: CaptionVideoError.cannotDraw)
                return
            }
            CaptionFrameMaker.clear(blank)
            request.finish(withComposedVideoFrame: blank)
            return
        }
        do {
            let frame = try instruction.maker.frame(from: source, at: request.compositionTime.seconds) {
                request.renderContext.newPixelBuffer()
            }
            request.finish(withComposedVideoFrame: frame)
        } catch {
            // 剛好切到背景之類的，黑一格比整支停掉好。
            if let blank = request.renderContext.newPixelBuffer() {
                CaptionFrameMaker.clear(blank)
                request.finish(withComposedVideoFrame: blank)
            } else {
                request.finish(with: error)
            }
        }
    }
}
