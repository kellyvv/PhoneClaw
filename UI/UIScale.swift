import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - UIScale
//
// 设备屏宽分档 + 关键 UI spec 集中管理。
//
// 设计理念(per design 讨论):
//   大屏(iPhone 17 Pro Max 等 6.9" 系)不应等比放大组件 — 那是 Android 适配味。
//   高级感来自 "更多空气 + 更克制 + 更孤独", 不是 "更大组件 + 更满"。
//   所以这里:
//     - 组件 (胶囊/chip/字号) 只微增 (54→56, 40→42)
//     - 真正放大的是 空气 (Orb 留白 / 区块间距 / 底部 safe area breathing)
//     - Orb 占屏比反而 变小 (48% → 44-45%)
//
// 阈值 420pt 区分:
//   < 420:  iPhone Pro 及小屏 (16 Pro = 402pt)
//   >= 420: Pro Max / Plus 等大屏 (16 Pro Max = 440pt)

enum UIScale {

    /// 当前是否大屏 (Pro Max / Plus 系).
    static var isLargeScreen: Bool {
        #if canImport(UIKit)
        return UIScreen.main.bounds.width >= 420
        #else
        return false  // macOS CLI / 测试: 永远走标准 spec
        #endif
    }

    /// 当前屏幕宽度 (pt). 用于按比例计算 orb 等元素大小.
    static var screenWidth: CGFloat {
        #if canImport(UIKit)
        return UIScreen.main.bounds.width
        #else
        return 402  // 默认 iPhone 16 Pro 宽
        #endif
    }

    // MARK: - Input Pill Spec

    /// 胶囊总高度 (chip + 上下 padding).
    static var pillHeight: CGFloat { isLargeScreen ? 56 : 54 }

    /// 屏幕到胶囊的水平边距.
    static var pillHorizontalMargin: CGFloat { isLargeScreen ? 20 : 16 }

    /// 胶囊阴影 blur 半径.
    static var pillShadowBlur: CGFloat { isLargeScreen ? 18 : 16 }

    /// chip (+ 按钮 / waveform 按钮) 直径.
    /// 36pt — 点击区够大,视觉重量克制. Apple Music nav chip 同档.
    /// "点击区域大 / 视觉 icon 小" = 空气感 = 高级感.
    static var chipDiameter: CGFloat { isLargeScreen ? 38 : 36 }

    /// plus icon 字号. 跟 chip ratio 50% — 留呼吸空间.
    static var chipIconSize: CGFloat { 18 }

    /// waveform icon 字号 — 比 plus 小 1pt.
    /// 因为 waveform 视觉密度高(三条波),同 pt 看着比 plus 更"吵".
    /// 这个 icon 应该几乎隐身, 真正主角是 orb.
    static var waveformIconSize: CGFloat { 17 }

    /// waveform / keyboard icon 的 opacity — 让它"浮在空气里",不抢戏.
    static var waveformIconOpacity: Double { 0.68 }

    /// 右上 gear icon 字号.
    static var gearIconSize: CGFloat { 18 }

    /// 右上 gear icon opacity — 跟整体克制气质对齐.
    static var gearIconOpacity: Double { 0.72 }

    /// 左上 chip 外圈直径.
    /// 28pt — 比底部 chip 更小, 因为它是"状态痕迹"不是按钮.
    static var topStatusChipDiameter: CGFloat { 28 }

    /// 左上 chip 内点直径.
    static var topStatusChipDotSize: CGFloat { 6 }

    /// 左上 chip 背景透明度 — 不像按钮, 像"悬浮状态痕迹".
    static var topStatusChipBgOpacity: Double { 0.6 }

    /// chip 到胶囊内壁的距离.
    static var chipInnerMargin: CGFloat { 12 }

    /// chip 跟中间 textfield 的间距.
    static var chipTextSpacing: CGFloat { isLargeScreen ? 18 : 16 }

    /// 输入文字字号.
    static var pillTextSize: CGFloat { 16 }

    /// 输入框空态示例字号. 比真实输入更轻一点, 避免示例抢主视觉。
    static var pillPlaceholderTextSize: CGFloat { 15 }

    // MARK: - Welcome Screen Spec

    /// 品牌签名 (BrandMarkView) 占屏宽比例 — 极小, 是"签字" 不是 "印章".
    /// 大屏反而 略缩, 留更多空气.
    static var orbWidthRatio: CGFloat { isLargeScreen ? 0.20 : 0.22 }

    /// 品牌签名视觉直径. (名字保留 orbSize 是为了减少调用点改动 —
    /// 历史 PorcelainOrbView 已被 BrandMarkView 替换.)
    static var orbSize: CGFloat { screenWidth * orbWidthRatio }

    /// 顶部固定留白 (topBar 下方 → 签名开始) — 让签名落到屏幕 ~ 42-45%
    /// 高度, 而不是被 topBar 推得太低. 签名小, 视觉重心可以更靠中央.
    static var topToOrbGap: CGFloat { isLargeScreen ? 230 : 200 }

    /// 顶部 chrome 视觉高度. topBar 内部是 28pt 状态点 + 上下 10pt padding.
    static var topChromeHeight: CGFloat { topStatusChipDiameter + 20 }

    /// 品牌签名从安全区顶部开始的固定偏移, 保持旧版 topBar + topToOrbGap 的位置.
    static var welcomeBrandTopOffset: CGFloat { topChromeHeight + topToOrbGap }

    /// 输入框到屏幕底部 (home indicator 之上) 的间距.
    static var inputBarBottomGap: CGFloat { isLargeScreen ? 18 : 14 }
}
