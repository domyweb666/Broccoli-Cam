import Foundation

/// 畫面優化的參數。滑桿數值直接存，0 就是不動。
struct LookParams: Codable, Equatable {
    /// 曝光補償（EV）-2…2。調的是相機本身，其他都是每一格畫面上的處理。
    var exposure: Double = 0
    /// 色溫 -100…100，正的偏暖
    var temperature: Double = 0
    /// 色調 -100…100，正的偏紅、負的偏綠
    var tint: Double = 0
    /// 亮部 -100…100，負的把亮的地方壓下來
    var highlights: Double = 0
    /// 暗部 -100…100，正的把暗的地方提亮
    var shadows: Double = 0
    /// 對比 -100…100
    var contrast: Double = 0
    /// 自然飽和度 -100…100
    var vibrance: Double = 0
    /// 降噪 0…100
    var denoise: Double = 0
    /// 銳利 0…100
    var sharpen: Double = 0
    /// 柔膚 0…100，一鍵優化不會動它
    var smooth: Double = 0

    static let neutral = LookParams()

    /// 每一格畫面都不用處理（曝光補償不算，那是相機做的）。
    var needsNoPixelWork: Bool {
        var copy = self
        copy.exposure = 0
        return copy == .neutral
    }
}

/// 一鍵優化的結果。
struct LookResult {
    var params: LookParams
    /// 有沒有看到臉。沒有就用整張畫面判斷。
    var hasFace: Bool
    /// 曝光調到底，臉還是太暗，要請使用者靠近光源。
    var stillTooDark: Bool
}
