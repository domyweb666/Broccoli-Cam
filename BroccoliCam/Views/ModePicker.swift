import SwiftUI
import UIKit

/// 主畫面按「看多少字」跳出來的選單。選聆聽者擺法才關掉，其他的可以一次調好幾樣。
struct ModeSheet: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    /// 預設展開的高度，照裡面實際有的東西一段段加起來，剛好看到全部、不會切一半。
    /// 放不下的時候系統會收到最高，裡面可以捲。
    private var height: CGFloat {
        // 上下留白（20＋8、20），加上拖拉把手和底部安全區約 60。
        var total: CGFloat = 28 + 20 + 60
        total += 80                                  // 全稿／提綱／不看
        total += 12 + SwitchCard.detailHeight        // 有人聽（兩行說明）
        total += 12 + SwitchCard.detailHeight        // 不看自己（兩行說明）
        guard settings.hasListener else { return total }
        total += 12 + SwitchCard.detailHeight        // 即時反應（兩行說明）
        if CompanionAssets.available.count > 1 {
            total += 12 + 88                         // 頭像列：72＋圈 8＋上下 8
        }
        if settings.usesPrompter {
            total += 12 + 40                         // 只剩兩種擺法的說明，兩行
        }
        total += 12 + 140 * 2 + 12                   // 擺法兩列
        return total
    }

    var body: some View {
        ScrollView {
            ModePicker { dismiss() }
                .padding(20)
                .padding(.top, 8)
        }
        .presentationDetents([.height(height), .large])
        .presentationDragIndicator(.visible)
    }
}

/// 看多少字、有沒有人聽、看不看自己，三件事分開選。
/// 只放在主畫面的「看多少字」選單裡，設定頁不再重複一份（QC-0012，回報 #94）。
struct ModePicker: View {
    @EnvironmentObject private var settings: SettingsStore
    var onPick: () -> Void = {}

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    /// 有字的時候字要貼著鏡頭，聆聽者只能墊在字後面，只有這兩種擺得下（規則在 PreviewStack.layout）。
    private static func worksWithPrompter(_ layout: CompanionLayout) -> Bool {
        layout == .fullCall || layout == .alignFirst
    }

    /// 畫面上實際生效的擺法。選了用不了的那幾種，有字時會被當成視訊通話。
    /// 只改顯示，不改存的值：切回「不看」時原本的選擇還在。
    private var effectiveLayout: CompanionLayout {
        let chosen: CompanionLayout = settings.companionLayout
        guard settings.usesPrompter else { return chosen }
        return Self.worksWithPrompter(chosen) ? chosen : .fullCall
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ForEach(PromptAmount.allCases) { amount in
                    amountButton(amount)
                }
            }
            SwitchCard(title: "有人聽", systemImage: "person.wave.2.fill", isOn: $settings.hasListener,
                       detail: "鏡頭旁邊多一位聆聽者，像對著真人講")
            SwitchCard(title: "不看自己", systemImage: "eye.slash.fill", isOn: $settings.hideSelf,
                       detail: "開錄後自己的畫面淡掉，不會一直盯著自己。臉跑出畫面會淡回來提醒你")
            if settings.hasListener {
                listenerOptions
            }
        }
    }

    @ViewBuilder
    private var listenerOptions: some View {
        // 原本只在設定頁，設定頁的模式區拿掉後搬到這裡。
        SwitchCard(title: "即時反應", systemImage: "face.smiling", isOn: $settings.instantReaction,
                   detail: "聆聽者跟著你的停頓和音量點頭、抬眉")
        if CompanionAssets.available.count > 1 {
            PersonPicker()
        }
        if settings.usesPrompter {
            Text("有字的時候字要貼著鏡頭，聆聽者只能墊在字後面，所以只有這兩種")
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(CompanionLayout.allCases) { layout in
                layoutButton(layout)
            }
        }
    }

    private func amountButton(_ amount: PromptAmount) -> some View {
        let selected: Bool = settings.promptAmount == amount
        return Button {
            settings.promptAmount = amount
        } label: {
            VStack(spacing: 8) {
                Image(systemName: amount.symbol)
                Text(amount.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .font(.title3.weight(.semibold))
            .modifier(ModeCard(selected: selected, height: 80))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func layoutButton(_ layout: CompanionLayout) -> some View {
        let usable: Bool = !settings.usesPrompter || Self.worksWithPrompter(layout)
        // 選取框畫在實際生效的那顆，不畫在變灰、按不了的那顆上。
        let selected: Bool = effectiveLayout == layout
        let hint: String = usable ? "" : "有字的時候字要貼著鏡頭，只能用視訊通話或對位再開講"
        return Button {
            settings.companionLayout = layout
            onPick()
        } label: {
            VStack(spacing: 10) {
                LayoutThumb(layout: layout, selected: selected)
                Text(layout.label)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .modifier(ModeCard(selected: selected, height: 140))
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .opacity(usable ? 1 : 0.35)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(hint)
    }
}

/// 大顆的開關，一整條都能按。Toggle 只有右邊那一小塊會切，所以外面包一顆按鈕。
/// 標題底下可以放一行到兩行小字，說這個開關是幹嘛的（回報 #90）。
private struct SwitchCard: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool
    var detail: String? = nil

    /// 沒有說明的高度。
    static let plainHeight: CGFloat = 60
    /// 有兩行說明的高度：標題一行約 25、空隙 4、說明兩行約 40，上下各留 12。
    /// ModeSheet 估高度也用這個。
    static let detailHeight: CGFloat = 96

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            card
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(title, isOn: $isOn)
                .accessibilityHint(detail ?? "")
        }
    }

    private var card: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.white)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.6))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(Theme.accent)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, detail == nil ? 0 : 12)
        .frame(maxWidth: .infinity, minHeight: detail == nil ? Self.plainHeight : Self.detailHeight)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
    }
}

extension PromptAmount {
    /// 選單和主畫面用的圖示。
    var symbol: String {
        switch self {
        case .full: return "text.alignleft"
        case .outline: return "list.bullet"
        case .none: return "text.badge.xmark"
        }
    }
}

/// 聆聽者的頭像橫排。只換人，不關選單，可以一個一個比。
private struct PersonPicker: View {
    @EnvironmentObject private var settings: SettingsStore

    private let side: CGFloat = 72

    var body: some View {
        HStack(spacing: 16) {
            ForEach(CompanionAssets.available) { person in
                personButton(person)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func personButton(_ person: CompanionPerson) -> some View {
        let selected = CompanionAssets.resolve(settings.companionPerson) == person
        return Button {
            settings.companionPerson = person
        } label: {
            face(person)
                .frame(width: side, height: side)
                .clipShape(Circle())
                .padding(4)
                .overlay {
                    Circle()
                        .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 3)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(person.accessibilityName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 定格圖放大到臉，眼睛在圓的中間。裁法和圓形頭像的擺法一樣。
    private func face(_ person: CompanionPerson) -> some View {
        let height = side * 2.6
        return ZStack(alignment: .top) {
            Theme.accent.opacity(0.4)
            if let image = CompanionAssets.thumbnail(person) {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: height * 9 / 16, height: height)
                    .offset(y: side / 2 - height * 0.21)
            }
        }
        .frame(width: side, height: side, alignment: .top)
    }
}

/// 大顆選項的外觀。模式和構圖線的選單共用。
struct ModeCard: ViewModifier {
    let selected: Bool
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .foregroundStyle(selected ? Color.black : Color.white)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(selected ? Theme.accent : Color.white.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// 擺法的小示意圖：灰的是自己，另一個顏色是聆聽者，橢圓是頭。
private struct LayoutThumb: View {
    let layout: CompanionLayout
    let selected: Bool

    private let w: CGFloat = 45
    private let h: CGFloat = 80

    private var me: Color { selected ? Color.black.opacity(0.35) : Color.white.opacity(0.28) }
    private var head: Color { selected ? Color.white : Color.white.opacity(0.85) }
    private var her: Color { selected ? Color.black.opacity(0.75) : Theme.accent }

    var body: some View {
        ZStack(alignment: .top) {
            switch layout {
            case .circle:
                selfBox(w, h)
                Circle().fill(her).frame(width: 16, height: 16).padding(.top, 3)
            case .topCard:
                selfBox(w, h)
                box(14, 24, 3).padding(.top, 3)
            case .fullCall:
                box(w, h, 5)
                selfBox(14, 25).offset(x: 13, y: 50)
            case .eyeStrip:
                selfBox(w, h)
                box(30, 10, 4).padding(.top, 3)
            case .fullFrame:
                VStack(spacing: 2) {
                    box(28, 27, 3)
                    selfBox(28, 50)
                }
            case .alignFirst:
                selfBox(w, h)
                box(14, 25, 3).offset(x: 13, y: 50)
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(head)
                    .offset(x: 13, y: 57)
            }
        }
        .frame(width: w, height: h, alignment: .top)
        .accessibilityHidden(true)
    }

    private func box(_ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(her)
            .frame(width: width, height: height)
    }

    private func selfBox(_ width: CGFloat, _ height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(layout == .fullCall ? Color.black.opacity(0.6) : me)
            .frame(width: width, height: height)
            .overlay {
                Ellipse()
                    .fill(head)
                    .frame(width: width * 0.36, height: width * 0.52)
                    .offset(y: -height * 0.08)
            }
    }
}
