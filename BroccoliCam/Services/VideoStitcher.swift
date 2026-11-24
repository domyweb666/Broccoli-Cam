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
        var audioTrack: AVMutableCompositionTrack?
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
                if audioTrack == nil {
                    audioTrack = composition.addMutableTrack(
                        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                let audioRange = try await sourceAudio.load(.timeRange)
                let clipped = range.intersection(audioRange)
                if clipped.duration.seconds > 0 {
                    let at = cursor + (clipped.start - range.start)
                    try audioTrack?.insertTimeRange(clipped, of: sourceAudio, at: at)
                }
            }

            offsets.append(cursor.seconds)
            durations.append(range.duration.seconds)
            cursor = cursor + range.duration
        }
        return (composition, offsets, durations, transform)
    }

    /// 輸出到 output，這個檔名不能已經存在。失敗時會把寫到一半的檔刪掉，各段不動。
    static func stitch(_ clips: [Clip], to output: URL) async throws {
        let composition = try await Self.composition(clips).composition

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
        session.shouldOptimizeForNetworkUse = true

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
}
