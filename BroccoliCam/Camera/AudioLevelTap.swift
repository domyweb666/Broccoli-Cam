import AVFoundation
import QuartzCore

/// 從音訊分流算出目前音量（RMS，dBFS）。音訊佇列寫、主執行緒讀。
final class AudioLevelTap {
    private let lock = NSLock()
    private var level: Float = -160
    private var channels: [Float] = []
    private var updatedAt: CFTimeInterval = 0

    /// 在音訊佇列呼叫。
    func consume(_ sampleBuffer: CMSampleBuffer) {
        guard let values = Self.channelDecibels(of: sampleBuffer), let loudest = values.max() else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        level = loudest
        channels = values
        updatedAt = now
        lock.unlock()
    }

    /// 各聲道的音量（左、右…）。雙聲道時拿來看兩支發射器是不是都有收到。半秒沒有新的音訊回空的。
    func currentChannels() -> [Float] {
        let now = CACurrentMediaTime()
        lock.lock()
        defer { lock.unlock() }
        guard updatedAt > 0, now - updatedAt <= 0.5 else { return [] }
        return channels
    }

    /// 目前音量。超過半秒沒有新的音訊就當作沒有收到。
    func current() -> Float? {
        let now = CACurrentMediaTime()
        lock.lock()
        defer { lock.unlock() }
        guard updatedAt > 0, now - updatedAt <= 0.5 else { return nil }
        return level
    }

    /// 取各聲道裡最大聲的那一個。
    static func decibels(of sampleBuffer: CMSampleBuffer) -> Float? {
        channelDecibels(of: sampleBuffer)?.max()
    }

    /// 每個聲道各自的音量。處理 Int16、Int32、Float32，交錯或不交錯。
    static func channelDecibels(of sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              basic.mFormatID == kAudioFormatLinearPCM else { return nil }
        let isFloat = (basic.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bits = Int(basic.mBitsPerChannel)
        let bytes = bits / 8
        guard bytes == 2 || bytes == 4 else { return nil }
        if isFloat && bytes != 4 { return nil }

        var means: [Double] = []
        do {
            try sampleBuffer.withAudioBufferList { (list: UnsafeMutableAudioBufferListPointer, _: CMBlockBuffer) -> Void in
                for buffer in list {
                    guard let data = buffer.mData else { continue }
                    let channels = max(1, Int(buffer.mNumberChannels))
                    let frames = Int(buffer.mDataByteSize) / bytes / channels
                    guard frames > 0 else { continue }
                    for channel in 0..<channels {
                        let mean = meanSquare(data, channel: channel, stride: channels,
                                              frames: frames, isFloat: isFloat, bytes: bytes)
                        means.append(mean)
                    }
                }
            }
        } catch {
            return nil
        }
        guard !means.isEmpty else { return nil }
        return means.map { mean in
            mean > 1e-16 ? Float(max(-160, 10 * log10(mean))) : -160
        }
    }

    private static func meanSquare(_ data: UnsafeMutableRawPointer, channel: Int, stride: Int,
                                   frames: Int, isFloat: Bool, bytes: Int) -> Double {
        var sum: Double = 0
        var index = channel
        if isFloat {
            let samples = data.assumingMemoryBound(to: Float.self)
            for _ in 0..<frames {
                let value = Double(samples[index])
                sum += value * value
                index += stride
            }
        } else if bytes == 2 {
            let samples = data.assumingMemoryBound(to: Int16.self)
            for _ in 0..<frames {
                let value = Double(samples[index]) / 32768
                sum += value * value
                index += stride
            }
        } else {
            let samples = data.assumingMemoryBound(to: Int32.self)
            for _ in 0..<frames {
                let value = Double(samples[index]) / 2147483648
                sum += value * value
                index += stride
            }
        }
        let mean = sum / Double(frames)
        return mean.isFinite ? mean : 0
    }
}
