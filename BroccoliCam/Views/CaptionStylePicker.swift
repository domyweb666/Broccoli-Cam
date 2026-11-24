import SwiftUI

/// 字幕樣式：款式、字級、位置。設定的預設樣式和校對頁共用。
struct CaptionStylePicker: View {
    @Binding var style: CaptionStyle

    var body: some View {
        VStack(spacing: 12) {
            lookRow
            sizeRow
            positionRow
        }
    }

    private var lookRow: some View {
        HStack(spacing: 10) {
            ForEach(CaptionStyle.Look.allCases) { look in
                lookButton(look)
            }
        }
    }

    private func lookButton(_ look: CaptionStyle.Look) -> some View {
        let selected = style.look == look
        return Button {
            style.look = look
        } label: {
            VStack(spacing: 8) {
                CaptionLookSample(look: look)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Color(white: 0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 3)
                    }
                Text(look.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selected ? Theme.accent : Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(look.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var sizeRow: some View {
        HStack(spacing: 10) {
            ForEach(CaptionStyle.Size.allCases) { size in
                CaptionChip(title: size.label, selected: style.size == size) {
                    style.size = size
                }
                .accessibilityLabel("字級\(size.label)")
            }
        }
    }

    private var positionRow: some View {
        HStack(spacing: 10) {
            ForEach(CaptionStyle.Position.allCases) { position in
                CaptionChip(title: position.label, selected: style.position == position) {
                    style.position = position
                }
                .accessibilityLabel("位置\(position.label)")
            }
        }
    }
}

/// 一顆可以選的小方塊。
struct CaptionChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(selected ? Color.black : Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(selected ? Theme.accent : Color.white.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 樣式的小樣本。只是示意，真正的樣子看校對頁的影片。
private struct CaptionLookSample: View {
    let look: CaptionStyle.Look

    var body: some View {
        switch look {
        case .outline:
            outlined(Color.white)
        case .box:
            word(Color.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        case .yellow:
            outlined(Color(red: 1, green: 0.87, blue: 0.2))
        }
    }

    private func word(_ color: Color) -> some View {
        Text("字幕")
            .font(.title3.weight(.bold))
            .foregroundStyle(color)
    }

    private func outlined(_ color: Color) -> some View {
        ZStack {
            ForEach(0..<8, id: \.self) { step in
                word(.black)
                    .offset(outlineOffset(step))
            }
            word(color)
        }
    }

    private func outlineOffset(_ step: Int) -> CGSize {
        let angle: Double = Double(step) * Double.pi / 4
        return CGSize(width: cos(angle) * 1.6, height: sin(angle) * 1.6)
    }
}
