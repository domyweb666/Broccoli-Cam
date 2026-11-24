import SwiftUI
import AVKit
import AVFoundation

/// 錄影完成：預覽、儲存到照片圖庫、重新錄影、返回。
struct VideoReviewView: View {
    @EnvironmentObject private var camera: CameraService
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    let video: RecordedVideo
    /// 存到照片成功。
    var onSaved: () -> Void = {}
    /// 使用者不要這一支了。檔案由外面在這一頁關掉之後刪，這裡不刪。
    var onDiscard: () -> Void = {}
    /// 丟掉接成這一支的各段（只有接好的影片會叫）。
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
    @State private var showNotice = false
    @State private var subtitleState: SubtitleState = .idle
    @State private var sharedSubtitle: SharedFile?

    private enum SubtitleState: Equatable {
        case idle
        case working
        case done(String)
        case failed(String)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 14) {
                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(video.isLandscape ? 16 / 9 : 9 / 16, contentMode: .fit)
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

                subtitleRow

                HStack(spacing: 12) {
                    Button {
                        if saveState == .saved {
                            // 單支影片和分段沒關係，不要順手刪掉還沒接完的段落。
                            if video.isStitched { onDiscardAll() }
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
                    // 正在複製到照片，這時候丟掉會兩頭空。
                    .disabled(saveState == .saving)

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
                    onDiscard()
                    close()
                }
                Button("全部丟掉重來", role: .destructive) {
                    onDiscard()
                    onDiscardAll()
                    close()
                }
            } else {
                Button("丟掉並重錄", role: .destructive) {
                    onDiscard()
                    close()
                }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("錄影有狀況", isPresented: $showNotice) {
            Button("好") {}
        } message: {
            Text(video.notice ?? "")
        }
        .onAppear {
            showNotice = video.notice != nil
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
        }
        .sheet(item: $sharedSubtitle) { file in
            ShareSheet(items: [file.url])
        }
        .statusBarHidden(true)
    }

    /// 字幕檔：用稿子對這支影片的聲音，做出 SRT，再交給分享選單（存到檔案、AirDrop、傳到剪輯 App）。
    @ViewBuilder
    private var subtitleRow: some View {
        VStack(spacing: 6) {
            Button {
                makeSubtitles()
            } label: {
                HStack(spacing: 8) {
                    if subtitleState == .working {
                        ProgressView().tint(.white)
                        Text("正在對字幕…")
                    } else {
                        Image(systemName: "captions.bubble")
                        Text("產生字幕檔（SRT）")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(subtitleState == .working)

            switch subtitleState {
            case .done(let note):
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
    }

    private func makeSubtitles() {
        subtitleState = .working
        player?.pause()
        let url = video.url
        let script = video.script
        let maxChars = Int(settings.subtitleMaxChars)
        Task {
            do {
                let result = try await SubtitleMaker.make(videoURL: url, script: script, maxChars: maxChars) { message in
                    camera.log(message)
                }
                await MainActor.run {
                    let note: String
                    if script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        note = "沒有稿子，字幕是直接聽出來的，可能有錯字。共 \(result.cueCount) 句。"
                    } else if !result.recognized {
                        note = "這支手機現在不能辨識中文，時間是照字數平均排的，匯入後請自己調。共 \(result.cueCount) 句。"
                    } else if result.coverage < 0.3 {
                        note = "聲音和稿子對不太上，時間是照字數平均排的，匯入後請自己調。共 \(result.cueCount) 句。"
                    } else {
                        note = "共 \(result.cueCount) 句，字用的是你的稿子。"
                    }
                    subtitleState = .done(note)
                    sharedSubtitle = SharedFile(url: result.url)
                }
            } catch {
                await MainActor.run {
                    subtitleState = .failed(error.localizedDescription)
                    camera.log("字幕失敗：\(error.localizedDescription)")
                }
            }
        }
    }

    private func save() {
        saveState = .saving
        PhotoSaver.save(videoAt: video.url) { result in
            switch result {
            case .success:
                saveState = .saved
                onSaved()
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

/// 要交給分享選單的檔案。
private struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// 系統分享選單。
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
