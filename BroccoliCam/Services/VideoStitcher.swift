import AVFoundation

enum VideoStitchError: LocalizedError {
    case noVideoTrack
    case cannotExport
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "有一段影片讀不到畫面。"
        case .cannotExport: return "這支裝置無法輸出接好的影片。"
        case .exportFailed(let reason): return "接片失敗：\(reason)"
        }
    }
}

/// 把各段錄影照順序接成一支影片。可選擇裁掉每段頭尾（秒）。
enum VideoStitcher {
    struct Clip {
        let url: URL
        /// 保留範圍的起點／終點（秒）。nil 代表不裁。
        let start: Double?
        let end: Double?
    }

    /// 把各段照順序排進同一條時間軸，還沒有輸出成檔案。接片、字幕預覽、燒錄都用這一份，時間才會一致。
    /// offsets 是各段在整支影片裡的起點（秒），durations 是各段裁完的長度（秒）。
    static func composition(_ clips: [Clip]) async throws
        -> (composition: AVMutableComposition, offsets: [Double], durations: [Double], transform: CGAffineTransform) {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoStitchError.cannotExport
        }
        var audioTracks: [Int: AVMutableCompositionTrack] = [:]
        var cursor = CMTime.zero
        var transformSet = false
        var transform = CGAffineTransform.identity
        var offsets: [Double] = []
        var durations: [Double] = []

        for clip in clips {
            let asset = AVURLAsset(url: clip.url)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw VideoStitchError.noVideoTrack
            }
            let trackRange = try await sourceVideo.load(.timeRange)
            let lower = trackRange.start.seconds
            let upper = trackRange.end.seconds

            var start = max(lower, clip.start ?? lower)
            var end = min(upper, clip.end ?? upper)
            // 裁完剩太短，多半是偵測不準，整段保留。
            if end - start < 0.5 {
                start = lower
                end = upper
            }
            let range = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                end: CMTime(seconds: end, preferredTimescale: 600)
            )

            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            if !transformSet {
                // 沿用原始影片的方向與鏡像設定。
                transform = try await sourceVideo.load(.preferredTransform)
                videoTrack.preferredTransform = transform
                transformSet = true
            }

            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                // 單聲道（手機麥）和立體聲（外接麥）的段落分開放兩條音軌，
                // 一條音軌裡混著不同聲道數，有些機器接起來會失敗。輸出和播放時兩條會混成一條。
                let channels = try await Self.channelCount(of: sourceAudio)
                if audioTracks[channels] == nil {
                    audioTracks[channels] = composition.addMutableTrack(
                        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                let audioRange = try await sourceAudio.load(.timeRange)
                let clipped = range.intersection(audioRange)
                if clipped.duration.seconds > 0 {
                    let at = cursor + (clipped.start - range.start)
                    try audioTracks[channels]?.insertTimeRange(clipped, of: sourceAudio, at: at)
                }
            }

            offsets.append(cursor.seconds)
            durations.append(range.duration.seconds)
            cursor = cursor + range.duration
        }
        return (composition, offsets, durations, transform)
    }

    /// 音軌是幾聲道（1 或 2，讀不到當 1）。
    private static func channelCount(of track: AVAssetTrack) async throws -> Int {
        let formats: [CMFormatDescription] = try await track.load(.formatDescriptions)
        let counts = formats.compactMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
        return (counts.max() ?? 1) >= 2 ? 2 : 1
    }

    /// 輸出到 output，這個檔名不能已經存在。失敗時會把寫到一半的檔刪掉，各段不動。
    static func stitch(_ clips: [Clip], to output: URL) async throws {
        let built = try await Self.composition(clips)
        let composition = built.composition

        // 各段格式完全一樣時直接搬原本的畫面，不重新壓。任何一項比不出來、輸出失敗、
        // 或輸出的長度跟時間軸對不上，就把檔刪掉改走原本的重壓。
        if let frameRate = await passthroughFrameRate(clips),
           await exportPassthrough(composition, to: output, frameRate: frameRate,
                                   expectedDuration: built.durations.reduce(0, +)) {
            return
        }

        let session: AVAssetExportSession
        if let hevc = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality) {
            session = hevc
        } else if let fallback = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) {
            session = fallback
        } else {
            throw VideoStitchError.cannotExport
        }

        session.outputURL = output
        session.outputFileType = .mov
        // 只存在手機裡、存到照片，用不到為串流重排檔案（重排要整支多寫一次）。
        session.shouldOptimizeForNetworkUse = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }

        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw VideoStitchError.exportFailed(session.error?.localizedDescription ?? "未知原因")
        }
    }

    // MARK: - 直通

    /// 每段的畫面與聲音格式。比對用，任何一項讀不到就回 nil。
    private struct SourceFormat {
        let video: CMFormatDescription
        let size: CGSize
        let frameRate: Float
        let transform: CGAffineTransform
        let audio: CMFormatDescription?
    }

    private static func sourceFormat(_ url: URL) async -> SourceFormat? {
        let asset = AVURLAsset(url: url)
        guard let videoTracks = try? await asset.loadTracks(withMediaType: .video),
              videoTracks.count == 1, let video = videoTracks.first,
              let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
              audioTracks.count <= 1,
              let videoFormats = try? await video.load(.formatDescriptions),
              videoFormats.count == 1, let videoFormat = videoFormats.first,
              let size = try? await video.load(.naturalSize),
              let frameRate = try? await video.load(.nominalFrameRate),
              let transform = try? await video.load(.preferredTransform) else { return nil }
        // 只收 HEVC：原本重壓出來的就是 HEVC，直通後編碼跟以前一樣。
        guard CMFormatDescriptionGetMediaSubType(videoFormat) == kCMVideoCodecType_HEVC,
              size.width > 0, size.height > 0, frameRate > 0 else { return nil }
        var audioFormat: CMFormatDescription?
        if let audio = audioTracks.first {
            guard let formats = try? await audio.load(.formatDescriptions),
                  formats.count == 1, let format = formats.first,
                  CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC else { return nil }
            audioFormat = format
        }
        return SourceFormat(video: videoFormat, size: size, frameRate: frameRate,
                            transform: transform, audio: audioFormat)
    }

    /// 所有段的編碼參數、尺寸、幀率、轉向、聲音格式都一樣才回幀率（給事後檢查長度用），否則 nil。
    private static func passthroughFrameRate(_ clips: [Clip]) async -> Float? {
        guard !clips.isEmpty else { return nil }
        var formats: [SourceFormat] = []
        for clip in clips {
            guard let format = await sourceFormat(clip.url) else { return nil }
            formats.append(format)
        }
        guard let first = formats.first else { return nil }
        for other in formats.dropFirst() {
            guard CMFormatDescriptionEqual(other.video, otherFormatDescription: first.video),
                  other.size == first.size,
                  // 錄影檔的幀率是照實際格數算的，掉一兩格就差一點點；四捨五入後一樣才算同一個設定。
                  other.frameRate.rounded() == first.frameRate.rounded(),
                  other.transform == first.transform else { return nil }
            switch (first.audio, other.audio) {
            case (nil, nil):
                break
            case let (a?, b?):
                guard CMFormatDescriptionEqual(a, otherFormatDescription: b) else { return nil }
            default:
                // 有的段有聲音、有的沒有，交給重壓。
                return nil
            }
        }
        return first.frameRate
    }

    /// 直通輸出。成功而且畫面長度跟時間軸一致才回 true；否則刪掉寫出來的檔回 false。
    private static func exportPassthrough(_ composition: AVMutableComposition, to output: URL,
                                          frameRate: Float, expectedDuration: Double) async -> Bool {
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.mov) else { return false }
        session.outputURL = output
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }

        guard session.status == .completed, await matchesTimeline(output, expected: expectedDuration, frameRate: frameRate) else {
            try? FileManager.default.removeItem(at: output)
            return false
        }
        return true
    }

    /// 裁切點不在關鍵格時，如果直通把前面的格也帶進來，畫面會變長、字幕會對不上。
    /// 輸出的畫面長度和時間軸差超過一格就當作不能用。
    private static func matchesTimeline(_ output: URL, expected: Double, frameRate: Float) async -> Bool {
        guard expected.isFinite, expected > 0 else { return false }
        let asset = AVURLAsset(url: output)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange) else { return false }
        let actual = range.duration.seconds
        guard actual.isFinite, range.start.seconds.isFinite, abs(range.start.seconds) < 0.001 else { return false }
        let frame = 1.0 / Double(frameRate)
        return abs(actual - expected) <= frame
    }
}
