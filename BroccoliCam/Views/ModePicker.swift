import SwiftUI
import UIKit

/// 主畫面按「看多少字」跳出來的選單。選聆聽者擺法才關掉，其他的可以一次調好幾樣。
struct ModeSheet: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    private var height: CGFloat {
        guard settings.hasListener else { return 330 }
        return CompanionAssets.available.count > 1 ? 760 : 670
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

/// 看多少字、有沒有人聽、看不看自己，三件事分開選。設定頁和選單共用。
struct ModePicker: View {
    @EnvironmentObject private var settings: SettingsStore
    var onPick: () -> Void = {}

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ForEach(PromptAmount.allCases) { amount in
                    amountButton(amount)
                }
            }
            SwitchCard(title: "有人聽", systemImage: "person.wave.2.fill", isOn: $settings.hasListener)
            SwitchCard(title: "不看自己", systemImage: "eye.slash.fill", isOn: $settings.hideSelf)
            if settings.hasListener {
                listenerOptions
            }
        }
    }

    @ViewBuilder
    private var listenerOptions: some View {
        if CompanionAssets.available.count > 1 {
            PersonPicker()
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
        let selected: Bool = settings.companionLayout == layout
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
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 大顆的開關，一整條都能按。
private struct SwitchCard: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))
        }
        .tint(Theme.accent)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 60)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
