import SwiftUI
import UIKit

/// 手機現在是直的還是橫的。App 的介面鎖直式，橫放時由各個元件自己轉 90 度，
/// 做法和系統相機一樣：版面不動，字和圖示轉過來。
final class OrientationMonitor: ObservableObject {
    /// 介面元件要轉幾度，使用者看起來才是正的：0（直放）、90、-90（橫放的兩個方向）。
    @Published private(set) var angle: Double = 0

    private var observer: NSObjectProtocol?

    init() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    private func refresh() {
        // 測試用：模擬器沒辦法真的把手機轉過來，可以用這個值指定角度。
        let forced = UserDefaults.standard.double(forKey: "debugForceAngle")
        if forced == 90 || forced == -90 {
            if angle != forced { angle = forced }
            return
        }
        let next: Double
        switch UIDevice.current.orientation {
        case .portrait:
            next = 0
        case .landscapeLeft:
            // 手機頂端朝左：內容要順時針轉 90 度。
            next = 90
        case .landscapeRight:
            next = -90
        default:
            // 平放、倒過來、還不知道：維持上一次的判斷。
            return
        }
        if angle != next { angle = next }
    }
}

extension View {
    /// 橫放時把內容轉 90 度：先用對調過的寬高排版，轉過來之後剛好填滿原本的框。
    func turned(_ angle: Double, width: CGFloat, height: CGFloat) -> some View {
        let sideways = angle != 0
        return self
            .frame(width: sideways ? height : width, height: sideways ? width : height)
            .rotationEffect(.degrees(angle))
            .frame(width: width, height: height)
    }
}
