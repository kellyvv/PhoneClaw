import SwiftUI

// MARK: - OrbBackgroundView
//
// 复刻 audio-orb 的 backdrop-shader.ts：
//   - 深紫黑 radial 渐变（中心 #050407 → 边缘 #0E0C12）
//   - TimelineView 每帧生成 fract(sin(...)) 胶片噪点（opacity 0.035）

struct OrbBackgroundView: View {

    var body: some View {
        ZStack {
            // ── Radial 渐变（对应 backdrop fragment shader 的 mix(from, to, d)） ──
            // from = vec3(3)/255 ≈ #030303；to = vec3(16,12,20)/2550 ≈ #060408
            // 实际视觉上中心略深紫，边缘更深，与截图吻合
            RadialGradient(
                colors: [
                    Color(red: 3/255,  green: 3/255,  blue: 5/255),   // centre ≈ #030305
                    Color(red: 14/255, green: 10/255, blue: 18/255),  // edge   ≈ #0E0A12
                ],
                center: .center,
                startRadius: 0,
                endRadius: 420
            )
            .ignoresSafeArea()

            // ── 胶片噪点（对应 backdrop shader 的 fract(sin(dot(vUv, ...)) * 43758)） ──
            TimelineView(.animation) { context in
                let seed = context.date.timeIntervalSinceReferenceDate
                GrainOverlay(seed: seed)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Grain 噪点层

private struct GrainOverlay: View {
    let seed: Double

    var body: some View {
        Canvas { ctx, size in
            // 用伪随机散点模拟 GLSL fract-sin 噪点
            // 密度 ~2000 点，opacity 0.035，视觉上轻微颗粒感
            let count = 2000
            let s = UInt64(bitPattern: Int64(seed * 1000)) &+ 1
            var rng = LehmerRNG(seed: s)

            for _ in 0..<count {
                let x = CGFloat(rng.next()) * size.width
                let y = CGFloat(rng.next()) * size.height
                let r = 0.6 + CGFloat(rng.next()) * 0.4
                ctx.fill(
                    Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r*2, height: r*2)),
                    with: .color(.white.opacity(0.035 + 0.02 * Double(rng.next())))
                )
            }
        }
    }
}

// MARK: - 极简整数 LCG（不依赖 Foundation，零分配）

private struct LehmerRNG {
    var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 1 : seed }

    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let v = UInt32(state >> 33)
        return Double(v) / Double(UInt32.max)
    }
}
