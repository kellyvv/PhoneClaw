import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
    static let bg = Color(light: "F8F5EF", dark: "15130F")
    static let bgElevated = Color(light: "FFFFFF", dark: "211E19")
    static let bgHover = Color(light: "EAE5DB", dark: "2D2821")

    // MARK: 文字
    static let textPrimary = Color(light: "3A342E", dark: "EFE9DF")
    static let textSecondary = Color(light: "70675E", dark: "B9AFA3")
    static let textTertiary = Color(light: "B8ADA0", dark: "756D63")
    static let assistantText = Color(light: "4A433B", dark: "BDB3A6")

    // MARK: 强调色 (brand)
    static let accent = Color(light: "C77A3F", dark: "D59B63")
    static let accentSubtle = Color(light: "C77A3F", dark: "D59B63").opacity(0.16)
    static let accentMuted = Color(light: "C39660", dark: "C99B68")
    static let accentGreen = Color(light: "7CB87C", dark: "8FD08F")

    // MARK: 对话
    static let userBubble = Color(light: "C49660", dark: "C49660").opacity(0.14)
    static let userBubbleStroke = Color(light: "C49660", dark: "D0A16D").opacity(0.18)
    static let userText = Color(light: "6A5848", dark: "E6D3BC")
    static let quietAction = Color(light: "8D8275", dark: "8E8378").opacity(0.5)

    // MARK: 边框
    static let border = Color(light: "E0DED7", dark: "39332A")
    static let borderSubtle = Color(light: "F0EBE2", dark: "2B261F")

    // MARK: 响应式间距
    #if os(macOS)
    static let chatPadH: CGFloat = 24
    static let chatSpacing: CGFloat = 28
    static let inputPadH: CGFloat = 20
    static let bubbleMinSpacer: CGFloat = 80
    static let aiMinSpacer: CGFloat = 40
    #else
    static let chatPadH: CGFloat = 16
    static let chatSpacing: CGFloat = 24
    static let inputPadH: CGFloat = 16
    static let bubbleMinSpacer: CGFloat = 60
    static let aiMinSpacer: CGFloat = 24
    #endif
}

// MARK: - Hex Color（跨平台）

extension Color {
    init(light: String, dark: String) {
        #if canImport(UIKit)
        self.init(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #elseif canImport(AppKit)
        self.init(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
        #else
        self.init(hex: light)
        #endif
    }

    init(hex: String) {
        let (a, r, g, b) = rgbaComponents(from: hex)
        self.init(.sRGB, red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255, opacity: Double(a)/255)
    }
}

private func rgbaComponents(from hexString: String) -> (UInt64, UInt64, UInt64, UInt64) {
    let hex = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&int)
    switch hex.count {
    case 6:
        return (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
    case 8:
        return (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
    default:
        return (255, 0, 0, 0)
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(hex: String) {
        let (a, r, g, b) = rgbaComponents(from: hex)
        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}
#elseif canImport(AppKit)
private extension NSColor {
    convenience init(hex: String) {
        let (a, r, g, b) = rgbaComponents(from: hex)
        self.init(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}
#endif
