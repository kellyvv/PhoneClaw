import SwiftUI

@main
struct PhoneClawApp: App {
    init() {
        // HealthKit 可行性探针 — 分支 experiment/healthkit-probe 专用, 不会进 develop/main。
        // 看 Xcode console 的 [HealthKitProbe] 日志判断 Free Apple ID 能否使用 HealthKit。
        HealthKitProbe.run()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
