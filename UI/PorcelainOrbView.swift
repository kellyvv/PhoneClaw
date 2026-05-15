import SwiftUI

// MARK: - BrandMarkView
//
// 主屏中央的"品牌签名"——直接渲染 designer 提供的爪痕 asset (brand_mark.imageset).
//
// 实现历史 (注释保留, 避免后人重蹈覆辙):
//   先后尝试过 3D 瓷釉球 (太拟物)、扁平 SwiftUI Path 爪痕 (画不出味道, 像断的 WiFi).
//   最终结论: 品牌 mark 走 raster asset, SwiftUI 只负责尺寸 + 极弱呼吸. 见 memory
//   "feedback_dont_handdraw_brand.md".
//
// 资源: Assets.xcassets/brand_mark.imageset (1024×1024 RGBA, 透明背景, 金铜原色)
struct BrandMarkView: View {
    var size: CGFloat = 90

    @State private var breathing = false

    var body: some View {
        Image("brand_mark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .scaleEffect(breathing ? 1.008 : 1.0)
            .onAppear {
                // 极缓极弱呼吸 — 4.5s 周期, ±0.8% scale, 几乎察觉不到.
                // 只为不让签名"完全静止" 而显死板.
                withAnimation(.easeInOut(duration: 4.5).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
    }
}

#Preview("BrandMark") {
    ZStack {
        Color(red: 248/255, green: 245/255, blue: 239/255)
            .ignoresSafeArea()
        BrandMarkView()
    }
}
