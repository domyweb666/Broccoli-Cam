import AVFoundation
import Speech

/// 校對頁叫到辨識（A）和燒錄（B）的地方都集中在這裡。那邊的介面改了只動這一個檔。
enum CaptionBridge {
    /// 這支手機辨識中文要不要把聲音送出去。
    static var sendsAudioOut: Bool {
        let recognizer = SFSpeechRecognizer(locale: SpeechFollower.locale)
        return !(recognizer?.supportsOnDeviceRecognition ?? false)
    }

    /// 接起來之後的長度和方向。
    struct Timeline {
        let offsets: [Double]
        let durations: [Double]
        let isLandscape: Bool?

        var total: Double {
            zip(offsets, durations).map { $0 + $1 }.max() ?? 0
        }
    }

    static func stitchClips(_ project: CaptionProject) -> [VideoStitcher.Clip] {
        project.clips.map { clip in
            VideoStitcher.Clip(url: CaptionStore.shared.url(clip.file, in: project.id),
                               start: clip.start, end: clip.end)
        }
    }

    static func timeline(_ project: CaptionProject) async throws -> Timeline {
        let result = try await VideoStitcher.composition(stitchClips(project))
        let natural: CGSize = result.composition.naturalSize
        let turned: CGRect = CGRect(origin: .zero, size: natural).applying(result.transform)
        let width = abs(turned.width)
        let height = abs(turned.height)
        let known = width > 1 && height > 1
        return Timeline(offsets: result.offsets, durations: result.durations,
                        isLandscape: known ? width > height : nil)
    }

    /// 對字幕。progress 可能在任何執行緒。fresh：聽過的也重新辨識一次。
    /// hearings 是各段聽到的字，沒辨識的是 nil。
    static func build(_ project: CaptionProject, timeline: Timeline, maxChars: Int, fresh: Bool,
                      log: @escaping (String) -> Void,
                      progress: @escaping (Double) -> Void)
    async throws -> (lines: [CaptionLine], recognition: CaptionRecognition, hearings: [TakeHearing?]) {
        let count = min(project.clips.count, timeline.offsets.count, timeline.durations.count)
        let result = try await CaptionBuilder.build(
            clips: (0..<count).map { index in
                (url: CaptionStore.shared.url(project.clips[index].file, in: project.id),
                 clip: project.clips[index],
                 offset: timeline.offsets[index],
                 duration: timeline.durations[index])
            },
            maxChars: maxChars,
            fresh: fresh,
            log: log,
            progress: progress
        )
        return (lines: result.lines, recognition: result.recognition, hearings: result.hearings)
    }

    /// 整支都沒聽到（沒網路、不能辨識）。只有部分失敗不算。
    static func heardNothing(_ lines: [CaptionLine], _ recognition: CaptionRecognition) -> Bool {
        recognition.engine == CaptionBuilder.noEngine || lines.allSatisfy { $0.status == .unrecognized }
    }

    static func makeVideo(_ project: CaptionProject) -> CaptionVideo {
        CaptionVideo(
            clips: project.clips.map { clip in
                (CaptionStore.shared.url(clip.file, in: project.id), clip.start, clip.end)
            },
            isLandscape: project.isLandscape
        )
    }

    static func srt(_ project: CaptionProject) -> String {
        SubtitleLines.srt(project.burnLines)
    }

    /// 除錯資訊要帶的辨識檢測。log 可能在任何執行緒。
    static func probe(log: @escaping (String) -> Void) {
        CaptionProbe.report(log: log)
    }
}
