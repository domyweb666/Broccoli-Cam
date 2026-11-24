import SwiftUI

/// 主畫面側邊的一條快速開關：語音跟隨、畫面優化、構圖線、防抖。
/// 版面不跟著手機轉，橫放時圖示各自轉正（和控制列一樣）。
struct QuickToggles: View {
    @EnvironmentObject private var camera: CameraService
    @EnvironmentObject private var settings: SettingsStore
    /// 倒數、錄影、接片中。只剩語音跟隨能按，整條變淡，錄影時才不會分心。
    let isBusy: Bool
    let angle: Double
    /// 每一顆的邊長，至少 44。
    let side: CGFloat
    let onVoice: () -> Void
    let onLook: () -> Void

    /// 四顆全部顯示時整條的高度，外面用來決定放得下哪一種大小。
    static func fullHeight(side: CGFloat) -> CGFloat {
        side * 4 + 4 * 3 + 3 * 2
    }

    private var showsStabilization: Bool {
        camera.availableStabilizations.count > 1
    }

    var body: some View {
        VStack(spacing: 4) {
            if settings.usesPrompter {
                voiceButton
            }
            lookButton
            guideButton
            if showsStabilization {
                stabilizationButton
            }
        }
        .padding(3)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: side / 2 + 3, style: .continuous))
        .opacity(isBusy ? 0.5 : 1)
    }

    private var voiceButton: some View {
        QuickButton(systemImage: "waveform", isOn: settings.voiceFollow,
                    label: "語音跟隨", value: settings.voiceFollow ? "開" : "關",
                    angle: angle, side: side, action: onVoice)
    }

    private var lookButton: some View {
        QuickButton(systemImage: "wand.and.stars", isOn: settings.lookEnabled,
                    label: "一鍵優化", value: settings.lookEnabled ? "開" : "關",
                    angle: angle, side: side, action: onLook)
            .disabled(isBusy)
            .opacity(isBusy ? 0.5 : 1)
    }

    private var guideButton: some View {
        QuickButton(systemImage: guideImage, isOn: settings.guideStyle != .off,
                    label: "構圖線", value: settings.guideStyle.label,
                    angle: angle, side: side) {
            settings.guideStyle = settings.guideStyle.next
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.5 : 1)
    }

    private var stabilizationButton: some View {
        QuickButton(systemImage: "figure.walk.motion", isOn: settings.stabilization != .off,
                    label: "防抖", value: settings.stabilization.label,
                    angle: angle, side: side,
                    badge: settings.stabilization == .strong ? "強" : nil,
                    action: nextStabilization)
            .disabled(isBusy)
            .opacity(isBusy ? 0.5 : 1)
    }

    private var guideImage: String {
        switch settings.guideStyle {
        case .off: return "viewfinder"
        case .head: return "person.crop.rectangle"
        case .grid: return "squareshape.split.3x3"
        }
    }

    private func nextStabilization() {
        let list: [StabilizationLevel] = camera.availableStabilizations
        guard !list.isEmpty else { return }
        let index = list.firstIndex(of: settings.stabilization) ?? 0
        settings.stabilization = list[(index + 1) % list.count]
    }
}

private struct QuickButton: View {
    let systemImage: String
    let isOn: Bool
    let label: String
    let value: String
    let angle: Double
    let side: CGFloat
    var badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            icon
                .rotationEffect(.degrees(angle))
                .animation(.easeInOut(duration: 0.25), value: angle)
                .frame(width: side, height: side)
                .background(isOn ? Theme.accent : Color.clear, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private var icon: some View {
        Image(systemName: systemImage)
            .font(.title3.weight(.medium))
            // 圓鈕大小固定，字級放到很大時圖示不要超出去。
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .foregroundStyle(isOn ? Color.black : Color.white)
            .frame(width: side, height: side)
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(.black.opacity(0.75), in: Circle())
                }
            }
    }
}

/// 提詞旁邊的跳轉鍵：往上、往下各一顆。
struct JumpKeys: View {
    let angle: Double
    let side: CGFloat
    let onJump: (_ forward: Bool) -> Void

    var body: some View {
        // 橫放時使用者看到的「上」是手機的右邊（90）或左邊（-90），兩顆改成左右排，看起來還是上下。
        let stack: AnyLayout = angle == 0 ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        stack {
            if angle > 0 {
                key(forward: true)
                key(forward: false)
            } else {
                key(forward: false)
                key(forward: true)
            }
        }
    }

    private func key(forward: Bool) -> some View {
        Button {
            onJump(forward)
        } label: {
            Image(systemName: forward ? "chevron.down" : "chevron.up")
                .font(.title3.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                .foregroundStyle(.white.opacity(0.9))
                .rotationEffect(.degrees(angle))
                .frame(width: side, height: side)
                .background(.black.opacity(0.4), in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(forward ? "提詞往下跳" : "提詞往上跳")
    }
}
