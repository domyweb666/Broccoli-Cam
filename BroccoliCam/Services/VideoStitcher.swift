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

    static func stitch(_ clips: [Clip]) async throws -> URL {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoStitchError.cannotExport
        }
        var audioTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        var transformSet = false

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
                videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
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

            cursor = cursor + range.duration
        }

        let session: AVAssetExportSession
        if let hevc = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality) {
            session = hevc
        } else if let fallback = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) {
            session = fallback
        } else {
            throw VideoStitchError.cannotExport
        }

        let name = "broccoli-merged-\(Int(Date().timeIntervalSince1970)).mov"
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: output)
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
        return output
    }
}
