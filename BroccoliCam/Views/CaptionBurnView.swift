import SwiftUI
import UIKit

/// 燒錄中與燒完的全畫面。蓋在校對頁上面，不是另一張彈出頁，才不會和別的視窗打架。
struct CaptionBurnView: View {
    @ObservedObject var model: CaptionEditorModel
    let onShare: () -> Void
    let onShowSRT: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
            content
                .padding(.horizontal, 24)
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private var content: some View {
        switch model.burn {
        case .none:
            EmptyView()
        case .running(let fraction):
            running(fraction)
        case .hot(let canLower):
            hot(canLower)
        case .finished:
            finished
        case .failed(let message):
            failed(message)
        }
    }

    private func running(_ fraction: Double) -> some View {
        VStack(spacing: 22) {
            CaptionProgressRing(fraction: fraction)
            Text("正在燒字幕")
                .font(.headline)
                .foregroundStyle(.white)
            CaptionWideButton(title: "取消", prominent: false) { model.cancelBurn() }
                .frame(maxWidth: 220)
        }
    }

    private func hot(_ canLower: Bool) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "thermometer.high")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text("手機太燙，先停下來了")
                .font(.headline)
                .foregroundStyle(.white)
            if canLower {
                CaptionWideButton(title: "改 1080p 繼續", prominent: true) { model.continueAt1080() }
            }
            CaptionWideButton(title: "照樣燒", prominent: !canLower) { model.keepBurning() }
            CaptionWideButton(title: "取消", prominent: false) { model.cancelBurn() }
        }
    }

    private var finished: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(Theme.good)
            Text("燒好了")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            photoStatus
                .padding(.bottom, 10)
            CaptionWideButton(title: "分享", icon: "square.and.arrow.up", prominent: true, action: onShare)
            originalButton
            CaptionWideButton(title: "看 SRT", icon: "doc.text", prominent: false, action: onShowSRT)
            CaptionWideButton(title: "完成", prominent: false) { model.dismissBurn() }
        }
    }

    @ViewBuilder
    private var photoStatus: some View {
        switch model.burnPhoto {
        case .idle, .saving:
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("正在存到照片")
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.8))
        case .saved:
            Label("字幕版已存到照片", systemImage: "photo")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
        case .failed(let message):
            VStack(spacing: 4) {
                photoProblem("沒有存到照片：\(message)")
                CaptionTextButton(title: "再存一次") { model.saveBurnedToPhotos() }
            }
        case .denied:
            VStack(spacing: 4) {
                photoProblem("沒有照片權限，字幕版還沒存到照片")
                HStack(spacing: 8) {
                    CaptionTextButton(title: "前往設定", action: openSettings)
                    CaptionTextButton(title: "再存一次") { model.saveBurnedToPhotos() }
                }
            }
        }
    }

    private func photoProblem(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.yellow)
            .multilineTextAlignment(.center)
    }

    private var originalButton: some View {
        CaptionWideButton(title: originalTitle, icon: "film", prominent: false,
                          busy: model.originalPhoto == .saving) {
            model.saveOriginal()
        }
        .disabled(model.originalPhoto == .saving || model.originalPhoto == .saved)
    }

    private var originalTitle: String {
        switch model.originalPhoto {
        case .saved: return "原片已存"
        case .failed: return "原片沒存成功，再試一次"
        case .denied: return "沒有照片權限，再試一次"
        default: return "存原片"
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text("沒有燒成功")
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            CaptionWideButton(title: "再燒一次", prominent: true) { model.startBurn() }
            CaptionWideButton(title: "回去校對", prominent: false) { model.dismissBurn() }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// 一圈進度，中間是百分比。
struct CaptionProgressRing: View {
    let fraction: Double

    private var percent: Int {
        Int((min(1, max(0, fraction)) * 100).rounded())
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 8)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0.01, fraction))))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(percent)%")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .frame(width: 120, height: 120)
        .animation(.linear(duration: 0.2), value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("進度")
        .accessibilityValue("\(percent)%")
    }
}

/// 整排寬的大按鈕。
struct CaptionWideButton: View {
    let title: String
    var icon: String?
    let prominent: Bool
    var busy = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().tint(prominent ? .black : .white)
                } else if let icon {
                    Image(systemName: icon)
                }
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .font(.headline)
            .foregroundStyle(prominent ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(prominent ? Theme.accent : Color.white.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 只有字的按鈕，點擊範圍一樣夠大。
struct CaptionTextButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
