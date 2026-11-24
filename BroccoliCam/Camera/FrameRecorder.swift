import AVFoundation
import CoreVideo
import Foundation

enum FrameRecorderError: LocalizedError {
    case badVideoSettings
    case cannotStart

    var errorDescription: String? {
        switch self {
        case .badVideoSettings: return "這個格式沒辦法編碼"
        case .cannotStart: return "寫檔沒有啟動"
        }
    }
}

/// 把一格一格的畫面和聲音寫成一個 .mov。一個物件只錄一次。
///
/// 執行緒：影格從 videoQueue 進來、聲音從 audioQueue 進來、開始和停止從 sessionQueue 進來，
/// 全部用同一把鎖。鎖裡面不呼叫任何會再拿鎖的東西：對外回呼只做「丟到別的佇列」，
/// 收尾的回呼在 finishQueue 或 AVAssetWriter 自己的佇列上，所以不會死結。
final class FrameRecorder {
    enum Outcome {
        /// 檔案可用。note 有值代表中途出過狀況，但檔案還能看。
        case finished(URL, note: String?)
        case failed(String)
    }

    /// 這一格要錄時，算圖需要的東西。
    struct Ticket {
        let pool: CVPixelBufferPool
        let width: Int
        let height: Int
        /// 影格要再順時針轉幾度才是成品的方向：0、90、-90、180。
        let turn: Int
    }

    struct Counts {
        var frames = 0
        /// 編碼器來不及收而丟掉的影格
        var notReady = 0
        /// 算圖失敗而丟掉的影格
        var renderFailed = 0
        /// 丟掉的聲音包
        var audioDropped = 0
    }

    private enum Phase {
        case running
        case stopping
        case ended
    }

    let url: URL
    /// 第一格寫進去了，參數是那一格的時間。在鎖裡面呼叫，只能做「丟到別的佇列」。
    var onStarted: ((CMTime) -> Void)?
    /// 整個結束了（只會呼叫一次）。
    var onEnded: ((Outcome) -> Void)?

    private let lock = NSLock()
    private let finishQueue = DispatchQueue(label: "org.domyweb.broccolicam.writer", qos: .userInitiated)
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let pool: CVPixelBufferPool
    private let width: Int
    private let height: Int
    private let turn: Int
    private let frameDuration: CMTime
    private let startTimeout: TimeInterval
    private let tailTimeout: TimeInterval

    // 以下都在 lock 裡面讀寫
    private var phase: Phase = .running
    private var armed = false
    private var sessionStarted = false
    private var reported = false
    private var startTime: CMTime = .invalid
    private var stopTime: CMTime = .invalid
    private var firstVideoTime: CMTime = .invalid
    private var lastVideoTime: CMTime = .invalid
    private var counts = Counts()
    /// 停止之後，畫面已經收到 stopTime 了，在等聲音。
    private var videoDone = false
    /// 最後一包聲音到什麼時候（不管寫了沒）。
    private var audioSeenUntil: CMTime = .invalid

    /// 聲音比畫面早到（開防抖時畫面會晚幾百毫秒），先放著，等畫面跟上再寫。
    private var pendingAudio: [CMSampleBuffer] = []
    private var lastAudioEnd: CMTime = .invalid
    private var audioBasic: AudioStreamBasicDescription?
    private var audioDescription: CMFormatDescription?
    private var reformatter: AudioReformatter?

    /// 聲音最多比畫面超前多少就先寫進去。
    private static let audioLead = CMTime(value: 1, timescale: 2)
    /// 聲音落後畫面這麼多就當作收不到了，補無聲。
    private static let audioStall = CMTime(value: 3, timescale: 2)
    /// 最多留著多少還沒寫的聲音（秒）。
    private static let audioBacklog: Double = 6

    /// 建立寫檔器並且暖機。會花一點時間，請在 sessionQueue 呼叫。
    /// startTimeout 內一格都沒收到就算失敗；停止後最多等 tailTimeout 收晚到的影格。
    init(url: URL, width: Int, height: Int, turn: Int,
         videoSettings: [String: Any], audioSettings: [String: Any]?,
         frameDuration: CMTime, startTimeout: TimeInterval, tailTimeout: TimeInterval) throws {
        let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
        // App 被系統殺掉或寫檔出錯時，前面的片段還能救回來。
        assetWriter.movieFragmentInterval = CMTime(value: 2, timescale: 1)
        assetWriter.initialMovieFragmentInterval = CMTime(value: 1, timescale: 1)

        guard assetWriter.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw FrameRecorderError.badVideoSettings
        }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(video) else { throw FrameRecorderError.badVideoSettings }
        let attributes: [String: Any] = FrameRecorder.bufferAttributes(width: width, height: height)
        let bufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
                                                                 sourcePixelBufferAttributes: attributes)
        assetWriter.add(video)

        // 沒有麥克風、或聲音設定不能用，就只錄畫面。
        var audio: AVAssetWriterInput?
        if let audioSettings, assetWriter.canApply(outputSettings: audioSettings, forMediaType: .audio) {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if assetWriter.canAdd(input) {
                assetWriter.add(input)
                audio = input
            }
        }

        guard assetWriter.startWriting() else {
            throw assetWriter.error ?? FrameRecorderError.cannotStart
        }
        guard let bufferPool = bufferAdaptor.pixelBufferPool ?? FrameRecorder.makePool(attributes) else {
            assetWriter.cancelWriting()
            throw FrameRecorderError.cannotStart
        }

        self.url = url
        self.writer = assetWriter
        self.videoInput = video
        self.adaptor = bufferAdaptor
        self.audioInput = audio
        self.pool = bufferPool
        self.width = width
        self.height = height
        self.turn = turn
        self.frameDuration = frameDuration
        self.startTimeout = startTimeout
        self.tailTimeout = tailTimeout
    }

    private static func bufferAttributes(width: Int, height: Int) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferWidthKey as String: NSNumber(value: width),
            kCVPixelBufferHeightKey as String: NSNumber(value: height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: NSNumber(value: true)
        ]
    }

    private static func makePool(_ attributes: [String: Any]) -> CVPixelBufferPool? {
        var made: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &made)
        return status == kCVReturnSuccess ? made : nil
    }

    // MARK: - 開始與停止

    var hasAudio: Bool { audioInput != nil }

    /// 還在收影格（還沒進入收尾）。
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return phase != .ended
    }

    var currentCounts: Counts {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    /// 從這個時間之後的影格開始收。
    func start(at time: CMTime) {
        lock.lock()
        startTime = time
        armed = true
        lock.unlock()
        finishQueue.asyncAfter(deadline: .now() + startTimeout) { [weak self] in
            self?.endIfNothingArrived()
        }
    }

    /// 停止：這個時間之前的影格還收，等到第一格超過這個時間的影格、或逾時才收尾。
    func stop(at time: CMTime) {
        lock.lock()
        guard phase == .running else {
            lock.unlock()
            return
        }
        phase = .stopping
        stopTime = time
        lock.unlock()
        finishQueue.asyncAfter(deadline: .now() + tailTimeout) { [weak self] in
            self?.endIfStopping()
        }
    }

    /// 馬上收尾，不等晚到的影格（中斷、進背景、session 要停了）。
    func finishNow(at time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard phase != .ended else { return }
        if phase == .running { stopTime = time }
        endLocked()
    }

    private func endIfNothingArrived() {
        lock.lock()
        defer { lock.unlock() }
        guard phase != .ended, !sessionStarted else { return }
        endLocked()
    }

    private func endIfStopping() {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .stopping else { return }
        endLocked()
    }

    // MARK: - 影格

    /// 這一格要不要錄。要錄才去算圖，編碼器來不及收也在這裡先擋掉。
    func ticket(at time: CMTime) -> Ticket? {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsLocked(time) else { return nil }
        guard videoReadyLocked() else { return nil }
        return Ticket(pool: pool, width: width, height: height, turn: turn)
    }

    func append(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        // 算圖期間可能已經停了，再確認一次。
        guard acceptsLocked(time), videoReadyLocked() else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: time)
            sessionStarted = true
            firstVideoTime = time
        }
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
            failLocked("寫入畫面失敗：\(errorText())")
            return
        }
        let isFirst = !lastVideoTime.isValid
        lastVideoTime = time
        counts.frames += 1
        #if targetEnvironment(simulator)
        appendFakeAudioLocked(until: time)
        #endif
        if isFirst {
            onStarted?(time)
        }
        drainAudioLocked(limit: time + Self.audioLead)
        padSilenceLocked(until: time - Self.audioStall)
    }

    func noteRenderFailure() {
        lock.lock()
        counts.renderFailed += 1
        lock.unlock()
    }

    private func acceptsLocked(_ time: CMTime) -> Bool {
        guard armed, phase != .ended, time.isNumeric else { return false }
        if phase == .stopping, time > stopTime {
            finishVideoLocked()
            return false
        }
        guard time >= startTime else { return false }
        // 時間一定要往前走，重複或倒退的影格不收。
        if lastVideoTime.isValid, time <= lastVideoTime { return false }
        return true
    }

    /// 畫面收到停止的那一刻了。聲音通常晚一點到，等它也到，最多 0.15 秒，尾音才不會被切。
    private func finishVideoLocked() {
        guard !videoDone else { return }
        videoDone = true
        guard audioInput != nil, !audioReachedStopLocked() else {
            endLocked()
            return
        }
        finishQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.endIfStopping()
        }
    }

    private func audioReachedStopLocked() -> Bool {
        audioSeenUntil.isValid && audioSeenUntil >= stopTime
    }

    private func videoReadyLocked() -> Bool {
        if writer.status == .failed {
            failLocked("寫檔失敗：\(errorText())")
            return false
        }
        guard writer.status == .writing, videoInput.isReadyForMoreMediaData else {
            counts.notReady += 1
            return false
        }
        return true
    }

    // MARK: - 聲音

    /// 在 audioQueue 呼叫。
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard audioInput != nil, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let time: CMTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isNumeric else { return }
        lock.lock()
        defer { lock.unlock() }
        let end: CMTime = audioEnd(sampleBuffer, from: time)
        guard armed, phase != .ended, end > startTime else { return }
        audioSeenUntil = end
        if phase != .stopping || time <= stopTime {
            pendingAudio.append(sampleBuffer)
            if lastVideoTime.isValid {
                drainAudioLocked(limit: lastVideoTime + Self.audioLead)
            }
            trimBacklogLocked()
        }
        if phase == .stopping, videoDone, audioReachedStopLocked() {
            endLocked()
        }
    }

    /// 有音軌卻一直收不到聲音時補上無聲。寫檔器要每一軌都有資料才肯把片段落地，
    /// 不補的話，錄到一半被滑掉整段都救不回來。
    private func padSilenceLocked(until limit: CMTime) {
        guard let audioInput, pendingAudio.isEmpty else { return }
        var start: CMTime = lastAudioEnd.isValid ? lastAudioEnd : firstVideoTime
        while start < limit, writer.status == .writing, audioInput.isReadyForMoreMediaData {
            guard let sample = Self.silence(at: start) else { return }
            writeAudioLocked(sample, at: start, to: audioInput)
            guard lastAudioEnd.isValid, lastAudioEnd > start else { return }
            start = lastAudioEnd
        }
    }

    private static func silence(at time: CMTime) -> CMSampleBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024),
              let samples = buffer.floatChannelData else { return nil }
        buffer.frameLength = 1024
        samples[0].update(repeating: 0, count: 1024)
        return AudioReformatter.sampleBuffer(from: buffer, description: format.formatDescription, at: time)
    }

    #if targetEnvironment(simulator)
    /// 測試用：模擬器沒有聲音，設 debugFakeAudio 就照著畫面的時間餵無聲的聲音，跟真機一樣每一刻都有聲音進來。
    private static let fakesAudio = UserDefaults.standard.bool(forKey: "debugFakeAudio")
    private var fakeAudioEnd: CMTime = .invalid

    private func appendFakeAudioLocked(until time: CMTime) {
        guard Self.fakesAudio, audioInput != nil else { return }
        var start: CMTime = fakeAudioEnd.isValid ? fakeAudioEnd : firstVideoTime
        while start < time {
            guard let sample = Self.silence(at: start) else { return }
            pendingAudio.append(sample)
            start = audioEnd(sample, from: start)
        }
        fakeAudioEnd = start
    }
    #endif

    private func audioEnd(_ sampleBuffer: CMSampleBuffer, from time: CMTime) -> CMTime {
        let duration: CMTime = CMSampleBufferGetDuration(sampleBuffer)
        return duration.isNumeric ? time + duration : time
    }

    /// 把留著的聲音寫進去，只寫到 limit 為止。
    private func drainAudioLocked(limit: CMTime) {
        guard sessionStarted, let audioInput else { return }
        while phase != .ended || drainingAtEnd, let first = pendingAudio.first {
            let time: CMTime = CMSampleBufferGetPresentationTimeStamp(first)
            guard time <= limit else { return }
            guard writer.status == .writing, audioInput.isReadyForMoreMediaData else { return }
            pendingAudio.removeFirst()
            writeAudioLocked(first, at: time, to: audioInput)
        }
    }

    /// 收尾時 phase 已經是 ended，這個旗標讓最後一次 drain 還能跑。
    private var drainingAtEnd = false

    private func writeAudioLocked(_ sampleBuffer: CMSampleBuffer, at time: CMTime, to input: AVAssetWriterInput) {
        guard audioEnd(sampleBuffer, from: time) > firstVideoTime else { return }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return }

        var output: CMSampleBuffer = sampleBuffer
        var outputTime: CMTime = time
        if let wanted = audioBasic, let wantedDescription = audioDescription {
            if !Self.sameFormat(basic, wanted) {
                // 錄到一半插拔耳機，收音格式變了。轉回一開始的格式再寫，轉不了就丟掉這包，不能讓整支影片壞掉。
                if reformatter == nil || !reformatter!.accepts(basic) {
                    reformatter = AudioReformatter(from: basic, to: wanted, description: wantedDescription)
                }
                if lastAudioEnd.isValid, lastAudioEnd > outputTime { outputTime = lastAudioEnd }
                guard let converted = reformatter?.convert(sampleBuffer, at: outputTime) else {
                    counts.audioDropped += 1
                    return
                }
                output = converted
            }
        } else {
            audioBasic = basic
            audioDescription = description
        }

        // 時間倒退超過 5 毫秒的聲音會讓寫檔器出錯。
        if lastAudioEnd.isValid, outputTime + CMTime(value: 5, timescale: 1000) < lastAudioEnd {
            counts.audioDropped += 1
            return
        }
        guard input.append(output) else {
            counts.audioDropped += 1
            if writer.status == .failed {
                failLocked("寫入聲音失敗：\(errorText())")
            }
            return
        }
        lastAudioEnd = audioEnd(output, from: outputTime)
    }

    /// 留太多就丟最舊的。
    private func trimBacklogLocked() {
        while pendingAudio.count > 1, let first = pendingAudio.first, let last = pendingAudio.last {
            let span: CMTime = CMSampleBufferGetPresentationTimeStamp(last) - CMSampleBufferGetPresentationTimeStamp(first)
            guard span.seconds > Self.audioBacklog else { return }
            pendingAudio.removeFirst()
            counts.audioDropped += 1
        }
    }

    private static func sameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mFormatID == b.mFormatID
            && a.mSampleRate == b.mSampleRate
            && a.mFormatFlags == b.mFormatFlags
            && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
    }

    // MARK: - 收尾

    private func errorText() -> String {
        writer.error?.localizedDescription ?? "未知原因"
    }

    private func endLocked() {
        guard phase != .ended else { return }
        phase = .ended
        guard sessionStarted, lastVideoTime.isValid else {
            discardLocked(writer.status == .failed ? "寫檔失敗：\(errorText())" : "沒有收到任何影格")
            return
        }
        guard writer.status == .writing else {
            pendingAudio.removeAll()
            salvage("寫檔失敗：\(errorText())")
            return
        }
        let end: CMTime = lastVideoTime + frameDuration
        drainTailLocked(until: end)
        guard writer.status == .writing else {
            salvage("寫檔失敗：\(errorText())")
            return
        }
        writer.endSession(atSourceTime: end)
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [self] in
            // 換一條佇列再回報：萬一這個回呼是當場同步叫的，鎖還在我們手上。
            finishQueue.async { [self] in
                if writer.status == .completed {
                    report(.finished(url, note: nil))
                } else {
                    salvage("收尾失敗：\(errorText())")
                }
            }
        }
    }

    /// 把最後留著的聲音寫完。輸入暫時不能收就等一下，最多 0.1 秒。
    private func drainTailLocked(until end: CMTime) {
        drainingAtEnd = true
        for _ in 0..<20 {
            drainAudioLocked(limit: end)
            guard let first = pendingAudio.first, writer.status == .writing else { break }
            if CMSampleBufferGetPresentationTimeStamp(first) > end { break }
            usleep(5000)
        }
        drainingAtEnd = false
        pendingAudio.removeAll()
    }

    /// 寫到一半出錯。前面的片段可能還能看，交給 salvage 判斷。
    private func failLocked(_ message: String) {
        let wasEnding = phase == .ended
        phase = .ended
        pendingAudio.removeAll()
        // 收尾途中（drainTailLocked）才發現的，由 endLocked 接手回報。
        guard !wasEnding else { return }
        if sessionStarted, lastVideoTime.isValid {
            salvage(message)
        } else {
            discardLocked(message)
        }
    }

    /// 什麼都沒錄到：取消、刪檔、回報失敗。
    private func discardLocked(_ message: String) {
        pendingAudio.removeAll()
        finishQueue.async { [self] in
            if writer.status == .writing {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: url)
            report(.failed(message))
        }
    }

    /// 寫檔器失敗後，看看已經寫出去的片段能不能播。能播就留著用。
    /// 現在讀不了不代表檔案壞了（例如媒體服務剛重啟），等一下再試；
    /// 還是不行也不刪，下次開 App 由 TakeStore 再看一次。
    private func salvage(_ message: String) {
        let fileURL = url
        Task {
            for attempt in 0..<3 {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                if case .usable = await TakeStore.examine(fileURL) {
                    self.report(.finished(fileURL, note: message))
                    return
                }
            }
            self.report(.failed(message))
        }
    }

    /// 不可以在拿著鎖的時候呼叫。
    private func report(_ outcome: Outcome) {
        lock.lock()
        let first = !reported
        reported = true
        lock.unlock()
        if first {
            onEnded?(outcome)
        }
    }
}

/// 把變了格式的收音轉回一開始的格式。
private final class AudioReformatter {
    private final class Feed {
        var used = false
    }

    private let source: AudioStreamBasicDescription
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let targetDescription: CMFormatDescription
    private let converter: AVAudioConverter

    init?(from source: AudioStreamBasicDescription, to target: AudioStreamBasicDescription,
          description: CMFormatDescription) {
        var sourceCopy = source
        var targetCopy = target
        guard let input = AVAudioFormat(streamDescription: &sourceCopy),
              let output = AVAudioFormat(streamDescription: &targetCopy),
              let made = AVAudioConverter(from: input, to: output) else { return nil }
        self.source = source
        sourceFormat = input
        targetFormat = output
        targetDescription = description
        converter = made
    }

    func accepts(_ basic: AudioStreamBasicDescription) -> Bool {
        basic.mSampleRate == source.mSampleRate
            && basic.mFormatID == source.mFormatID
            && basic.mFormatFlags == source.mFormatFlags
            && basic.mChannelsPerFrame == source.mChannelsPerFrame
            && basic.mBitsPerChannel == source.mBitsPerChannel
    }

    func convert(_ sampleBuffer: CMSampleBuffer, at time: CMTime) -> CMSampleBuffer? {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        input.frameLength = AVAudioFrameCount(frames)
        let copied: OSStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList)
        guard copied == noErr else { return nil }

        let ratio: Double = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        let feed = Feed()
        var conversionError: NSError?
        let status: AVAudioConverterOutputStatus = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if feed.used {
                inputStatus.pointee = .noDataNow
                return nil
            }
            feed.used = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else { return nil }
        return Self.sampleBuffer(from: output, description: targetDescription, at: time)
    }

    static func sampleBuffer(from buffer: AVAudioPCMBuffer, description: CMFormatDescription,
                                     at time: CMTime) -> CMSampleBuffer? {
        let rate = CMTimeScale(buffer.format.sampleRate.rounded())
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate),
                                        presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        var made: CMSampleBuffer?
        let created: OSStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
            sampleCount: CMItemCount(buffer.frameLength), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &made)
        guard created == noErr, let result = made else { return nil }
        let filled: OSStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            result, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList)
        guard filled == noErr else { return nil }
        if !CMSampleBufferDataIsReady(result) {
            guard CMSampleBufferSetDataReady(result) == noErr else { return nil }
        }
        return result
    }
}
