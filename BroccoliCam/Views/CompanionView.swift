import SwiftUI
import AVFoundation
import UIKit

/// 陪伴模式的聆聽者：播 CompanionClipPlayer 的 9:16 預錄短片。
/// 只是預覽上的畫面，不會錄進影片，也不會發出聲音。
/// 所有擺法都用這個 view，差在外框大小和裁法。
struct CompanionView: View {
    enum Crop {
        /// 寬或高貼滿外框，頭頂對齊上緣。
        case top
        /// 放大到臉（圓形頭像）。
        case face
        /// 眉毛到嘴巴的橫條（眼神條）。
        case eyes
    }

    @ObservedObject var player: CompanionClipPlayer
    var crop: Crop = .top

    var body: some View {
        CompanionVideoView(player: player, crop: crop)
            .allowsHitTesting(false)
            .accessibilityLabel("聆聽者")
    }
}

private struct CompanionVideoView: UIViewRepresentable {
    @ObservedObject var player: CompanionClipPlayer
    let crop: CompanionView.Crop

    final class VideoView: UIView {
        let stillView = UIImageView()
        let videoLayers = [AVPlayerLayer(), AVPlayerLayer()]
        var crop: CompanionView.Crop = .top {
            didSet {
                if crop != oldValue { setNeedsLayout() }
            }
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
        /// 定格圖的眼睛大約在高度 21% 的地方，放大時都拿眼睛當基準。
        private func videoRect() -> CGRect {
            let w = bounds.width
            let h = bounds.height
            guard w > 0, h > 0 else { return .zero }
            switch crop {
            case .face:
                let videoHeight = h * 2.6
                let videoWidth = videoHeight * 9 / 16
                return CGRect(x: (w - videoWidth) / 2, y: h / 2 - videoHeight * 0.21,
                              width: videoWidth, height: videoHeight)
            case .eyes:
                let videoWidth = w
                let videoHeight = videoWidth * 16 / 9
                return CGRect(x: 0, y: h * 0.34 - videoHeight * 0.21,
                              width: videoWidth, height: videoHeight)
            case .top:
                break
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
        view.crop = crop
        for (index, videoLayer) in view.videoLayers.enumerated() {
            videoLayer.player = player.players[index]
        }
        view.show(front: player.front, animated: false)
        return view
    }

    func updateUIView(_ uiView: VideoView, context: Context) {
        uiView.crop = crop
        uiView.show(front: player.front, animated: true)
    }
}
