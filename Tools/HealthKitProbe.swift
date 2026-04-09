import Foundation
import HealthKit

// MARK: - HealthKit Probe (feasibility test)
//
// 这是一个一次性探针, 目的是验证 Free Apple ID 签发的 PhoneClaw 能否
// 通过 Xcode 本地 Run 成功使用 HealthKit entitlement。
//
// 验证清单 (看 Xcode console 的 [HealthKitProbe] 日志):
//   1. 编译阶段能否通过 (只要能看到这条文件里的 import, build 没挂, 这关过)
//   2. 运行时 HKHealthStore.isHealthDataAvailable() 是否返回 true
//   3. 授权对话框能否正常弹出 (第一次 Run 到设备时)
//   4. 授权通过后能否真的拿到一个具体的数字 (今日步数)
//
// 三种可能的结果:
//   A. build 失败 → entitlement 被 Apple 硬拒, Free Apple ID 走不通, Health Skill 封死
//   B. build 过, 运行时 isHealthDataAvailable() 返回 false → 静默剥离, 也封死
//   C. build 过, 弹授权框, 授权后能读到步数 → **开放!** Health Skill 可做
//
// 如果本探针在你的 Free Apple ID + 真机上走通了 (结果 C), 那就把这段代码
// 留着做基础, 开始认真写 HealthSkill。如果走不通, 整个分支封存。

@MainActor
enum HealthKitProbe {

    private static let store = HKHealthStore()

    /// 启动时调用一次, 打印 HealthKit 可用性 + 授权状态, 然后尝试读今日步数。
    static func run() {
        print("[HealthKitProbe] ---- start ----")

        // Step 1: 设备是否支持 HealthKit (iPad 不支持, iPhone/Watch 支持)
        let available = HKHealthStore.isHealthDataAvailable()
        print("[HealthKitProbe] isHealthDataAvailable = \(available)")
        guard available else {
            print("[HealthKitProbe] 设备不支持 HealthKit, stop")
            return
        }

        // Step 2: 请求读步数权限 (一次性弹系统授权对话框)
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            print("[HealthKitProbe] stepCount type 不存在 — 不应该发生")
            return
        }

        Task {
            do {
                try await store.requestAuthorization(toShare: [], read: [stepType])
                print("[HealthKitProbe] requestAuthorization 返回 (不代表用户同意, 只代表对话框流程结束)")

                // Step 3: 尝试查询今日步数
                let stepsToday = await fetchTodaySteps(quantityType: stepType)
                if let stepsToday {
                    print("[HealthKitProbe] ✅ 今日步数: \(Int(stepsToday))")
                    print("[HealthKitProbe] ---- PASS: HealthKit 完全可用 ----")
                } else {
                    print("[HealthKitProbe] ⚠️ 查询返回 nil — 可能用户拒绝授权, 或今天没数据")
                }
            } catch {
                print("[HealthKitProbe] ❌ authorization 失败: \(error.localizedDescription)")
                print("[HealthKitProbe] ---- FAIL: 授权这一关挂了 ----")
            }
        }
    }

    /// 查询今日 (本地 0 点到现在) 的步数总和
    private static func fetchTodaySteps(quantityType: HKQuantityType) async -> Double? {
        await withCheckedContinuation { continuation in
            let calendar = Calendar.current
            let now = Date()
            let start = calendar.startOfDay(for: now)
            let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)

            let query = HKStatisticsQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, error in
                if let error {
                    print("[HealthKitProbe] query error: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                let sum = stats?.sumQuantity()?.doubleValue(for: .count())
                continuation.resume(returning: sum)
            }

            Self.store.execute(query)
        }
    }
}
