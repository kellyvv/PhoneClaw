import SwiftUI

// MARK: - PhoneClaw 设计系统（Claude 风格）
// 跨平台共享：macOS + iOS

struct Theme {
    // MARK: 背景
    static let bg = Color(hex: "1A1915")            // 深暖棕
    static let bgElevated = Color(hex: "24221D")     // 卡片/输入框
    static let bgHover = Color(hex: "2E2B25")        // hover / pressed

    // MARK: 文字
    static let textPrimary = Color(hex: "ECECEA")    // 主文字 暖白
    static let textSecondary = Color(hex: "A8A8A0")  // 次要
    static let textTertiary = Color(hex: "6B6B63")   // 辅助/placeholder

    // MARK: 强调色
    static let accent = Color(hex: "D4A574")         // 沙金/赭石
    static let accentSubtle = Color(hex: "D4A574").opacity(0.12)
    static let accentGreen = Color(hex: "7CB87C")    // 成功/在线

    // MARK: 用户气泡
    static let userBubble = Color(hex: "D4A574")
    static let userText = Color(hex: "1A1915")

    // MARK: 边框
    static let border = Color(hex: "3A3732")
    static let borderSubtle = Color(hex: "2E2B25")

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
