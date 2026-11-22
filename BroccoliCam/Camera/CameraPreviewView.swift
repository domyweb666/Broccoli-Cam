import SwiftUI
import AVFoundation
import AVKit

/// 前鏡頭預覽。外層把這個 view 的大小固定成 9:16，所以看到的範圍就是錄到的範圍。
/// 陪伴模式「上下分割」時外框不是 9:16，用 fill 裁滿外框，看到的會比錄到的少一些。
struct CameraPreviewView: UIViewRepresentable {
    let camera: CameraService
    var fill = false

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

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        camera.attachPreviewLayer(view.previewLayer)
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

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.previewLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}
