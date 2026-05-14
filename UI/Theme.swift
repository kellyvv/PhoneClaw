import SwiftUI

// MARK: - PhoneClaw 设计系统(瓷器风,v2)
// 跨平台共享:macOS + iOS
//
// v2 配色锚点:
//   - 主背景 champagne #F8F5EF (跟 master 设计稿一致)
//   - 强调色 amber copper #C77A3F (跟 App Icon 金爪同色系,brand 主载体)
//   - 状态点 muted gold #C39660 (避开 iOS 通知红语义)
//   - 文字深灰系 (light theme 下保持高可读性)
//
// dark theme 的旧值 (#1A1915 / #D4A574 等) 已迁移走 — Live mode 内部
// 用 dark 风格的 view 自己持有局部颜色, 不再走 Theme.bg。

struct Theme {
    // MARK: 背景
    static let bg = Color(hex: "F8F5EF")            // champagne 米白
    static let bgElevated = Color(hex: "FFFFFF")     // 卡片/输入框 纯白
    static let bgHover = Color(hex: "EAE5DB")        // chip 内底 / pressed (在白胶囊上有 ~8% 对比, 清晰可见)

    // MARK: 文字
    static let textPrimary = Color(hex: "2C2C2C")    // 主文字 深灰
    static let textSecondary = Color(hex: "6B6B6B")  // 次要中灰
    static let textTertiary = Color(hex: "B0B0B0")   // 辅助/placeholder 浅灰

    // MARK: 强调色 (brand)
    static let accent = Color(hex: "C77A3F")         // amber copper — brand 主色
    static let accentSubtle = Color(hex: "C77A3F").opacity(0.12)
    static let accentMuted = Color(hex: "C39660")    // muted gold — 状态点专用,避开通知红
    static let accentGreen = Color(hex: "7CB87C")    // 成功/在线 (保留, 旧逻辑可能在用)

    // MARK: 用户气泡 (浅底 + 深字 → 改成 brand 色底 + 白字)
    static let userBubble = Color(hex: "C77A3F")
    static let userText = Color(hex: "FFFFFF")

    // MARK: 边框
    static let border = Color(hex: "E0DED7")        // 浅描线
    static let borderSubtle = Color(hex: "F0EBE2")  // 更浅

    // MARK: 响应式间距
    #if os(macOS)
    static let chatPadH: CGFloat = 24
    static let chatSpacing: CGFloat = 24
    static let inputPadH: CGFloat = 20
    static let bubbleMinSpacer: CGFloat = 80
    static let aiMinSpacer: CGFloat = 40
    #else
    static let chatPadH: CGFloat = 16
    static let chatSpacing: CGFloat = 20
    static let inputPadH: CGFloat = 16
    static let bubbleMinSpacer: CGFloat = 60
    static let aiMinSpacer: CGFloat = 24
    #endif
}

// MARK: - Hex Color（跨平台）

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255, opacity: Double(a)/255)
    }
}
