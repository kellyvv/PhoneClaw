import SwiftUI

// MARK: - PorcelainOrbView
//
// 主屏空状态的瓷器球视觉。
//
// 设计语言:跟 App Icon 的金爪同色系(brand color #C77A3F),
// 但形态从"利爪划痕"软化为"釉中流金"——同一物质语言不同姿态。
//
// 实现选择:Image asset + SwiftUI 微动画(方案 D)。
// 主屏不需要响应音频,只是 idle 邀请性视觉,PNG + breathing scale 够了。
// Live mode 内的动态 orb 仍走 Three.js (OrbSceneView),那里能跟着 audio 顶点变形。
//
// 球本体已包含瓷釉裂纹 + 金铜流痕 + 下方涟漪,SwiftUI 只负责呼吸 + 微旋转。

struct PorcelainOrbView: View {
    /// 球的视觉直径(包含下方涟漪)。默认 280pt 对应设计稿主屏中央比例。
    var size: CGFloat = 280

    @State private var breathing = false
    @State private var rotation: Double = -2

    var body: some View {
        Image("orb_porcelain")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .scaleEffect(breathing ? 1.02 : 1.0)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                // 呼吸: 3s 一个周期, scale 1.0 ↔ 1.02 — 轻微到几乎察觉不到,
                // 暗示"陶瓷之内有生命"。
                withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                    breathing = true
                }
                // 微旋转: 12s 一个周期, -2° ↔ +2° — 表面流金有缓慢"漂移"感。
                withAnimation(.easeInOut(duration: 12.0).repeatForever(autoreverses: true)) {
                    rotation = 2
                }
            }
    }
}

#Preview {
    ZStack {
        Color(red: 248/255, green: 245/255, blue: 239/255)  // champagne #F8F5EF
            .ignoresSafeArea()
        PorcelainOrbView()
    }
}
