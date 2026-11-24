import SwiftUI
import AVFoundation
import AVKit
import QuartzCore

/// 前鏡頭預覽。外層把這個 view 的大小固定成 9:16，所以看到的範圍就是錄到的範圍。
/// 整個主畫面只能有一個，換擺法時只改大小和位置。重建預覽層會卡住主執行緒，
/// 而且新的預覽層常常接不回執行中的 session，自己的畫面就一直是黑的（QC-0005）。
///
/// 底層一直是 AVCaptureVideoPreviewLayer：RotationCoordinator 和臉部座標都靠它。
/// 有逐格處理或開防抖時，才在上面疊一張 CAMetalLayer 畫處理過的影格。
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

        override func layoutSubviews() {
            super.layoutSubviews()
            layoutMetalLayer()
            onLayout?()
        }

        /// 疊上或拿掉處理過的畫面。每次都用新的圖層：還沒畫出第一張之前它是透明的，
        /// 底下的原生預覽照樣看得到，切換時就不會黑一下，也不會閃出上一次的舊畫面。
        func setMetalActive(_ active: Bool) {
            if active {
                addMetalLayer()
            } else {
                removeMetalLayer()
            }
        }

        private func addMetalLayer() {
            guard metalLayer == nil, let target = renderer, let device = CameraGPU.device else { return }
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
            target.setLayer(metal, size: metal.drawableSize)
        }

        private func removeMetalLayer() {
            renderer?.setLayer(nil, size: .zero)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer?.removeFromSuperlayer()
            CATransaction.commit()
            metalLayer = nil
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
}
