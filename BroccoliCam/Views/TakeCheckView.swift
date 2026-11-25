import SwiftUI
import AVKit
import AVFoundation
import Combine

/// 檢查的小卡：最多三條，點一條去聽。
struct TakeCheckCard: View {
    let entries: [TakeCheckEntry]
    /// 正在聽的要把聲音送出去。
    let sendsAudioOut: Bool
    let onOpen: (TakeCheckEntry, TakeIssue) -> Void

    private static let most = 3
    private static let rowHeight: CGFloat = 44
    private static let statusHeight: CGFloat = 36

    /// 大概多高，橫放時要先留位置。
    static func height(_ entries: [TakeCheckEntry]) -> CGFloat {
        let summary = TakeCheckSummary(entries)
        var result: CGFloat = CGFloat(min(most, summary.rows.count)) * rowHeight
        if summary.rows.count > most { result += rowHeight }
        if summary.rows.isEmpty || summary.isChecking || summary.note != nil { result += statusHeight }
        return result
    }

    var body: some View {
        let summary = TakeCheckSummary(entries)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(summary.rows.prefix(Self.most))) { row in
                issueRow(row)
            }
            if summary.rows.count > Self.most {
                moreRow(summary.rows[Self.most], count: summary.rows.count - Self.most)
            }
            status(summary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .buttonStyle(.plain)
    }

    private func issueRow(_ row: TakeCheckSummary.Row) -> some View {
        Button {
            onOpen(row.entry, row.issue)
        } label: {
            TakeIssueLabel(text: row.text, kind: row.issue.kind)
                .frame(minHeight: Self.rowHeight)
        }
    }

    private func moreRow(_ row: TakeCheckSummary.Row, count: Int) -> some View {
        Button {
            onOpen(row.entry, row.issue)
        } label: {
            Text("還有 \(count) 處")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func status(_ summary: TakeCheckSummary) -> some View {
        if summary.isChecking {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(.white)
                Text("檢查中")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                if sendsAudioOut {
                    CaptionNetworkLine()
                }
            }
            .frame(minHeight: Self.statusHeight)
        } else if let note = summary.note {
            Label(note, systemImage: "exclamationmark.triangle")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.yellow)
                .frame(minHeight: Self.statusHeight)
        } else if summary.isClean {
            Label("沒問題", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.good)
                .frame(minHeight: Self.statusHeight)
        }
    }
}

/// 一處：哪一種、稿子和聽到的、可以播。
private struct TakeIssueLabel: View {
    let text: String
    let kind: TakeIssue.Kind

    private var icon: String {
        switch kind {
        case .number: return "number"
        case .missing: return "text.badge.minus"
        case .word: return "arrow.left.arrow.right"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.yellow)
                .frame(width: 22)
            Text(text)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Image(systemName: "play.circle.fill")
                .foregroundStyle(Theme.accent)
        }
        .font(.subheadline)
        .contentShape(Rectangle())
    }
}

/// 從那一處前面一點開始播的小視窗。開著的時候相機先停，關掉由外面再叫起來。
struct TakePlaybackView: View {
    @EnvironmentObject private var camera: CameraService
    @Environment(\.dismiss) private var dismiss
    let playback: TakePlayback
    /// 按鈕上的字。nil 是不能重錄。
    let retakeTitle: String?
    /// 記下要重錄。視窗自己會關，真的動手要等關掉之後，檔案還在播。
    let onRetake: () -> Void

    @StateObject private var player = TakePlayer()

    var body: some View {
        VStack(spacing: 12) {
            header
            video
            list
            if let retakeTitle {
                retakeButton(retakeTitle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .onAppear(perform: appeared)
        .onDisappear {
            player.close()
        }
    }

    private var header: some View {
        HStack {
            Text(playback.title ?? "")
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("關閉")
        }
    }

    @ViewBuilder
    private var video: some View {
        if player.isBroken {
            Text("影片播不出來")
                .font(.body)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VideoPlayer(player: player.player)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxHeight: .infinity)
        }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(playback.issues) { issue in
                    Button {
                        player.play(at: issue.time)
                    } label: {
                        TakeIssueLabel(text: issue.text, kind: issue.kind)
                            .frame(minHeight: 48)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // 超過三條半就捲，影片才看得清楚。
        .frame(height: min(168, CGFloat(playback.issues.count) * 48))
    }

    private func retakeButton(_ title: String) -> some View {
        Button {
            onRetake()
            dismiss()
        } label: {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func appeared() {
        // 和完成頁一樣：先停相機，再把音訊切到播放，聲音才會從喇叭出來。
        camera.stop()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            camera.log("檢查播放的音訊設定失敗：\(error.localizedDescription)")
        }
        player.open(playback.url, at: playback.time)
    }
}

/// 從某一秒開始播。影片還沒準備好就先記著，準備好再跳。
@MainActor
final class TakePlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var isBroken = false

    /// 提前多久開始播（秒）。
    private let lead = 0.5
    private var target: Double?
    private var watch: AnyCancellable?

    func open(_ url: URL, at time: Double) {
        guard watch == nil else { return }
        target = time
        let item = AVPlayerItem(url: url)
        watch = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.itemMoved(status)
                }
            }
        player.replaceCurrentItem(with: item)
    }

    func play(at time: Double) {
        target = time
        guard player.currentItem?.status == .readyToPlay else { return }
        jump()
    }

    func close() {
        player.pause()
        watch = nil
        target = nil
        player.replaceCurrentItem(with: nil)
    }

    private func itemMoved(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay: jump()
        case .failed: isBroken = true
        default: break
        }
    }

    private func jump() {
        guard let time = target, time.isFinite else { return }
        target = nil
        player.seek(to: CMTime(seconds: max(0, time - lead), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }
}
