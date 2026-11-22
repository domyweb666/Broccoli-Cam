import SwiftUI
import AVFoundation
import UIKit

/// 陪伴模式的聆聽者：播 CompanionClipPlayer 的 9:16 預錄短片。
/// 只是預覽上的畫面，不會錄進影片，也不會發出聲音。
/// 四種擺法（圓形頭像、頂部小窗、上下分割、視訊通話）都用這個 view，差在外框大小和裁法。
struct CompanionView: View {
    @ObservedObject var player: CompanionClipPlayer
    /// 放大到臉（圓形頭像用）。關掉時影片寬度貼齊外框、頭頂對齊上緣。
    var faceZoom = false

    var body: some View {
        CompanionVideoView(player: player, faceZoom: faceZoom)
            .allowsHitTesting(false)
            .accessibilityLabel("聆聽者")
    }
}

private struct CompanionVideoView: UIViewRepresentable {
    @ObservedObject var player: CompanionClipPlayer
    let faceZoom: Bool

    final class VideoView: UIView {
        let stillView = UIImageView()
        let videoLayers = [AVPlayerLayer(), AVPlayerLayer()]
        var faceZoom = false {
            didSet { setNeedsLayout() }
        }
        private var shownFront = -1

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            // 和定格圖背景差不多的顏色，第一次載入前不會閃黑。
            backgroundColor = UIColor(red: 0.73, green: 0.67, blue: 0.70, alpha: 1)
            stillView.contentMode = .scaleToFill
            addSubview(stillView)
            for videoLayer in videoLayers {
                videoLayer.videoGravity = .resizeAspect
                videoLayer.opacity = 0
                layer.addSublayer(videoLayer)
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// 9:16 影片在外框裡的位置。
        /// 一般：寬或高至少一邊貼滿，頭頂貼齊上緣，讓眼睛靠近前鏡頭。
        /// 放大到臉：頭到脖子塞滿外框（定格圖的眼睛大約在高度 21% 的地方）。
        private func videoRect() -> CGRect {
            let w = bounds.width
            let h = bounds.height
            guard w > 0, h > 0 else { return .zero }
            if faceZoom {
                let videoHeight = h * 2.6
                let videoWidth = videoHeight * 9 / 16
                return CGRect(x: (w - videoWidth) / 2, y: h / 2 - videoHeight * 0.21,
                              width: videoWidth, height: videoHeight)
            }
            let scale = max(w / 9, h / 16)
            let videoWidth = 9 * scale
            let videoHeight = 16 * scale
            return CGRect(x: (w - videoWidth) / 2, y: 0, width: videoWidth, height: videoHeight)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let rect = videoRect()
            stillView.frame = rect
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayers.forEach { $0.frame = rect }
            CATransaction.commit()
        }

        /// 把指定的那台播放器淡入、另一台淡出。
        func show(front: Int, animated: Bool) {
            guard front != shownFront else { return }
            shownFront = front
            CATransaction.begin()
            if animated {
                CATransaction.setAnimationDuration(CompanionClipPlayer.fade)
            } else {
                CATransaction.setDisableActions(true)
            }
            for (index, videoLayer) in videoLayers.enumerated() {
                videoLayer.opacity = index == front ? 1 : 0
            }
            CATransaction.commit()
        }
    }

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.stillView.image = player.still
        view.faceZoom = faceZoom
        for (index, videoLayer) in view.videoLayers.enumerated() {
            videoLayer.player = player.players[index]
        }
        view.show(front: player.front, animated: false)
        return view
    }

    func updateUIView(_ uiView: VideoView, context: Context) {
        uiView.faceZoom = faceZoom
        uiView.show(front: player.front, animated: true)
    }
}
