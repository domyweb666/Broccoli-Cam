import AVFoundation

/// 把一包收音轉成指定的格式：換取樣率、換聲道數。
/// 立體聲轉單聲道是左右混在一起（兩支發射器都聽得到），單聲道轉立體聲是左右放同一份。
final class AudioReformatter {
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
        guard let input = Self.format(source),
              let output = Self.format(target),
              let made = AVAudioConverter(from: input, to: output) else { return nil }
        let inChannels = Int(input.channelCount)
        let outChannels = Int(output.channelCount)
        if outChannels == 1, inChannels > 1 {
            made.downmix = true
        } else if inChannels == 1, outChannels > 1 {
            made.channelMap = Array(repeating: NSNumber(value: 0), count: outChannels)
        } else if inChannels > outChannels {
            // 多軌的錄音介面：只取前面幾軌（通常是第 1、2 軌）。
            made.channelMap = (0..<outChannels).map { NSNumber(value: $0) }
        }
        self.source = source
        sourceFormat = input
        targetFormat = output
        targetDescription = description
        converter = made
    }

    /// 超過兩聲道的格式要附聲道配置，AVAudioFormat 才建得起來。
    private static func format(_ basic: AudioStreamBasicDescription) -> AVAudioFormat? {
        var copy = basic
        if basic.mChannelsPerFrame <= 2 {
            return AVAudioFormat(streamDescription: &copy)
        }
        let tag: AudioChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(basic.mChannelsPerFrame)
        guard let layout = AVAudioChannelLayout(layoutTag: tag) else { return nil }
        return AVAudioFormat(streamDescription: &copy, channelLayout: layout)
    }

    func accepts(_ basic: AudioStreamBasicDescription) -> Bool {
        AudioFormatKeeper.sameFormat(basic, source)
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

/// 讓一路收音從頭到尾維持同一個格式。第一包定下格式（聲道數可以指定），之後格式變了就轉回來。
/// 錄到一半插拔麥克風時，取樣率、聲道數會變；寫檔和語音辨識都要一樣的格式才不會壞。
/// 不是執行緒安全的，固定在同一條佇列（或同一把鎖裡）呼叫。
final class AudioFormatKeeper {
    /// nil 是照第一包的聲道數。
    let channels: Int?
    private(set) var target: AudioStreamBasicDescription?
    private(set) var targetDescription: CMFormatDescription?
    private var reformatter: AudioReformatter?

    init(channels: Int?) {
        self.channels = channels
    }

    var isSettled: Bool { target != nil }

    /// 用這一包定下格式。不是 PCM 就不收，回 false。
    @discardableResult
    func settle(_ basic: AudioStreamBasicDescription, description: CMFormatDescription) -> Bool {
        guard basic.mFormatID == kAudioFormatLinearPCM, basic.mSampleRate > 0, basic.mChannelsPerFrame > 0 else {
            return false
        }
        if let channels, Int(basic.mChannelsPerFrame) != channels,
           let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: basic.mSampleRate,
                                      channels: AVAudioChannelCount(channels), interleaved: false) {
            target = format.streamDescription.pointee
            targetDescription = format.formatDescription
        } else {
            target = basic
            targetDescription = description
        }
        return true
    }

    /// 這個格式要不要轉。
    func needsConversion(_ basic: AudioStreamBasicDescription) -> Bool {
        guard let target else { return false }
        return !Self.sameFormat(basic, target)
    }

    /// 轉成定好的格式。轉不了回 nil。
    func convert(_ sampleBuffer: CMSampleBuffer, from basic: AudioStreamBasicDescription,
                 at time: CMTime) -> CMSampleBuffer? {
        guard let target, let targetDescription else { return nil }
        if reformatter == nil || !reformatter!.accepts(basic) {
            reformatter = AudioReformatter(from: basic, to: target, description: targetDescription)
        }
        return reformatter?.convert(sampleBuffer, at: time)
    }

    /// 給語音辨識用：第一包定格式，之後一律交出一樣格式的聲音。轉不了回 nil。
    func process(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return nil }
        if !isSettled {
            guard settle(basic, description: description) else { return nil }
        }
        guard needsConversion(basic) else { return sampleBuffer }
        return convert(sampleBuffer, from: basic, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    static func sameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mFormatID == b.mFormatID
            && a.mSampleRate == b.mSampleRate
            && a.mFormatFlags == b.mFormatFlags
            && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
    }

    /// 給 AAC 設定用的聲道配置。
    static func channelLayoutData(channels: Int) -> Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels >= 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }
}
