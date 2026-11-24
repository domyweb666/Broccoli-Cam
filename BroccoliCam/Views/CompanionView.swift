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
        let videoLayers: [AVPlayerLayer]
        var crop: CompanionView.Crop = .top {
            didSet {
                if crop != oldValue { setNeedsLayout() }
            }
        }
        private var shownFront = -1
        /// 疊放順序，最後一個在最上面。
        private var stacking: [Int]

        init(layerCount: Int) {
            videoLayers = (0..<layerCount).map { _ in AVPlayerLayer() }
            stacking = Array(0..<layerCount)
            super.init(frame: .zero)
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

        /// 換定格圖。播放中被影片蓋住看不到；只看得到定格圖時用淡化換。
        func setStill(_ image: UIImage?, animated: Bool) {
            guard stillView.image !== image else { return }
            guard animated else {
                stillView.image = image
                return
            }
            UIView.transition(with: stillView, duration: CompanionClipPlayer.fade,
                              options: .transitionCrossDissolve) {
                self.stillView.image = image
            }
        }

        /// 把指定的那台播放器疊到最上面淡入，舊的留在底下不動，等蓋滿了再拿掉。
        /// 兩台同時一進一出的話，中間會透出底色，換人時看起來會閃。
        func show(front: Int, animated: Bool) {
            guard front != shownFront else { return }
            shownFront = front

            guard videoLayers.indices.contains(front) else {
                hideOthers(than: front)
                return
            }
            stacking.removeAll { $0 == front }
            stacking.append(front)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (depth, index) in stacking.enumerated() {
                videoLayers[index].zPosition = CGFloat(depth + 1)
            }
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.shownFront == front else { return }
                self.hideOthers(than: front)
            }
            let top = videoLayers[front]
            top.opacity = 1
            if animated {
                let fadeIn = CABasicAnimation(keyPath: "opacity")
                fadeIn.fromValue = 0
                fadeIn.toValue = 1
                fadeIn.duration = CompanionClipPlayer.fade
                fadeIn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                top.add(fadeIn, forKey: "fadeIn")
            }
            CATransaction.commit()
        }

        private func hideOthers(than front: Int) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (index, videoLayer) in videoLayers.enumerated() where index != front {
                videoLayer.removeAnimation(forKey: "fadeIn")
                videoLayer.opacity = 0
            }
            CATransaction.commit()
        }
    }

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView(layerCount: player.players.count)
        view.setStill(player.still, animated: false)
        view.crop = crop
        for (index, videoLayer) in view.videoLayers.enumerated() {
            videoLayer.player = player.players[index]
        }
        view.show(front: player.front, animated: false)
        return view
    }

    func updateUIView(_ uiView: VideoView, context: Context) {
        uiView.crop = crop
        uiView.setStill(player.still, animated: true)
        uiView.show(front: player.front, animated: true)
    }
}
