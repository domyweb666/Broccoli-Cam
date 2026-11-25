import SwiftUI

/// 主畫面側邊的一條快速開關。預設只放語音跟隨、一鍵優化兩顆；
/// 設定裡打開「主畫面也放構圖和防抖鍵」才多出構圖線、防抖（QC-0012，回報 #87）。
/// 每顆是「圓形圖示＋底下一行短字」，一眼看得懂是幹嘛的。
/// 版面不跟著手機轉，橫放時每顆各自轉正（和控制列一樣）。
struct QuickToggles: View {
    @EnvironmentObject private var camera: CameraService
    @EnvironmentObject private var settings: SettingsStore
    /// 倒數、錄影、接片中。只剩語音跟隨能按，整條變淡，錄影時才不會分心。
    let isBusy: Bool
    /// 提綱的重點不跟聲音，這顆就不顯示。
    let showsVoice: Bool
    let angle: Double
    /// 每一顆圓鈕的邊長，至少 44。
    let side: CGFloat
    let onVoice: () -> Void
    let onLook: () -> Void

    /// 圖示和底下短字之間的空隙。
    fileprivate static let captionGap: CGFloat = 2
    /// 短字那一行的高度。字級上限 xLarge 的 caption2 放得下。
    fileprivate static let captionTextHeight: CGFloat = 16
    /// 每顆比圓鈕多出來的長度（短字＋空隙）。
    fileprivate static let captionHeight: CGFloat = captionGap + captionTextHeight

    /// 會顯示幾顆。外面算高度和這裡實際排的都用這個，兩邊才會一致。
    /// 一鍵優化一定在；構圖線、防抖要設定裡打開才放，防抖還要裝置有兩種以上可以切。
    static func count(showsVoice: Bool, showsAll: Bool, stabilizationChoices: Int) -> Int {
        var total = 1
        if showsVoice { total += 1 }
        if showsAll {
            total += 1
            if stabilizationChoices > 1 { total += 1 }
        }
        return total
    }

    /// 整條的高度，外面用來決定放得下哪一種大小。
    /// 橫放時每顆轉了 90 度，短字跑到旁邊，佔的長度只剩圓鈕那麼長。
    static func fullHeight(side: CGFloat, count: Int, sideways: Bool) -> CGFloat {
        let n: CGFloat = CGFloat(max(count, 1))
        let unit: CGFloat = sideways ? side : side + captionHeight
        return unit * n + 4 * (n - 1) + 3 * 2
    }

    private var showsGuide: Bool {
        settings.showAllQuickToggles
    }

    private var showsStabilization: Bool {
        settings.showAllQuickToggles && camera.availableStabilizations.count > 1
    }

    var body: some View {
        VStack(spacing: 4) {
            if showsVoice {
                voiceButton
            }
            lookButton
            if showsGuide {
                guideButton
            }
            if showsStabilization {
                stabilizationButton
            }
        }
        .padding(3)
        .background(.black.opacity(isBusy ? 0.18 : 0.35),
                    in: RoundedRectangle(cornerRadius: side / 2 + 3, style: .continuous))
    }

    private var voiceButton: some View {
        QuickButton(systemImage: "waveform", isOn: settings.voiceFollow, caption: "跟讀",
                    label: "語音跟隨", value: settings.voiceFollow ? "開" : "關",
                    angle: angle, side: side, dim: isBusy ? 0.6 : 1, action: onVoice)
    }

    private var lookButton: some View {
        QuickButton(systemImage: "wand.and.stars", isOn: settings.lookEnabled, caption: "優化",
                    label: "一鍵優化", value: settings.lookEnabled ? "開" : "關",
                    angle: angle, side: side, dim: isBusy ? 0.25 : 1, action: onLook)
            .disabled(isBusy)
    }

    private var guideButton: some View {
        QuickButton(systemImage: guideImage, isOn: settings.guideStyle != .off, caption: "構圖",
                    label: "構圖線", value: settings.guideStyle.label,
                    angle: angle, side: side, dim: isBusy ? 0.25 : 1) {
            settings.guideStyle = settings.guideStyle.next
        }
        .disabled(isBusy)
    }

    private var stabilizationButton: some View {
        QuickButton(systemImage: "figure.walk.motion", isOn: stabilization != .off, caption: "防抖",
                    label: "防抖", value: stabilization.label,
                    angle: angle, side: side,
                    badge: stabilization == .strong ? "強" : nil, dim: isBusy ? 0.25 : 1,
                    action: nextStabilization)
            .disabled(isBusy)
    }

    /// 實際生效的強度，不是設定裡選的。
    private var stabilization: StabilizationLevel {
        camera.effectiveStabilization(settings.stabilization)
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
        let index = list.firstIndex(of: stabilization) ?? 0
        settings.stabilization = list[(index + 1) % list.count]
    }
}

private struct QuickButton: View {
    let systemImage: String
    let isOn: Bool
    /// 圖示底下的短字（跟讀、優化、構圖、防抖）。
    let caption: String
    let label: String
    let value: String
    let angle: Double
    let side: CGFloat
    var badge: String?
    /// 錄影時各顆自己淡，還能按的那顆淡得少一點。
    /// 不要改成整條一起 .opacity：iOS 26 實測那樣錄影中連還能按的語音跟隨都收不到點擊。
    var dim: Double = 1
    let action: () -> Void

    /// 直放時的大小：圓鈕在上、短字在下。
    private var uprightSize: CGSize {
        CGSize(width: side, height: side + QuickToggles.captionHeight)
    }

    var body: some View {
        let sideways: Bool = angle != 0
        Button(action: action) {
            unit
                .frame(width: uprightSize.width, height: uprightSize.height)
                // 整顆（圖示連短字）一起轉，橫放時使用者看到的還是圖示在上、字在下。
                .rotationEffect(.degrees(angle))
                // 轉了 90 度後佔的長寬對調，外框跟著換，才不會凸出底色。
                .frame(width: sideways ? uprightSize.height : uprightSize.width,
                       height: sideways ? uprightSize.width : uprightSize.height)
                .animation(.easeInOut(duration: 0.25), value: angle)
                .opacity(dim)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private var unit: some View {
        VStack(spacing: QuickToggles.captionGap) {
            icon
                .background(isOn ? Theme.accent : Color.clear, in: Circle())
            Text(caption)
                .font(.caption2.weight(.semibold))
                // 和圖示一樣設上限，字級放到很大時不會撐破這一條。
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: side, height: QuickToggles.captionTextHeight)
                .accessibilityHidden(true)
        }
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
    /// 底下有自己的小窗時左右排，往下的那顆才不會疊到小窗。
    var sideBySide = false
    let onJump: (_ forward: Bool) -> Void

    var body: some View {
        // 橫放時使用者看到的「上」是手機的右邊（90）或左邊（-90），兩顆改成左右排，看起來還是上下。
        let isColumn: Bool = angle == 0 && !sideBySide
        let stack: AnyLayout = isColumn ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
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
