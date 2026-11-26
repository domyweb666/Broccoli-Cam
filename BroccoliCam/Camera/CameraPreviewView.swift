import SwiftUI
import AVFoundation
import AVKit
import QuartzCore

/// 前鏡頭預覽。外層把這個 view 的大小固定成 9:16，所以看到的範圍就是錄到的範圍。
/// 整個主畫面只能有一個，換擺法時只改大小和位置。重建預覽層會卡住主執行緒，
/// 而且新的預覽層常常接不回執行中的 session，自己的畫面就一直是黑的（QC-0005）。
///
/// 底層一直是 AVCaptureVideoPreviewLayer：RotationCoordinator 和臉部座標都靠它。
/// 有逐格處理或開防抖時，才在上面疊一張 CAMetalLayer 畫處理過的影格；
/// 那張畫出來之後，底下原生預覽的連線先暫停（isEnabled = false），不再白收畫面。
struct CameraPreviewView: UIViewRepresentable {
    let camera: CameraService

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // layerClass 已指定，轉型必定成功。
            layer as! AVCaptureVideoPreviewLayer
        }

        /// 每次排版都重新確認預覽是直式。
        var onLayout: (() -> Void)?
        var renderer: MetalPreviewRenderer?
        private var metalLayer: CAMetalLayer?
        /// 剛拿掉、還留著蓋一下的 Metal 圖層（等原生預覽恢復出畫面）。
        private var retiringLayers: [CAMetalLayer] = []
        /// 原生預覽的連線是不是被這個 view 暫停了。
        private var nativePaused = false
        /// SwiftUI 拆掉這個 view 之後就不再接相機的通知。
        private var tornDown = false

        /// 拿掉 Metal 圖層之後，處理過的最後一張再蓋多久，等原生預覽恢復收畫面（秒）。
        private static let retireDelay: TimeInterval = 0.12

        /// 開 Metal 預覽時要不要暫停原生預覽的連線。真機上若發現臉的位置、旋轉跟著壞掉，改成 false 就回到以前的做法。
        private static let pausesNativeUnderMetal = true

        override func layoutSubviews() {
            super.layoutSubviews()
            layoutMetalLayer()
            onLayout?()
        }

        /// 疊上或拿掉處理過的畫面。每次都用新的圖層：還沒畫出第一張之前它是透明的，
        /// 底下的原生預覽照樣看得到，切換時就不會黑一下，也不會閃出上一次的舊畫面。
        ///
        /// Metal 圖層畫出第一張之後就整個蓋住原生預覽（四周補黑、不透明），這時把原生預覽的連線暫停，
        /// 系統不用再每格把畫面送進底下那層、兩層也不用每格疊。圖層和連線都留著：
        /// RotationCoordinator、臉的座標換算、鏡像判斷都只看預覽層的幾何和連線設定，不看有沒有在出畫面。
        /// 拿掉 Metal 圖層時先恢復連線，再讓最後一張多蓋 0.12 秒（約原生預覽恢復出畫面要的時間）才拿掉。
        func setMetalActive(_ active: Bool) {
            guard !tornDown else { return }
            if active {
                addMetalLayer()
            } else {
                removeMetalLayer()
            }
        }

        /// SwiftUI 拆掉預覽 view 時呼叫：把 Metal 圖層從 renderer 和畫面上拿掉，不再留著 drawable。
        func tearDown() {
            tornDown = true
            onLayout = nil
            if let metal = metalLayer {
                renderer?.detach(metal)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer?.removeFromSuperlayer()
            for old in retiringLayers {
                old.removeFromSuperlayer()
            }
            CATransaction.commit()
            metalLayer = nil
            retiringLayers.removeAll()
        }

        private func addMetalLayer() {
            guard metalLayer == nil, let target = renderer, let device = CameraGPU.device else { return }
            // 上一個還在蓋著的就直接拿掉；原生預覽在拿掉時已經恢復了。
            dropRetiringLayers()
            let metal = CAMetalLayer()
            metal.device = device
            metal.pixelFormat = .bgra8Unorm
            // Core Image 用 compute 寫進去，不能只當 framebuffer。
            metal.framebufferOnly = false
            metal.colorspace = CameraGPU.colorSpace
            metal.isOpaque = false
            metal.contentsGravity = .resizeAspect
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.addSublayer(metal)
            CATransaction.commit()
            metalLayer = metal
            layoutMetalLayer()
            target.setLayer(metal, size: metal.drawableSize, onFirstFrame: { [weak self] drawn in
                self?.metalLayerDidDraw(drawn)
            })
        }

        /// Metal 圖層第一張畫好了（主執行緒）。還是同一個圖層才暫停原生預覽。
        private func metalLayerDidDraw(_ drawn: CAMetalLayer) {
            guard Self.pausesNativeUnderMetal, !tornDown, let metal = metalLayer, metal === drawn else { return }
            setNativePreviewPaused(true)
        }

        private func removeMetalLayer() {
            guard let metal = metalLayer else { return }
            renderer?.detach(metal)
            metalLayer = nil
            let wasPaused = nativePaused
            setNativePreviewPaused(false)
            guard wasPaused else {
                // 原生預覽一直都在出畫面，直接拿掉就好（和以前一樣）。
                drop(metal)
                return
            }
            // 原生預覽剛恢復，第一張可能還沒到：最後一張處理過的先留著蓋住，才不會黑一下或閃出暫停前的舊畫面。
            retiringLayers.append(metal)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retireDelay) { [weak self] in
                self?.drop(metal)
            }
        }

        private func drop(_ metal: CAMetalLayer) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metal.removeFromSuperlayer()
            CATransaction.commit()
            retiringLayers.removeAll { $0 === metal }
        }

        private func dropRetiringLayers() {
            for old in retiringLayers {
                drop(old)
            }
        }

        /// 暫停或恢復原生預覽層的連線。連線還沒建立（session 還沒設定好）就不動。
        private func setNativePreviewPaused(_ paused: Bool) {
            nativePaused = paused
            guard let connection = previewLayer.connection else { return }
            if connection.isEnabled == paused {
                connection.isEnabled = !paused
            }
        }

        private func layoutMetalLayer() {
            guard let metal = metalLayer else { return }
            let displayScale: CGFloat = traitCollection.displayScale
            let scale: CGFloat = displayScale > 0 ? displayScale : 3
            let pixels = CGSize(width: (bounds.width * scale).rounded(),
                                height: (bounds.height * scale).rounded())
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metal.contentsScale = scale
            metal.frame = bounds
            if metal.drawableSize != pixels {
                metal.drawableSize = pixels
            }
            CATransaction.commit()
            renderer?.noteSize(pixels)
        }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspect
        view.renderer = camera.previewRenderer
        camera.attachPreviewLayer(view.previewLayer)
        camera.attachMetalPreview { [weak view] active in
            view?.setMetalActive(active)
        }
        view.onLayout = { [weak camera] in
            camera?.applyPreviewRotation()
        }
        // 音量鍵、藍牙自拍遙控器當錄影鍵用。iOS 17.2 以上才有，舊版本就只有螢幕上的按鈕。
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { [weak camera] event in
                guard event.phase == .ended else { return }
                DispatchQueue.main.async {
                    camera?.onCaptureButton?()
                }
            }
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    /// 預覽 view 被拆掉：放掉 Metal 圖層。新的預覽 view 若已經先掛上自己的圖層，detach 不會動到它。
    static func dismantleUIView(_ uiView: PreviewUIView, coordinator: ()) {
        uiView.tearDown()
    }
}
