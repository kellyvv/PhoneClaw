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
    static var chipDiameter: CGFloat { isLargeScreen ? 42 : 40 }

    /// chip icon 字号 (SF Symbols).
    static var chipIconSize: CGFloat { 22 }  // 两档相同,符合 "只放大空气" 原则

    /// chip 到胶囊内壁的距离.
    static var chipInnerMargin: CGFloat { 12 }

    /// chip 跟中间 textfield 的间距.
    static var chipTextSpacing: CGFloat { isLargeScreen ? 18 : 16 }

    /// placeholder / 输入文字字号.
    static var pillTextSize: CGFloat { 17 }

    // MARK: - Welcome Screen Spec

    /// Orb 占屏宽比例 — 大屏反而 缩 (留更多空气).
    static var orbWidthRatio: CGFloat { isLargeScreen ? 0.44 : 0.48 }

    /// Orb 视觉直径.
    static var orbSize: CGFloat { screenWidth * orbWidthRatio }

    /// Orb 跟下方 "进入 LIVE" 文字的距离.
    static var orbToEntryTextGap: CGFloat { isLargeScreen ? 64 : 48 }

    /// "进入 LIVE" 跟底部输入框的间距 (由 Spacer 主导, 这只是 minLength 兜底).
    static var entryToInputMinGap: CGFloat { isLargeScreen ? 120 : 96 }

    /// 输入框到屏幕底部 (home indicator 之上) 的间距.
    static var inputBarBottomGap: CGFloat { isLargeScreen ? 18 : 14 }
}
