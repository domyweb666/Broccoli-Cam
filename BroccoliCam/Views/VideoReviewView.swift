import SwiftUI
import AVKit
import AVFoundation

/// 錄影完成：預覽、儲存到照片圖庫、重新錄影、返回。
struct VideoReviewView: View {
    @EnvironmentObject private var camera: CameraService
    @Environment(\.dismiss) private var dismiss
    let video: RecordedVideo
    /// 丟掉所有已錄的段落（分段錄影用）。
    var onDiscardAll: () -> Void = {}

    private enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    @State private var player: AVPlayer?
    @State private var saveState: SaveState = .idle
    @State private var confirmDiscard = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 14) {
                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(9 / 16, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    Spacer()
                }

                if case .failed(let message) = saveState {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.yellow)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                HStack(spacing: 12) {
                    Button {
                        if saveState == .saved {
                            onDiscardAll()
                            close()
                        } else {
                            confirmDiscard = true
                        }
                    } label: {
                        Text(saveState == .saved ? "再錄一支" : (video.isStitched ? "回去修改" : "重新錄影"))
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    Button {
                        save()
                    } label: {
                        Group {
                            switch saveState {
                            case .saving:
                                ProgressView().tint(.black)
                            case .saved:
                                Label("已儲存", systemImage: "checkmark")
                            default:
                                Text("儲存到照片")
                            }
                        }
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .disabled(saveState == .saving || saveState == .saved)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .confirmationDialog(video.isStitched ? "這支影片還沒儲存" : "這支影片還沒儲存，確定要丟掉重錄？",
                            isPresented: $confirmDiscard, titleVisibility: .visible) {
            if video.isStitched {
                // 各段都還留著，回去只重錄想改的那一段。
                Button("回去重錄其中一段") {
                    close()
                }
                Button("全部丟掉重來", role: .destructive) {
                    onDiscardAll()
                    close()
                }
            } else {
                Button("丟掉並重錄", role: .destructive) {
                    close()
                }
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            // 回放時先停相機，並把音訊切到播放，聲音才會從喇叭出來。
            camera.stop()
            let audioSession = AVAudioSession.sharedInstance()
            do {
                try audioSession.setCategory(.playback, mode: .moviePlayback)
                try audioSession.setActive(true)
            } catch {
                camera.log("回放音訊設定失敗：\(error.localizedDescription)")
            }
            let newPlayer = AVPlayer(url: video.url)
            player = newPlayer
            newPlayer.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
            try? FileManager.default.removeItem(at: video.url)
        }
        .statusBarHidden(true)
    }

    private func save() {
        saveState = .saving
        PhotoSaver.save(videoAt: video.url) { result in
            switch result {
            case .success:
                saveState = .saved
                camera.log("已儲存到照片圖庫")
            case .failure(let error):
                saveState = .failed(error.localizedDescription)
                camera.log("儲存失敗：\(error.localizedDescription)")
            }
        }
    }

    private func close() {
        player?.pause()
        dismiss()
    }
}
