import SwiftUI

/// 畫面優化面板：從底部滑出，只佔下面一截，上方的預覽看得到即時效果。
/// 參數寫進 settings，由 RecordingView 套到相機。
/// 拖滑桿的期間例外：值先放在 draft、直接叫相機套，放開才寫回 settings，
/// 拖動中不會每格都存一次設定、也不會讓整個主畫面跟著重算。
struct LookPanel: View {
    @EnvironmentObject private var camera: CameraService
    @EnvironmentObject private var settings: SettingsStore
    /// 倒數、錄影、接片中：滑桿可以拉，一鍵優化不能按。
    let isBusy: Bool
    /// 正在錄影。面板會蓋住計時，留一顆紅點。
    let isRecording: Bool
    let onClose: () -> Void

    @State private var analyzing = false
    @State private var note: String?
    /// 第幾次分析。面板關掉再開、或等太久放棄之後，舊的結果不可以再改畫面上的字。
    @State private var attempt = 0
    /// 拖動中的參數。nil 代表沒在拖，畫面直接顯示 settings.look。
    @State private var draft: LookParams?
    /// 正在被手指按住的滑桿（兩隻手指各拉一條也算得清楚）。全部放開才寫回 settings。
    @State private var editingItems: Set<LookItem> = []

    var body: some View {
        VStack(spacing: 8) {
            topRow
            actionRow
            if let note {
                Text(note)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            sliders
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { panelBackground }
        .contentShape(Rectangle())
        .onDisappear {
            // 拖到一半面板被關掉，收不到放開的事件，拖到的值在這裡存回去。
            editingItems = []
            commitDraft()
            // 按著比對的時候面板被關掉，也要還原。
            camera.setLookBypassed(false)
        }
        .onChange(of: isBusy) { _, busy in
            guard busy, analyzing else { return }
            attempt += 1
            analyzing = false
            camera.cancelOptimize()
        }
    }

    private var panelBackground: some View {
        UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous)
            .fill(Color(white: 0.09))
            .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - 按鈕

    private var topRow: some View {
        HStack(spacing: 10) {
            if isRecording {
                Circle()
                    .fill(Theme.record)
                    .frame(width: 10, height: 10)
                    .accessibilityLabel("錄影中")
            }
            Button(action: optimize) {
                HStack(spacing: 8) {
                    if analyzing {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                    Text("一鍵優化")
                }
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(analyzing || isBusy)
            .opacity(isBusy ? 0.35 : 1)

            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("關閉")
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                // 過場中切換開關就直接換，不要接著播一半的過場。
                camera.cancelLookTransition()
                settings.lookEnabled.toggle()
            } label: {
                PanelPill(title: settings.lookEnabled ? "優化 開" : "優化 關", isOn: settings.lookEnabled)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(settings.lookEnabled ? .isSelected : [])

            CompareButton(isEnabled: settings.lookEnabled) { on in
                camera.setLookBypassed(on)
            }

            Button(action: reset) {
                PanelPill(title: "還原", isOn: false)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 滑桿

    private var sliders: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(LookItem.allCases) { item in
                    LookSliderRow(item: item, value: binding(item)) { editing in
                        noteEditing(item, editing)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
    }

    private func binding(_ item: LookItem) -> Binding<Double> {
        Binding<Double>(
            get: { (draft ?? settings.look)[keyPath: item.keyPath] },
            set: { value in
                if !editingItems.isEmpty {
                    // 拖動中：只改 draft、直接套到相機，不寫設定。
                    // draft 被還原或一鍵優化清掉之後還在拖，就從最新的 settings 接著改。
                    var next: LookParams = draft ?? settings.look
                    guard next[keyPath: item.keyPath] != value || !settings.lookEnabled else { return }
                    next[keyPath: item.keyPath] = value
                    draft = next
                    camera.setLook(next, enabled: true)
                    if !settings.lookEnabled {
                        // 原本關著：打開的這一次連值一起存，RecordingView 跟著套的才是現在這個值，不會退回舊的。
                        // 整段拖動只會多寫這一次。
                        if settings.look != next { settings.look = next }
                        settings.lookEnabled = true
                    }
                    return
                }
                if !settings.lookEnabled { settings.lookEnabled = true }
                // 雙擊歸零、VoiceOver 調整：只改一次，直接寫回設定。
                // 滑桿拖動時同一格會重複回報，沒變就不要再寫。
                if settings.look[keyPath: item.keyPath] != value {
                    settings.look[keyPath: item.keyPath] = value
                }
            }
        )
    }

    /// 滑桿按下、放開。全部放開才把 draft 寫回 settings（RecordingView 會再 setLook 一次同樣的值）。
    private func noteEditing(_ item: LookItem, _ editing: Bool) {
        if editing {
            editingItems.insert(item)
        } else {
            editingItems.remove(item)
            if editingItems.isEmpty { commitDraft() }
        }
    }

    private func commitDraft() {
        guard let next = draft else { return }
        draft = nil
        if settings.look != next { settings.look = next }
    }

    // MARK: - 動作

    private func optimize() {
        guard !analyzing, !isBusy else { return }
        analyzing = true
        note = nil
        attempt += 1
        let current = attempt
        let store: SettingsStore = settings
        let service: CameraService = camera
        camera.optimizeLook { result in
            // 等太久已經放棄的那次，結果不套。
            guard current == attempt, analyzing else { return }
            analyzing = false
            guard let result else {
                note = "現在沒有畫面"
                return
            }
            // 結果回來時手指還按著滑桿的話，畫面上看的是 draft，以它當舊的樣子。
            let shown: LookParams = draft ?? store.look
            var params: LookParams = result.params
            params.smooth = shown.smooth
            // 先記下舊的樣子開始過場，再寫新的參數，預覽才會從舊的慢慢換成新的（QC-0012）。
            let style: LookTransition = store.lookTransition
            if style != LookTransition.none {
                service.beginLookTransition(from: shown, wasEnabled: store.lookEnabled, style: style)
            }
            // 拖到一半的值作廢，滑桿改顯示新的結果。
            let dropped: Bool = draft != nil
            draft = nil
            store.look = params
            store.lookEnabled = true
            // 存著的值剛好沒變時 RecordingView 不會再套一次，相機會停在 draft，自己補套。
            if dropped { service.setLook(params, enabled: true) }
            note = Self.noteText(result)
        }
        // 分析到一半相機被打斷的話，不要一直轉圈。
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard current == attempt, analyzing else { return }
            analyzing = false
            note = "現在沒有畫面"
        }
    }

    private func reset() {
        // 分析到一半按還原，那次的結果不要再套上來。
        attempt += 1
        analyzing = false
        camera.cancelOptimize()
        // 還原不做過場，進行中的也停掉。
        camera.cancelLookTransition()
        // 拖到一半的值作廢，滑桿改顯示還原後的值。
        let dropped: Bool = draft != nil
        draft = nil
        settings.look = .neutral
        settings.lookEnabled = false
        // 同上：存著的值沒變的話相機會停在 draft。
        if dropped { camera.setLook(.neutral, enabled: false) }
        note = nil
    }

    private static func noteText(_ result: LookResult) -> String? {
        var parts: [String] = []
        if !result.hasFace { parts.append("沒看到臉，用整個畫面判斷") }
        if result.stillTooDark { parts.append("請靠近光源") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

// MARK: - 參數

/// 面板上的十項參數，順序就是顯示順序。
private enum LookItem: String, CaseIterable, Identifiable {
    case exposure
    case temperature
    case tint
    case highlights
    case shadows
    case contrast
    case vibrance
    case denoise
    case sharpen
    case smooth

    var id: String { rawValue }

    var label: String {
        switch self {
        case .exposure: return "曝光"
        case .temperature: return "色溫"
        case .tint: return "色調"
        case .highlights: return "亮部"
        case .shadows: return "暗部"
        case .contrast: return "對比"
        case .vibrance: return "自然飽和度"
        case .denoise: return "降噪"
        case .sharpen: return "銳利"
        case .smooth: return "柔膚"
        }
    }

    var keyPath: WritableKeyPath<LookParams, Double> {
        switch self {
        case .exposure: return \LookParams.exposure
        case .temperature: return \LookParams.temperature
        case .tint: return \LookParams.tint
        case .highlights: return \LookParams.highlights
        case .shadows: return \LookParams.shadows
        case .contrast: return \LookParams.contrast
        case .vibrance: return \LookParams.vibrance
        case .denoise: return \LookParams.denoise
        case .sharpen: return \LookParams.sharpen
        case .smooth: return \LookParams.smooth
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .exposure: return -2...2
        case .denoise, .sharpen, .smooth: return 0...100
        default: return -100...100
        }
    }

    var step: Double {
        self == .exposure ? 0.1 : 1
    }

    func text(_ value: Double) -> String {
        if self == .exposure {
            // 0.04 這種會被印成 +0.0，先四捨五入再判斷正負。
            let rounded = (value * 10).rounded() / 10
            return rounded == 0 ? "0" : String(format: "%+.1f", rounded)
        }
        let whole = Int(value.rounded())
        return range.lowerBound < 0 && whole > 0 ? "+\(whole)" : "\(whole)"
    }
}

/// 一列：名稱、滑桿、數值。雙擊名稱或數值歸零。
private struct LookSliderRow: View {
    let item: LookItem
    @Binding var value: Double
    /// 手指按下滑桿（true）、放開（false）。
    let onEditing: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(item.label)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 84, alignment: .leading)
                .frame(minHeight: 46)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: zero)
                .accessibilityHidden(true)

            Slider(value: $value, in: item.range, step: item.step, onEditingChanged: onEditing)
                .accessibilityLabel(item.label)
                .accessibilityValue(item.text(value))
                .accessibilityAction(named: "歸零", zero)

            Text(item.text(value))
                .font(.subheadline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(value == 0 ? Color.white.opacity(0.5) : Theme.accent)
                .frame(width: 48, alignment: .trailing)
                .frame(minHeight: 46)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: zero)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
    }

    private func zero() {
        value = 0
    }
}

// MARK: - 小元件

private struct PanelPill: View {
    let title: String
    let isOn: Bool

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(isOn ? Color.black : Color.white)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(isOn ? Theme.accent : Color.white.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// 按住看沒處理過的畫面，放開就回來。
/// 用 GestureState：手勢被系統取消（來電、切 app）也會自己回到 false，不會卡在比對狀態。
private struct CompareButton: View {
    let isEnabled: Bool
    let onCompare: (Bool) -> Void

    @GestureState private var pressing = false

    var body: some View {
        PanelPill(title: "按住比對", isOn: pressing)
            .opacity(isEnabled ? 1 : 0.35)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressing) { _, state, _ in
                        state = true
                    }
            )
            .allowsHitTesting(isEnabled)
            .onChange(of: pressing) { _, on in
                onCompare(on)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("按住比對")
            .accessibilityAddTraits(.isButton)
    }
}
