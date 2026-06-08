import Foundation
#if canImport(HealthKit)
import HealthKit

// MARK: - Health Tools
//
// 读取 HealthKit 里用户的健康数据。只读,不写。
//
// HealthKit 是 iOS-only framework. macOS 系统物理上没有 HealthKit, 这整个文件主体
// 用 #if canImport(HealthKit) 守护. macOS CLI 走文件末尾的 #else 分支 — 但
// PhoneClawCLI/Sources/PhoneClawCLI/MockToolHandlers.swift 里有 fixture-based
// HealthTools, ToolRegistry 注册到那个版本. CLI scenario 仍能跑, 用 fixture 数据.
// (这不是 design 选择, 是 Mac 没真实健康数据的物理事实.)
//
// 权限策略: 每次调用时检查授权, 首次会弹系统对话框。用户拒绝后直接返回
// failurePayload, 由 skill body 里的指令让模型给用户一个友好解释。

enum HealthTools {

    /// HealthKit store 单例 — Apple 官方建议整个 app 只创建一个
    private static let store = HKHealthStore()
    static let readAuthorizationRequestedDefaultsKey = "PhoneClawHealthReadAuthorizationRequested"

    static var hasRequestedReadAuthorization: Bool {
        UserDefaults.standard.bool(forKey: readAuthorizationRequestedDefaultsKey)
    }

    private static let healthDataContract = PhoneGroundToolContract(
        evidenceTypes: [.health],
        answerContract: .groundedDataSummary,
        freshness: .userScopedData,
        supportsRecovery: false
    )

    private static var defaultReadTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()

        [
            HKQuantityTypeIdentifier.stepCount,
            .distanceWalkingRunning,
            .activeEnergyBurned,
            .restingHeartRate,
            .heartRate,
            .heartRateVariabilitySDNN,
            .bodyMass,
        ].compactMap {
            HKQuantityType.quantityType(forIdentifier: $0)
        }.forEach { types.insert($0) }

        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleepType)
        }
        types.insert(HKWorkoutType.workoutType())

        return types
    }

    private enum HealthQueryOutcome<Value> {
        case success(Value)
        case noData
        case failure(String)
    }

    static func register(into registry: ToolRegistry) {

        registerStepsToday(into: registry)
        registerStepsYesterday(into: registry)
        registerStepsRange(into: registry)
        registerDistanceToday(into: registry)
        registerActiveEnergyToday(into: registry)
        registerHeartRateResting(into: registry)
        registerHeartRateRecent(into: registry)
        registerHeartRateVariability(into: registry)
        registerWeightLatest(into: registry)
        registerSleepLastNight(into: registry)
        registerSleepWeek(into: registry)
        registerWorkoutRecent(into: registry)
        registerReportRange(into: registry)
        registerReportWeek(into: registry)
    }

    // ── health-steps-today ──
    private static func registerStepsToday(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-steps-today",
            description: tr("读取用户今日步数 (从本地 0 点到当前时间的累计步数)。仅读取,不修改。", "Read the user's step count for today (cumulative steps from local midnight to now). Read-only, no modifications.", "ユーザーの今日の歩数を読み取る (現地の0時から現在までの累計歩数)。読み取りのみ、変更しません。"),
            parameters: tr("无", "None", "なし"),
            phoneGroundContract: healthDataContract,
            isParameterless: true,
            skipFollowUp: true,
            execute: { args in
                try await stepsTodayCanonical(args).detail
            },
            executeCanonical: { args in
                try await stepsTodayCanonical(args)
            }
        ))
    }

    // ── health-steps-yesterday ──
    private static func registerStepsYesterday(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-steps-yesterday",
            description: tr("读取用户昨日步数 (昨天本地 0 点到 23:59:59 的累计步数)。仅读取,不修改。", "Read the user's step count for yesterday (cumulative steps from yesterday local midnight to 23:59:59). Read-only, no modifications.", "ユーザーの昨日の歩数を読み取る (昨日の現地0時から23:59:59までの累計歩数)。読み取りのみ、変更しません。"),
            parameters: tr("无", "None", "なし"),
            phoneGroundContract: healthDataContract,
            isParameterless: true,
            skipFollowUp: true,
            execute: { args in
                try await stepsYesterdayCanonical(args).detail
            },
            executeCanonical: { args in
                try await stepsYesterdayCanonical(args)
            }
        ))
    }

    // ── health-sleep-last-night ──
    private static func registerSleepLastNight(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-sleep-last-night",
            description: tr("读取用户昨晚的睡眠数据 (最近 24 小时内的睡眠记录)。返回总时长和分阶段明细。", "Read the user's sleep data for last night (sleep records within the past 24 hours). Returns total duration and per-stage breakdown.", "ユーザーの昨夜の睡眠データを読み取る (直近24時間以内の睡眠記録)。合計時間と各ステージの内訳を返します。"),
            parameters: tr("无", "None", "なし"),
            phoneGroundContract: healthDataContract,
            isParameterless: true,
            skipFollowUp: true,
            execute: { args in
                try await sleepLastNightCanonical(args).detail
            },
            executeCanonical: { args in
                try await sleepLastNightCanonical(args)
            }
        ))
    }

    // ── health-sleep-week ──
    private static func registerSleepWeek(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-sleep-week",
            description: tr("读取用户最近 7 天的睡眠汇总 (每晚总时长 + 7 天平均)。", "Read a sleep summary for the user's past 7 days (total duration per night + 7-day average).", "ユーザーの直近7日間の睡眠サマリーを読み取る (毎晩の合計時間 + 7日間の平均)。"),
            parameters: tr("无", "None", "なし"),
            phoneGroundContract: healthDataContract,
            isParameterless: true,
            skipFollowUp: true,
            execute: { args in
                try await sleepWeekCanonical(args).detail
            },
            executeCanonical: { args in
                try await sleepWeekCanonical(args)
            }
        ))
    }

    // ── health-workout-recent ──
    private static func registerWorkoutRecent(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-workout-recent",
            description: tr("读取用户最近 7 天的运动记录 (类型、时长、消耗)。", "Read the user's workout records for the past 7 days (type, duration, calories burned).", "ユーザーの直近7日間のワークアウト記録を読み取る (種類、時間、消費カロリー)。"),
            parameters: tr("无", "None", "なし"),
            phoneGroundContract: healthDataContract,
            isParameterless: true,
            skipFollowUp: true,
            execute: { args in
                try await workoutRecentCanonical(args).detail
            },
            executeCanonical: { args in
                try await workoutRecentCanonical(args)
            }
        ))
    }

    // ── health-report-week ──
    private static func registerReportWeek(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-report-week",
            description: tr(
                "读取用户最近 7 天的综合健康数据并生成本地周报：步数、距离、活动能量、睡眠、运动、心率、HRV、体重。仅读取。",
                "Read the user's past 7 days of Health data and generate a local weekly report: steps, distance, active energy, sleep, workouts, heart rate, HRV, and weight. Read-only.",
                "ユーザーの直近7日間の総合的なヘルスデータを読み取り、ローカルで週次レポートを生成する：歩数、距離、アクティブエネルギー、睡眠、ワークアウト、心拍数、HRV、体重。読み取りのみ。"
            ),
            parameters: tr("无", "None", "なし"),
            phoneGroundContract: healthDataContract,
            isParameterless: true,
            skipFollowUp: true,
            execute: { args in
                try await healthReportWeekCanonical(args).detail
            },
            executeCanonical: { args in
                try await healthReportWeekCanonical(args)
            }
        ))
    }

    // ── health-report-range ──
    private static func registerReportRange(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-report-range",
            description: tr(
                "读取用户指定天数内的综合健康数据并生成本地报告：步数、距离、活动能量、睡眠、运动、心率、HRV、体重。仅读取。",
                "Read the user's Health data for a requested day range and generate a local report: steps, distance, active energy, sleep, workouts, heart rate, HRV, and weight. Read-only.",
                "ユーザーが指定した日数分の総合的なヘルスデータを読み取り、ローカルでレポートを生成する：歩数、距離、アクティブエネルギー、睡眠、ワークアウト、心拍数、HRV、体重。読み取りのみ。"
            ),
            parameters: tr(
                "{\"days\":{\"type\":\"integer\",\"description\":\"查询最近几天的健康数据，1 到 90 天。例如一周=7，两周=14，一个月=30。\",\"required\":true}}",
                "{\"days\":{\"type\":\"integer\",\"description\":\"Number of recent days to query, 1 to 90. For example: one week=7, two weeks=14, one month=30.\",\"required\":true}}",
                "{\"days\":{\"type\":\"integer\",\"description\":\"直近何日分のヘルスデータを照会するか、1～90日。例：1週間=7、2週間=14、1ヶ月=30。\",\"required\":true}}"
            ),
            phoneGroundContract: healthDataContract,
            requiredParameters: ["days"],
            isParameterless: false,
            skipFollowUp: true,
            execute: { args in
                try await healthReportRangeCanonical(args).detail
            },
            executeCanonical: { args in
                try await healthReportRangeCanonical(args)
            }
        ))
    }

    // ── health-distance-today ──
    private static func registerDistanceToday(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-distance-today",
            description: tr("读取用户今日步行+跑步距离 (从本地 0 点到当前时间, 单位 km)。仅读取。", "Read the user's walking+running distance for today (from local midnight to now, in km). Read-only.", "ユーザーの今日のウォーキング+ランニングの距離を読み取る (現地0時から現在まで、単位km)。読み取りのみ。"),
            parameters: tr("无", "None", "なし"),
            phoneGroundContract: healthDataContract,
            isParameterless: true,
            skipFollowUp: true,
            execute: { args in
                try await distanceTodayCanonical(args).detail
            },
            executeCanonical: { args in
                try await distanceTodayCanonical(args)
            }
        ))
    }

    // ── health-active-energy-today ──
    private static func registerActiveEnergyToday(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-active-energy-today",
            description: tr("读取用户今日活动消耗的卡路里 (从本地 0 点到当前时间)。仅读取。", "Read the user's active calories burned today (from local midnight to now). Read-only.", "ユーザーの今日のアクティブ消費カロリーを読み取る (現地0時から現在まで)。読み取りのみ。"),
            parameters: tr("无", "None", "なし"),
            phoneGroundContract: healthDataContract,
            isParameterless: true,
            skipFollowUp: true,
            execute: { args in
                try await activeEnergyTodayCanonical(args).detail
            },
            executeCanonical: { args in
                try await activeEnergyTodayCanonical(args)
            }
        ))
    }

    // ── health-heart-rate-resting ──
    private static func registerHeartRateResting(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-heart-rate-resting",
            description: tr("读取用户最近的静息心率 (最近 24 小时平均, 单位 BPM)。仅读取。", "Read the user's recent resting heart rate (average over the past 24 hours, in BPM). Read-only.", "ユーザーの最近の安静時心拍数を読み取る (直近24時間の平均、単位BPM)。読み取りのみ。"),
            parameters: tr("无", "None", "なし"),
            phoneGroundContract: healthDataContract,
            isParameterless: true,
            skipFollowUp: true,
            execute: { args in
                try await heartRateRestingCanonical(args).detail
            },
            executeCanonical: { args in
                try await heartRateRestingCanonical(args)
            }
        ))
    }

    // ── health-heart-rate-recent ──
    private static func registerHeartRateRecent(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-heart-rate-recent",
            description: tr("读取用户最近一条心率记录 (单位 BPM)。仅读取。", "Read the user's most recent heart rate sample (in BPM). Read-only.", "ユーザーの最新の心拍数記録を読み取る (単位BPM)。読み取りのみ。"),
            parameters: tr("无", "None", "なし"),
            phoneGroundContract: healthDataContract,
            isParameterless: true,
            skipFollowUp: true,
            execute: { args in
                try await heartRateRecentCanonical(args).detail
            },
            executeCanonical: { args in
                try await heartRateRecentCanonical(args)
            }
        ))
    }

    // ── health-heart-rate-variability ──
    private static func registerHeartRateVariability(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-heart-rate-variability",
            description: tr("读取用户最近一条心率变异性 HRV SDNN 记录 (单位 ms)。仅读取。", "Read the user's most recent heart rate variability (HRV SDNN) sample (in ms). Read-only.", "ユーザーの最新の心拍変動 HRV SDNN 記録を読み取る (単位ms)。読み取りのみ。"),
            parameters: tr("无", "None", "なし"),
            phoneGroundContract: healthDataContract,
            isParameterless: true,
            skipFollowUp: true,
            execute: { args in
                try await heartRateVariabilityCanonical(args).detail
            },
            executeCanonical: { args in
                try await heartRateVariabilityCanonical(args)
            }
        ))
    }

    // ── health-weight-latest ──
    private static func registerWeightLatest(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-weight-latest",
            description: tr("读取用户最近一条体重记录 (单位 kg)。仅读取。", "Read the user's most recent body weight sample (in kg). Read-only.", "ユーザーの最新の体重記録を読み取る (単位kg)。読み取りのみ。"),
            parameters: tr("无", "None", "なし"),
            phoneGroundContract: healthDataContract,
            isParameterless: true,
            skipFollowUp: true,
            execute: { args in
                try await weightLatestCanonical(args).detail
            },
            executeCanonical: { args in
                try await weightLatestCanonical(args)
            }
        ))
    }

    // ── health-steps-range ──
    private static func registerStepsRange(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-steps-range",
            description: tr("读取最近 N 天的每日步数。返回每日列表 + 总数 + 日均。", "Read daily step counts for the past N days. Returns a daily list + total + daily average.", "直近N日間の日別歩数を読み取る。日別リスト + 合計 + 日平均を返します。"),
            parameters: tr("{\"days\":{\"type\":\"integer\",\"description\":\"查询天数 (1-30)\",\"required\":true}}", "{\"days\":{\"type\":\"integer\",\"description\":\"Number of days to query (1-30)\",\"required\":true}}", "{\"days\":{\"type\":\"integer\",\"description\":\"照会する日数 (1-30)\",\"required\":true}}"),
            phoneGroundContract: healthDataContract,
            requiredParameters: ["days"],
            isParameterless: false,
            skipFollowUp: true,
            execute: { args in
                try await stepsRangeCanonical(args).detail
            },
            executeCanonical: { args in
                try await stepsRangeCanonical(args)
            }
        ))
    }

    // 约定:
    // - 查询为空/没有可用样本 = success=true
    // - 授权失败 / 参数缺失 / Health 查询失败 = success=false
    // - HealthKit 底层问题在本文件内归一成 canonical failure, 不向上层抛 Swift error

    private static func stepsTodayCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        let cal = Calendar.current
        let now = Date()
        let start = cal.startOfDay(for: now)
        switch await fetchQuantitySumResult(
            identifier: .stepCount,
            unit: .count(),
            start: start,
            end: now
        ) {
        case .success(let steps):
            let rounded = Int(steps.rounded())
            let summary = singleDayStepsSummary(periodZh: "今天", periodEn: "Today", steps: rounded)
            return healthSuccess(
                summary: summary,
                extras: ["steps": rounded, "unit": tr("步", "steps", "歩"), "date": isoDateString(now)]
            )
        case .noData:
            return stepsNoDataResult(periodDescription: tr("今天", "today", "今日"), extras: ["date": isoDateString(now)])
        case .failure(let error):
            return stepsFailureResult(error)
        }
    }

    private static func stepsYesterdayCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
        switch await fetchQuantitySumResult(
            identifier: .stepCount,
            unit: .count(),
            start: yesterdayStart,
            end: todayStart
        ) {
        case .success(let steps):
            let rounded = Int(steps.rounded())
            let summary = singleDayStepsSummary(periodZh: "昨天", periodEn: "Yesterday", steps: rounded)
            return healthSuccess(
                summary: summary,
                extras: ["steps": rounded, "unit": tr("步", "steps", "歩"), "date": isoDateString(yesterdayStart)]
            )
        case .noData:
            return stepsNoDataResult(periodDescription: tr("昨天", "yesterday", "昨日"), extras: ["date": isoDateString(yesterdayStart)])
        case .failure(let error):
            return stepsFailureResult(error)
        }
    }

    private static func sleepLastNightCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        let now = Date()
        let start = Calendar.current.date(byAdding: .hour, value: -24, to: now)!
        switch await fetchSleepAnalysisResult(start: start, end: now) {
        case .success(let stages):
            let totalMin = totalAsleepMinutes(in: stages)
            guard totalMin > 0 else {
                return healthEmpty(
                    summary: tr("最近 24 小时没有可用的睡眠时长记录", "No usable sleep-duration record in the past 24 hours", "直近24時間に利用可能な睡眠時間の記録がありません"),
                    extras: ["total_minutes": 0, "stages": stages.map { ["stage": $0.stage, "minutes": $0.minutes] as [String: Any] }]
                )
            }
            let hours = totalMin / 60
            let mins = totalMin % 60
            let stageList = stages.map { ["stage": $0.stage, "minutes": $0.minutes] as [String: Any] }
            let summary = tr("昨晚睡了 \(hours) 小时 \(mins) 分钟。", "You slept \(hours) h \(mins) min last night.", "昨夜は \(hours) 時間 \(mins) 分眠りました。")
            return healthSuccess(
                summary: summary,
                extras: ["total_minutes": totalMin, "hours": hours, "minutes": mins, "stages": stageList]
            )
        case .noData:
            return healthEmpty(
                summary: tr("最近 24 小时没有睡眠记录", "No sleep records in the past 24 hours", "直近24時間に睡眠記録がありません"),
                extras: ["total_minutes": 0, "stages": [] as [Any]]
            )
        case .failure(let error):
            return healthFailure(
                summary: tr("无法读取睡眠数据。请确认健康权限已开启。", "Unable to read sleep data. Please make sure Health permission is enabled.", "睡眠データを読み取れません。ヘルスケアの権限が有効になっているか確認してください。"),
                detail: error,
                errorCode: "HEALTH_SLEEP_READ_FAILED"
            )
        }
    }

    private static func sleepWeekCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        let cal = Calendar.current
        let now = Date()
        let weekAgo = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now))!
        switch await fetchSleepAnalysisResult(start: weekAgo, end: now) {
        case .success(let stages):
            let totalMin = totalAsleepMinutes(in: stages)
            guard totalMin > 0 else {
                return healthEmpty(
                    summary: tr("最近 7 天没有可用的睡眠时长记录", "No usable sleep-duration records in the past 7 days", "直近7日間に利用可能な睡眠時間の記録がありません"),
                    extras: ["nights": [] as [Any], "avg_minutes": 0]
                )
            }
            let avgMin = totalMin / 7
            let avgH = avgMin / 60
            let avgM = avgMin % 60
            let summary = tr("最近 7 天日均睡眠 \(avgH) 小时 \(avgM) 分钟。", "Your 7-day sleep average is \(avgH) h \(avgM) min.", "直近7日間の平均睡眠は1日あたり \(avgH) 時間 \(avgM) 分です。")
            return healthSuccess(
                summary: summary,
                extras: ["total_minutes": totalMin, "avg_minutes": avgMin, "days": 7]
            )
        case .noData:
            return healthEmpty(
                summary: tr("最近 7 天没有睡眠记录", "No sleep records in the past 7 days", "直近7日間に睡眠記録がありません"),
                extras: ["nights": [] as [Any], "avg_minutes": 0]
            )
        case .failure(let error):
            return healthFailure(
                summary: tr("无法读取睡眠数据。请确认健康权限已开启。", "Unable to read sleep data. Please make sure Health permission is enabled.", "睡眠データを読み取れません。ヘルスケアの権限が有効になっているか確認してください。"),
                detail: error,
                errorCode: "HEALTH_SLEEP_READ_FAILED"
            )
        }
    }

    private static func workoutRecentCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        let cal = Calendar.current
        let now = Date()
        let weekAgo = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now))!
        switch await fetchWorkoutsResult(start: weekAgo, end: now) {
        case .success(let workouts):
            let list = workouts.map { w in
                ["type": w.type, "duration_min": w.durationMin, "calories": w.calories, "date": w.date] as [String: Any]
            }
            let totalMin = workouts.reduce(0) { $0 + $1.durationMin }
            let summary = tr("最近 7 天有 \(workouts.count) 次运动，共 \(totalMin) 分钟。", "\(workouts.count) workouts in the past 7 days, \(totalMin) min total.", "直近7日間にワークアウトが \(workouts.count) 回、合計 \(totalMin) 分です。")
            return healthSuccess(
                summary: summary,
                extras: ["workouts": list, "count": workouts.count, "total_minutes": totalMin]
            )
        case .noData:
            return healthEmpty(
                summary: tr("最近 7 天没有运动记录", "No workout records in the past 7 days", "直近7日間にワークアウト記録がありません"),
                extras: ["workouts": [] as [Any], "count": 0]
            )
        case .failure(let error):
            return healthFailure(
                summary: tr("无法读取运动数据。请确认健康权限已开启。", "Unable to read workout data. Please make sure Health permission is enabled.", "ワークアウトデータを読み取れません。ヘルスケアの権限が有効になっているか確認してください。"),
                detail: error,
                errorCode: "HEALTH_WORKOUT_READ_FAILED"
            )
        }
    }

    private static func distanceTodayCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        let cal = Calendar.current
        let now = Date()
        let start = cal.startOfDay(for: now)
        switch await fetchQuantitySumResult(
            identifier: .distanceWalkingRunning,
            unit: .meter(),
            start: start,
            end: now
        ) {
        case .success(let meters):
            let km = (meters / 1000 * 100).rounded() / 100
            let summary = tr("今天步行约 \(km) 公里。", "You walked about \(km) km today.", "今日は約 \(km) キロ歩きました。")
            return healthSuccess(
                summary: summary,
                extras: ["distance_km": km, "distance_m": Int(meters.rounded()), "date": isoDateString(now)]
            )
        case .noData:
            return healthEmpty(
                summary: tr("今天还没有可用的步行距离数据。", "No walking distance data available yet today.", "今日はまだ利用可能なウォーキング距離のデータがありません。"),
                extras: ["distance_km": 0, "distance_m": 0, "date": isoDateString(now)]
            )
        case .failure(let error):
            return healthFailure(
                summary: tr("无法读取距离数据。请确认健康权限已开启。", "Unable to read distance data. Please make sure Health permission is enabled.", "距離データを読み取れません。ヘルスケアの権限が有効になっているか確認してください。"),
                detail: error,
                errorCode: "HEALTH_DISTANCE_READ_FAILED"
            )
        }
    }

    private static func activeEnergyTodayCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        let cal = Calendar.current
        let now = Date()
        let start = cal.startOfDay(for: now)
        switch await fetchQuantitySumResult(
            identifier: .activeEnergyBurned,
            unit: .kilocalorie(),
            start: start,
            end: now
        ) {
        case .success(let kcal):
            let rounded = Int(kcal.rounded())
            let summary = tr("今天活动消耗约 \(rounded) 千卡。", "You burned about \(rounded) active kcal today.", "今日のアクティブ消費は約 \(rounded) キロカロリーです。")
            return healthSuccess(
                summary: summary,
                extras: ["calories": rounded, "unit": "kcal", "date": isoDateString(now)]
            )
        case .noData:
            return healthEmpty(
                summary: tr(
                    "今天还没有活动能量记录。健康里可能没有生成这项数据；如果只想看活动量，可以问今天走了多少步。",
                    "No active energy record is available today. Health may not have generated this metric; ask for today's steps if you want activity level.",
                    "今日はまだアクティブエネルギーの記録がありません。ヘルスケアでこの指標が生成されていない可能性があります。活動量を知りたい場合は、今日の歩数を聞いてみてください。"
                ),
                extras: ["calories": 0, "unit": "kcal", "date": isoDateString(now)]
            )
        case .failure(let error):
            return healthFailure(
                summary: tr("无法读取活动能量数据：\(error)", "Unable to read active energy data: \(error)", "アクティブエネルギーデータを読み取れません：\(error)"),
                detail: error,
                errorCode: "HEALTH_ACTIVE_ENERGY_READ_FAILED"
            )
        }
    }

    private static func heartRateRestingCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        switch await fetchLatestQuantityResult(
            identifier: .restingHeartRate,
            unit: HKUnit.count().unitDivided(by: .minute())
        ) {
        case .success(let bpm):
            let rounded = Int(bpm.rounded())
            let summary = tr("静息心率是 \(rounded) BPM。", "Your resting heart rate is \(rounded) BPM.", "安静時心拍数は \(rounded) BPM です。")
            return healthSuccess(
                summary: summary,
                extras: ["bpm": rounded, "unit": "BPM"]
            )
        case .noData:
            return healthEmpty(
                summary: tr("最近 24 小时还没有可用的静息心率数据。", "No resting heart rate data available in the past 24 hours.", "直近24時間に利用可能な安静時心拍数のデータがありません。"),
                extras: ["bpm": 0, "unit": "BPM"]
            )
        case .failure(let error):
            return healthFailure(
                summary: tr("无法读取心率数据。请确认健康权限已开启。", "Unable to read heart rate data. Please make sure Health permission is enabled.", "心拍数データを読み取れません。ヘルスケアの権限が有効になっているか確認してください。"),
                detail: error,
                errorCode: "HEALTH_HEART_RATE_READ_FAILED"
            )
        }
    }

    private static func heartRateRecentCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        switch await fetchMostRecentQuantityResult(
            identifier: .heartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            daysBack: 7
        ) {
        case .success(let sample):
            let rounded = Int(sample.value.rounded())
            let summary = tr("最近一次心率是 \(rounded) BPM。", "Your most recent heart rate is \(rounded) BPM.", "直近の心拍数は \(rounded) BPM です。")
            return healthSuccess(
                summary: summary,
                extras: ["bpm": rounded, "unit": "BPM", "date": isoDateString(sample.date)]
            )
        case .noData:
            return healthEmpty(
                summary: tr("最近 7 天还没有可用的心率数据。", "No heart rate data available in the past 7 days.", "直近7日間に利用可能な心拍数のデータがありません。"),
                extras: ["bpm": 0, "unit": "BPM"]
            )
        case .failure(let error):
            return healthFailure(
                summary: tr("无法读取心率数据。请确认健康权限已开启。", "Unable to read heart rate data. Please make sure Health permission is enabled.", "心拍数データを読み取れません。ヘルスケアの権限が有効になっているか確認してください。"),
                detail: error,
                errorCode: "HEALTH_HEART_RATE_READ_FAILED"
            )
        }
    }

    private static func heartRateVariabilityCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        switch await fetchMostRecentQuantityResult(
            identifier: .heartRateVariabilitySDNN,
            unit: HKUnit.secondUnit(with: .milli),
            daysBack: 30
        ) {
        case .success(let sample):
            let rounded = Int(sample.value.rounded())
            let summary = tr("最近一次心率变异性是 \(rounded) ms。", "Your most recent HRV is \(rounded) ms.", "直近の心拍変動は \(rounded) ms です。")
            return healthSuccess(
                summary: summary,
                extras: ["hrv_ms": rounded, "unit": "ms", "date": isoDateString(sample.date)]
            )
        case .noData:
            return healthEmpty(
                summary: tr("最近 30 天还没有可用的心率变异性数据。", "No heart rate variability data available in the past 30 days.", "直近30日間に利用可能な心拍変動のデータがありません。"),
                extras: ["hrv_ms": 0, "unit": "ms"]
            )
        case .failure(let error):
            return healthFailure(
                summary: tr("无法读取心率变异性数据。请确认健康权限已开启。", "Unable to read heart rate variability data. Please make sure Health permission is enabled.", "心拍変動データを読み取れません。ヘルスケアの権限が有効になっているか確認してください。"),
                detail: error,
                errorCode: "HEALTH_HRV_READ_FAILED"
            )
        }
    }

    private static func weightLatestCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        switch await fetchMostRecentQuantityResult(
            identifier: .bodyMass,
            unit: HKUnit.gramUnit(with: .kilo),
            daysBack: 365
        ) {
        case .success(let sample):
            let kg = (sample.value * 10).rounded() / 10
            let summary = tr("最近一次体重记录是 \(kg) kg。", "Your most recent weight record is \(kg) kg.", "直近の体重記録は \(kg) kg です。")
            return healthSuccess(
                summary: summary,
                extras: ["weight_kg": kg, "unit": "kg", "date": isoDateString(sample.date)]
            )
        case .noData:
            return healthEmpty(
                summary: tr("最近一年还没有可用的体重记录。", "No body weight data available in the past year.", "直近1年間に利用可能な体重の記録がありません。"),
                extras: ["weight_kg": 0, "unit": "kg"]
            )
        case .failure(let error):
            return healthFailure(
                summary: tr("无法读取体重数据。请确认健康权限已开启。", "Unable to read body weight data. Please make sure Health permission is enabled.", "体重データを読み取れません。ヘルスケアの権限が有効になっているか確認してください。"),
                detail: error,
                errorCode: "HEALTH_WEIGHT_READ_FAILED"
            )
        }
    }

    private static func healthReportWeekCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        try await healthReportRangeCanonical(["days": 7])
    }

    private static func healthReportRangeCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        let rawDays = (args["days"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedDays = (args["days"] as? Int) ?? rawDays.flatMap(Int.init) ?? 7
        let days = max(1, min(90, requestedDays))

        if let err = await requestAllReadAuthorization() {
            return healthFailure(
                summary: tr("无法生成健康报告。请确认健康权限已开启。", "Unable to generate the Health report. Please make sure Health permissions are enabled.", "ヘルスレポートを生成できません。ヘルスケアの権限が有効になっているか確認してください。"),
                detail: err,
                errorCode: "HEALTH_REPORT_READ_FAILED"
            )
        }

        let cal = Calendar.current
        let now = Date()
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: now))!

        let steps = await fetchDailyQuantitySumsResult(identifier: .stepCount, unit: .count(), days: days)
        let distance = await fetchDailyQuantitySumsResult(identifier: .distanceWalkingRunning, unit: .meter(), days: days)
        let activeEnergy = await fetchDailyQuantitySumsResult(identifier: .activeEnergyBurned, unit: .kilocalorie(), days: days)
        let sleep = await fetchSleepAnalysisResult(start: start, end: now)
        let workouts = await fetchWorkoutsResult(start: start, end: now)
        let restingHeartRate = await fetchLatestQuantityResult(
            identifier: .restingHeartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            hoursBack: 24 * days
        )
        let recentHeartRate = await fetchMostRecentQuantityResult(
            identifier: .heartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            daysBack: days
        )
        let hrv = await fetchMostRecentQuantityResult(
            identifier: .heartRateVariabilitySDNN,
            unit: HKUnit.secondUnit(with: .milli),
            daysBack: days
        )
        let weight = await fetchMostRecentQuantityResult(
            identifier: .bodyMass,
            unit: HKUnit.gramUnit(with: .kilo),
            daysBack: days
        )

        var lines: [String] = []
        var unavailable: [String] = []
        var extras: [String: Any] = ["days": days, "date": isoDateString(now)]
        var stepAverage: Int?
        var sleepAverage: Int?
        var workoutCount: Int?

        switch steps {
        case .success(let entries):
            let total = entries.reduce(0) { $0 + Int($1.value.rounded()) }
            let avg = entries.isEmpty ? 0 : total / entries.count
            stepAverage = avg
            extras["steps_total"] = total
            extras["steps_daily_avg"] = avg
            extras["steps_daily"] = entries.map { ["date": $0.date, "steps": Int($0.value.rounded())] as [String: Any] }
            if let best = entries.max(by: { $0.value < $1.value }) {
                extras["steps_best_day"] = best.date
                extras["steps_best_day_count"] = Int(best.value.rounded())
            }
            lines.append(tr("活动：共 \(total) 步，日均 \(avg) 步。", "Activity: \(total) steps total, \(avg) per day.", "アクティビティ：合計 \(total) 歩、1日平均 \(avg) 歩。"))
        case .noData:
            unavailable.append(tr("步数", "steps", "歩数"))
        case .failure(let error):
            unavailable.append(tr("步数读取失败：\(error)", "steps failed: \(error)", "歩数の読み取りに失敗：\(error)"))
        }

        switch distance {
        case .success(let entries):
            let totalMeters = entries.reduce(0.0) { $0 + $1.value }
            let km = totalMeters / 1000
            extras["distance_km_total"] = roundedOneDecimal(km)
            if km > 0 {
                lines.append(tr("距离：步行+跑步约 \(formatOneDecimal(km)) 公里。", "Distance: about \(formatOneDecimal(km)) km walking+running.", "距離：ウォーキング+ランニング約 \(formatOneDecimal(km)) キロ。"))
            } else {
                unavailable.append(tr("步行距离", "walking distance", "ウォーキング距離"))
            }
        case .noData:
            unavailable.append(tr("步行距离", "walking distance", "ウォーキング距離"))
        case .failure(let error):
            unavailable.append(tr("距离读取失败：\(error)", "distance failed: \(error)", "距離の読み取りに失敗：\(error)"))
        }

        switch activeEnergy {
        case .success(let entries):
            let kcal = Int(entries.reduce(0.0) { $0 + $1.value }.rounded())
            extras["active_energy_kcal_total"] = kcal
            if kcal > 0 {
                lines.append(tr("活动能量：约 \(kcal) 千卡。", "Active energy: about \(kcal) kcal.", "アクティブエネルギー：約 \(kcal) キロカロリー。"))
            } else {
                unavailable.append(tr("活动能量", "active energy", "アクティブエネルギー"))
            }
        case .noData:
            unavailable.append(tr("活动能量", "active energy", "アクティブエネルギー"))
        case .failure(let error):
            unavailable.append(tr("活动能量读取失败：\(error)", "active energy failed: \(error)", "アクティブエネルギーの読み取りに失敗：\(error)"))
        }

        switch sleep {
        case .success(let stages):
            let totalMin = totalAsleepMinutes(in: stages)
            if totalMin > 0 {
                let avg = totalMin / days
                sleepAverage = avg
                extras["sleep_total_minutes"] = totalMin
                extras["sleep_avg_minutes"] = avg
                lines.append(tr("睡眠：日均 \(minutesText(avg))。", "Sleep: \(minutesText(avg)) per day on average.", "睡眠：1日平均 \(minutesText(avg))。"))
            } else {
                unavailable.append(tr("睡眠", "sleep", "睡眠"))
            }
        case .noData:
            unavailable.append(tr("睡眠", "sleep", "睡眠"))
        case .failure(let error):
            unavailable.append(tr("睡眠读取失败：\(error)", "sleep failed: \(error)", "睡眠の読み取りに失敗：\(error)"))
        }

        switch workouts {
        case .success(let records):
            let totalMin = records.reduce(0) { $0 + $1.durationMin }
            workoutCount = records.count
            extras["workouts_count"] = records.count
            extras["workouts_total_minutes"] = totalMin
            extras["workouts"] = records.map {
                ["type": $0.type, "duration_min": $0.durationMin, "calories": $0.calories, "date": $0.date] as [String: Any]
            }
            lines.append(tr("运动：\(records.count) 次，共 \(totalMin) 分钟。", "Workouts: \(records.count) sessions, \(totalMin) min total.", "ワークアウト：\(records.count) 回、合計 \(totalMin) 分。"))
        case .noData:
            workoutCount = 0
            lines.append(tr("运动：最近 \(days) 天没有运动记录。", "Workouts: no workout records in the past \(days) days.", "ワークアウト：直近 \(days) 日間にワークアウト記録がありません。"))
        case .failure(let error):
            unavailable.append(tr("运动读取失败：\(error)", "workouts failed: \(error)", "ワークアウトの読み取りに失敗：\(error)"))
        }

        var heartParts: [String] = []
        switch restingHeartRate {
        case .success(let bpm):
            let rounded = Int(bpm.rounded())
            heartParts.append(tr("静息 \(rounded) BPM", "resting \(rounded) BPM", "安静時 \(rounded) BPM"))
            extras["resting_bpm"] = rounded
        case .failure(let error):
            unavailable.append(tr("静息心率读取失败：\(error)", "resting heart rate failed: \(error)", "安静時心拍数の読み取りに失敗：\(error)"))
        case .noData:
            break
        }
        switch recentHeartRate {
        case .success(let sample):
            let rounded = Int(sample.value.rounded())
            heartParts.append(tr("最近 \(rounded) BPM", "recent \(rounded) BPM", "直近 \(rounded) BPM"))
            extras["recent_bpm"] = rounded
            extras["recent_bpm_date"] = isoDateString(sample.date)
        case .failure(let error):
            unavailable.append(tr("心率读取失败：\(error)", "heart rate failed: \(error)", "心拍数の読み取りに失敗：\(error)"))
        case .noData:
            break
        }
        switch hrv {
        case .success(let sample):
            let rounded = Int(sample.value.rounded())
            heartParts.append("HRV \(rounded) ms")
            extras["hrv_ms"] = rounded
            extras["hrv_date"] = isoDateString(sample.date)
        case .failure(let error):
            unavailable.append(tr("HRV 读取失败：\(error)", "HRV failed: \(error)", "HRVの読み取りに失敗：\(error)"))
        case .noData:
            break
        }
        if !heartParts.isEmpty {
            lines.append(tr("心率：", "Heart: ", "心拍数：") + heartParts.joined(separator: tr("，", ", ", "、")) + "。")
        } else {
            unavailable.append(tr("心率/HRV", "heart rate/HRV", "心拍数/HRV"))
        }

        switch weight {
        case .success(let sample):
            let kg = roundedOneDecimal(sample.value)
            extras["weight_kg"] = kg
            extras["weight_date"] = isoDateString(sample.date)
            lines.append(tr("体重：最近记录 \(formatOneDecimal(kg)) kg。", "Weight: latest record \(formatOneDecimal(kg)) kg.", "体重：直近の記録 \(formatOneDecimal(kg)) kg。"))
        case .failure(let error):
            unavailable.append(tr("体重读取失败：\(error)", "weight failed: \(error)", "体重の読み取りに失敗：\(error)"))
        case .noData:
            unavailable.append(tr("体重", "weight", "体重"))
        }

        if lines.isEmpty {
            return healthEmpty(
                summary: tr("最近 \(days) 天没有可用的健康数据记录。", "No usable Health records are available for the past \(days) days.", "直近 \(days) 日間に利用可能なヘルスデータの記録がありません。"),
                extras: extras
            )
        }

        let advice = healthRangeAdvice(stepAverage: stepAverage, sleepAverage: sleepAverage, workoutCount: workoutCount)
        extras["unavailable"] = unavailable
        extras["advice"] = advice

        let summary: String
        if LanguageService.shared.current.isChinese {
            var reportLines = ["最近 \(days) 天健康报告："]
            reportLines.append(contentsOf: lines.map { "- \($0)" })
            if !unavailable.isEmpty {
                reportLines.append("- 暂无：\(unavailable.joined(separator: "、"))。")
            }
            reportLines.append("- 建议：\(advice)")
            summary = reportLines.joined(separator: "\n")
        } else if LanguageService.shared.current.isJapanese {
            var reportLines = ["直近 \(days) 日間のヘルスレポート："]
            reportLines.append(contentsOf: lines.map { "- \($0)" })
            if !unavailable.isEmpty {
                reportLines.append("- データなし：\(unavailable.joined(separator: "、"))。")
            }
            reportLines.append("- アドバイス：\(advice)")
            summary = reportLines.joined(separator: "\n")
        } else {
            var reportLines = ["Past \(days) days Health report:"]
            reportLines.append(contentsOf: lines.map { "- \($0)" })
            if !unavailable.isEmpty {
                reportLines.append("- Unavailable: \(unavailable.joined(separator: ", ")).")
            }
            reportLines.append("- Suggestion: \(advice)")
            summary = reportLines.joined(separator: "\n")
        }

        return healthSuccess(summary: summary, extras: extras)
    }

    private static func stepsRangeCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        let rawDays = (args["days"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let days = (args["days"] as? Int) ?? rawDays.flatMap(Int.init) else {
            return healthFailure(
                summary: tr("请告诉我查询最近几天，1 到 30 天。", "Please tell me how many days to query, between 1 and 30.", "直近何日分を照会するか教えてください、1～30日。"),
                detail: tr("缺少 days 参数 (1-30 的整数)", "Missing `days` parameter (integer 1-30)", "days パラメータがありません (1-30 の整数)"),
                errorCode: "DAYS_MISSING"
            )
        }
        let clampedDays = max(1, min(30, days))
        switch await fetchDailyQuantitySumsResult(
            identifier: .stepCount,
            unit: .count(),
            days: clampedDays
        ) {
        case .success(let entries):
            let total = entries.reduce(0) { $0 + Int($1.value.rounded()) }
            let avg = entries.isEmpty ? 0 : total / entries.count
            let dailyList = entries.map { ["date": $0.date, "steps": Int($0.value.rounded())] as [String: Any] }
            let summary = stepsRangeSummary(days: clampedDays, total: total, average: avg)
            return healthSuccess(
                summary: summary,
                extras: ["days": clampedDays, "total": total, "daily_avg": avg, "daily": dailyList]
            )
        case .noData:
            return stepsNoDataResult(periodDescription: tr("最近 \(clampedDays) 天", "the past \(clampedDays) days", "直近 \(clampedDays) 日間"), extras: ["days": clampedDays])
        case .failure(let error):
            return stepsFailureResult(error)
        }
    }

    // MARK: - Shared HealthKit Helpers
    //
    // 所有 Health tool 共用的 query 封装。每个 helper 负责一种 HK query 模式,
    // 具体 tool 的 register 闭包只需要组装参数 + 格式化返回值。

    /// 请求读取权限并验证设备支持。
    /// 返回 nil 表示请求成功发起; 这不等价于系统一定会返回读结果。
    static func requestReadAuth(for types: Set<HKObjectType>) async -> String? {
        guard HKHealthStore.isHealthDataAvailable() else {
            return tr("设备不支持 HealthKit", "This device does not support HealthKit", "このデバイスは HealthKit に対応していません")
        }
        do {
            try await store.requestAuthorization(toShare: [], read: defaultReadTypes.union(types))
            UserDefaults.standard.set(true, forKey: readAuthorizationRequestedDefaultsKey)
        } catch {
            return tr("健康数据授权失败: \(error.localizedDescription)", "Health data authorization failed: \(error.localizedDescription)", "ヘルスデータの認可に失敗しました: \(error.localizedDescription)")
        }
        return nil
    }

    static func requestAllReadAuthorization() async -> String? {
        await requestReadAuth(for: defaultReadTypes)
    }

    private static func isHealthNoDataError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == HKError.Code.errorNoData.rawValue {
            return true
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("No data available")
    }

    private static func fetchQuantitySumResult(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async -> HealthQueryOutcome<Double> {
        guard let qType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            return .failure(tr("不支持的数据类型：\(identifier.rawValue)", "Unsupported data type: \(identifier.rawValue)", "サポートされていないデータ型：\(identifier.rawValue)"))
        }
        if let err = await requestReadAuth(for: [qType]) {
            PCLog.error("health_auth_failed", detail: "type=\(identifier.rawValue) error=\(err)")
            return .failure(err)
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<HealthQueryOutcome<Double>, Never>) in
            let predicate = HKQuery.predicateForSamples(
                withStart: start, end: end, options: .strictStartDate
            )
            let query = HKStatisticsQuery(
                quantityType: qType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, error in
                if let error {
                    if isHealthNoDataError(error) {
                        continuation.resume(returning: .noData)
                        return
                    }
                    PCLog.error(
                        "health_quantity_sum_failed",
                        detail: "type=\(identifier.rawValue) error=\(error.localizedDescription)"
                    )
                    continuation.resume(
                        returning: .failure(tr("Health 查询失败：\(error.localizedDescription)", "Health query failed: \(error.localizedDescription)", "ヘルスケアのクエリに失敗：\(error.localizedDescription)"))
                    )
                    return
                }

                guard let sum = stats?.sumQuantity()?.doubleValue(for: unit) else {
                    continuation.resume(returning: .noData)
                    return
                }
                continuation.resume(returning: .success(sum))
            }
            store.execute(query)
        }
    }

    private static func fetchDailyQuantitySumsResult(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        days: Int
    ) async -> HealthQueryOutcome<[(date: String, value: Double)]> {
        guard let qType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            return .failure(tr("不支持的数据类型：\(identifier.rawValue)", "Unsupported data type: \(identifier.rawValue)", "サポートされていないデータ型：\(identifier.rawValue)"))
        }
        if let err = await requestReadAuth(for: [qType]) {
            PCLog.error("health_auth_failed", detail: "type=\(identifier.rawValue) error=\(err)")
            return .failure(err)
        }
        let cal = Calendar.current
        let now = Date()
        let dayCount = max(1, days)
        let endOfToday = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now)!)
        let start = cal.date(byAdding: .day, value: -(dayCount - 1), to: cal.startOfDay(for: now))!
        let interval = DateComponents(day: 1)

        return await withCheckedContinuation { (continuation: CheckedContinuation<HealthQueryOutcome<[(date: String, value: Double)]>, Never>) in
            let predicate = HKQuery.predicateForSamples(
                withStart: start, end: endOfToday, options: .strictStartDate
            )
            let query = HKStatisticsCollectionQuery(
                quantityType: qType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: start,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, results, error in
                if let error {
                    if isHealthNoDataError(error) {
                        continuation.resume(returning: .noData)
                        return
                    }
                    PCLog.error(
                        "health_daily_quantity_failed",
                        detail: "type=\(identifier.rawValue) error=\(error.localizedDescription)"
                    )
                    continuation.resume(
                        returning: .failure(tr("Health 查询失败：\(error.localizedDescription)", "Health query failed: \(error.localizedDescription)", "ヘルスケアのクエリに失敗：\(error.localizedDescription)"))
                    )
                    return
                }
                guard let results else {
                    continuation.resume(returning: .failure(tr("Health 查询没有返回结果", "Health query returned no results", "ヘルスケアのクエリが結果を返しませんでした")))
                    return
                }
                var entries: [(date: String, value: Double)] = []
                results.enumerateStatistics(from: start, to: endOfToday) { stat, _ in
                    let val = stat.sumQuantity()?.doubleValue(for: unit) ?? 0
                    entries.append((date: isoDateString(stat.startDate), value: val))
                }
                continuation.resume(returning: .success(entries))
            }
            store.execute(query)
        }
    }

    /// 查询最新一条离散值 (heart rate 等)。
    /// 用 HKStatisticsQuery + .discreteAverage 取最近区间平均值。
    private static func fetchLatestQuantityResult(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        hoursBack: Int = 24
    ) async -> HealthQueryOutcome<Double> {
        guard let qType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            return .failure(tr("不支持的数据类型：\(identifier.rawValue)", "Unsupported data type: \(identifier.rawValue)", "サポートされていないデータ型：\(identifier.rawValue)"))
        }
        if let err = await requestReadAuth(for: [qType]) {
            PCLog.error("health_auth_failed", detail: "type=\(identifier.rawValue) error=\(err)")
            return .failure(err)
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<HealthQueryOutcome<Double>, Never>) in
            let now = Date()
            let start = Calendar.current.date(byAdding: .hour, value: -hoursBack, to: now)!
            let predicate = HKQuery.predicateForSamples(
                withStart: start, end: now, options: .strictStartDate
            )
            let query = HKStatisticsQuery(
                quantityType: qType,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, stats, error in
                if let error {
                    if isHealthNoDataError(error) {
                        continuation.resume(returning: .noData)
                        return
                    }
                    PCLog.error(
                        "health_latest_quantity_failed",
                        detail: "type=\(identifier.rawValue) error=\(error.localizedDescription)"
                    )
                    continuation.resume(
                        returning: .failure(tr("Health 查询失败：\(error.localizedDescription)", "Health query failed: \(error.localizedDescription)", "ヘルスケアのクエリに失敗：\(error.localizedDescription)"))
                    )
                    return
                }

                guard let avg = stats?.averageQuantity()?.doubleValue(for: unit) else {
                    continuation.resume(returning: .noData)
                    return
                }
                continuation.resume(returning: .success(avg))
            }
            store.execute(query)
        }
    }

    /// 查询最近一条离散数值样本 (heart rate, HRV, weight 等)。
    private static func fetchMostRecentQuantityResult(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        daysBack: Int
    ) async -> HealthQueryOutcome<(value: Double, date: Date)> {
        guard let qType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            return .failure(tr("不支持的数据类型：\(identifier.rawValue)", "Unsupported data type: \(identifier.rawValue)", "サポートされていないデータ型：\(identifier.rawValue)"))
        }
        if let err = await requestReadAuth(for: [qType]) {
            PCLog.error("health_auth_failed", detail: "type=\(identifier.rawValue) error=\(err)")
            return .failure(err)
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<HealthQueryOutcome<(value: Double, date: Date)>, Never>) in
            let now = Date()
            let start = Calendar.current.date(byAdding: .day, value: -daysBack, to: now)!
            let predicate = HKQuery.predicateForSamples(
                withStart: start, end: now, options: .strictStartDate
            )
            let query = HKSampleQuery(
                sampleType: qType,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error {
                    if isHealthNoDataError(error) {
                        continuation.resume(returning: .noData)
                        return
                    }
                    PCLog.error(
                        "health_most_recent_quantity_failed",
                        detail: "type=\(identifier.rawValue) error=\(error.localizedDescription)"
                    )
                    continuation.resume(
                        returning: .failure(tr("Health 查询失败：\(error.localizedDescription)", "Health query failed: \(error.localizedDescription)", "ヘルスケアのクエリに失敗：\(error.localizedDescription)"))
                    )
                    return
                }

                guard let sample = (samples as? [HKQuantitySample])?.first else {
                    continuation.resume(returning: .noData)
                    return
                }
                continuation.resume(returning: .success((sample.quantity.doubleValue(for: unit), sample.startDate)))
            }
            store.execute(query)
        }
    }

    /// 查询睡眠分析数据 (HKCategoryType)。
    /// 返回 [(stage: String, minutes: Int)] 数组。
    private static func fetchSleepAnalysisResult(
        start: Date,
        end: Date
    ) async -> HealthQueryOutcome<[(stage: String, minutes: Int)]> {
        guard let sleepType = HKObjectType.categoryType(
            forIdentifier: .sleepAnalysis
        ) else { return .failure(tr("不支持的数据类型：sleepAnalysis", "Unsupported data type: sleepAnalysis", "サポートされていないデータ型：sleepAnalysis")) }
        if let err = await requestReadAuth(for: [sleepType]) {
            PCLog.error("health_auth_failed", detail: "type=sleepAnalysis error=\(err)")
            return .failure(err)
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<HealthQueryOutcome<[(stage: String, minutes: Int)]>, Never>) in
            let predicate = HKQuery.predicateForSamples(
                withStart: start, end: end, options: .strictStartDate
            )
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error {
                    if isHealthNoDataError(error) {
                        continuation.resume(returning: .noData)
                        return
                    }
                    PCLog.error(
                        "health_sleep_query_failed",
                        detail: "type=sleepAnalysis error=\(error.localizedDescription)"
                    )
                    continuation.resume(
                        returning: .failure(tr("Health 查询失败：\(error.localizedDescription)", "Health query failed: \(error.localizedDescription)", "ヘルスケアのクエリに失敗：\(error.localizedDescription)"))
                    )
                    return
                }

                guard let samples = samples as? [HKCategorySample] else {
                    continuation.resume(returning: .failure(tr("Health 查询没有返回结果", "Health query returned no results", "ヘルスケアのクエリが結果を返しませんでした")))
                    return
                }

                guard !samples.isEmpty else {
                    continuation.resume(returning: .noData)
                    return
                }
                var result: [(stage: String, minutes: Int)] = []
                for s in samples {
                    let mins = Int(s.endDate.timeIntervalSince(s.startDate) / 60)
                    let stage: String
                    if #available(iOS 16.0, *) {
                        switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
                        case .inBed:        stage = "inBed"
                        case .asleepCore:   stage = "core"
                        case .asleepDeep:   stage = "deep"
                        case .asleepREM:    stage = "REM"
                        case .awake:        stage = "awake"
                        default:            stage = "unknown"
                        }
                    } else {
                        switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
                        case .inBed:    stage = "inBed"
                        case .asleep:   stage = "asleep"
                        case .awake:    stage = "awake"
                        default:        stage = "unknown"
                        }
                    }
                    result.append((stage: stage, minutes: mins))
                }
                continuation.resume(returning: .success(result))
            }
            store.execute(query)
        }
    }

    /// 查询最近的运动记录 (HKWorkout)。
    private static func fetchWorkoutsResult(
        start: Date,
        end: Date,
        limit: Int = 20
    ) async -> HealthQueryOutcome<[(type: String, durationMin: Int, calories: Int, date: String)]> {
        let workoutType = HKWorkoutType.workoutType()
        if let err = await requestReadAuth(for: [workoutType]) {
            PCLog.error("health_auth_failed", detail: "type=workout error=\(err)")
            return .failure(err)
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<HealthQueryOutcome<[(type: String, durationMin: Int, calories: Int, date: String)]>, Never>) in
            let predicate = HKQuery.predicateForSamples(
                withStart: start, end: end, options: .strictStartDate
            )
            let query = HKSampleQuery(
                sampleType: workoutType,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error {
                    if isHealthNoDataError(error) {
                        continuation.resume(returning: .noData)
                        return
                    }
                    PCLog.error(
                        "health_workout_query_failed",
                        detail: "type=workout error=\(error.localizedDescription)"
                    )
                    continuation.resume(
                        returning: .failure(tr("Health 查询失败：\(error.localizedDescription)", "Health query failed: \(error.localizedDescription)", "ヘルスケアのクエリに失敗：\(error.localizedDescription)"))
                    )
                    return
                }

                guard let workouts = samples as? [HKWorkout] else {
                    continuation.resume(returning: .failure(tr("Health 查询没有返回结果", "Health query returned no results", "ヘルスケアのクエリが結果を返しませんでした")))
                    return
                }

                guard !workouts.isEmpty else {
                    continuation.resume(returning: .noData)
                    return
                }
                let result = workouts.map { w in
                    (
                        type: workoutActivityName(w.workoutActivityType),
                        durationMin: Int(w.duration / 60),
                        calories: Int(w.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0),
                        date: isoDateString(w.startDate)
                    )
                }
                continuation.resume(returning: .success(result))
            }
            store.execute(query)
        }
    }

    // MARK: - Formatting Helpers

    static func isoDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func roundedOneDecimal(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func formatOneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func minutesText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if LanguageService.shared.current.isChinese {
            if hours > 0 {
                return "\(hours) 小时 \(mins) 分钟"
            }
            return "\(mins) 分钟"
        }
        if LanguageService.shared.current.isJapanese {
            if hours > 0 {
                return "\(hours) 時間 \(mins) 分"
            }
            return "\(mins) 分"
        }
        if hours > 0 {
            return "\(hours) h \(mins) min"
        }
        return "\(mins) min"
    }

    private static func totalAsleepMinutes(in stages: [(stage: String, minutes: Int)]) -> Int {
        stages.reduce(0) { total, entry in
            let isAsleep = entry.stage == "asleep"
                || entry.stage == "core"
                || entry.stage == "deep"
                || entry.stage == "REM"
            return total + (isAsleep ? entry.minutes : 0)
        }
    }

    private static func healthRangeAdvice(
        stepAverage: Int?,
        sleepAverage: Int?,
        workoutCount: Int?
    ) -> String {
        if let stepAverage, stepAverage < 3_000 {
            return tr("日均步数偏少，先把每天散步或通勤步数稳定到 3000-5000 步。", "Average steps are low; first aim for 3,000-5,000 steady daily walking or commute steps.", "1日の平均歩数が少なめです。まずは毎日の散歩や通勤の歩数を3000～5000歩で安定させましょう。")
        }
        if let sleepAverage, sleepAverage < 6 * 60 {
            return tr("睡眠时长偏少，优先把作息稳定下来。", "Sleep duration is low; prioritize a steadier sleep schedule.", "睡眠時間が少なめです。まずは生活リズムを整えることを優先しましょう。")
        }
        if let workoutCount, workoutCount == 0 {
            return tr("可以安排 1-2 次低强度训练或快走。", "Consider 1-2 low-intensity workouts or brisk walks.", "低強度のトレーニングや早歩きを1～2回取り入れてみましょう。")
        }
        return tr("整体节奏可以，继续保持并关注趋势变化。", "The overall rhythm looks fine; keep it up and watch the trend.", "全体的なペースは良好です。この調子を保ちつつ、傾向の変化に注目しましょう。")
    }

    private static func healthSuccess(
        summary: String,
        extras: [String: Any] = [:]
    ) -> CanonicalToolResult {
        var payloadExtras = extras
        payloadExtras["phone_ground"] = healthPhoneGroundMetadata(status: "succeeded")
        payloadExtras["evidence_pack"] = healthEvidencePack(
            summary: summary,
            extras: extras,
            status: (extras["type"] as? String) == "empty" ? "empty" : "sufficient"
        )
        return CanonicalToolResult(
            success: true,
            summary: summary,
            detail: successPayload(result: summary, extras: payloadExtras)
        )
    }

    private static func healthEmpty(
        summary: String,
        extras: [String: Any] = [:]
    ) -> CanonicalToolResult {
        var extras = extras
        extras["type"] = "empty"
        return healthSuccess(summary: summary, extras: extras)
    }

    private static func healthFailure(
        summary: String,
        detail: String,
        errorCode: String
    ) -> CanonicalToolResult {
        let extras: [String: Any] = [
            "error_code": errorCode,
            "phone_ground": healthPhoneGroundMetadata(status: "failed"),
            "evidence_pack": healthEvidencePack(
                summary: summary,
                extras: ["error_code": errorCode],
                status: "failed"
            )
        ]
        return CanonicalToolResult(
            success: false,
            summary: summary,
            detail: failurePayload(error: detail, extras: extras),
            errorCode: errorCode
        )
    }

    private static func healthPhoneGroundMetadata(status: String) -> [String: Any] {
        [
            "version": "phoneground_v0",
            "evidence_type": PhoneGroundEvidenceType.health.rawValue,
            "answer_contract": PhoneGroundAnswerContract.groundedDataSummary.rawValue,
            "freshness": PhoneGroundFreshnessRequirement.userScopedData.rawValue,
            "privacy": "device_local",
            "status": status
        ]
    }

    private static func healthEvidencePack(
        summary: String,
        extras: [String: Any],
        status: String
    ) -> [String: Any] {
        let metricKeys = extras.keys
            .filter { key in
                !["phone_ground", "evidence_pack", "success", "status", "result"].contains(key)
            }
            .sorted()
        return [
            "version": "phoneground_health_v0",
            "source_type": PhoneGroundEvidenceType.health.rawValue,
            "sufficiency": status,
            "generated_at": iso8601String(from: Date()),
            "metric_keys": metricKeys,
            "item_count": summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1,
            "items": [
                [
                    "id": "health_summary",
                    "type": PhoneGroundEvidenceType.health.rawValue,
                    "title": tr("健康数据摘要", "Health data summary", "ヘルスデータの概要"),
                    "content": summary,
                    "confidence": "device_data"
                ] as [String: Any]
            ]
        ]
    }

    private static func stepsNoDataResult(
        periodDescription: String,
        extras: [String: Any] = [:]
    ) -> CanonicalToolResult {
        healthEmpty(
            summary: tr("\(periodDescription)还没有可用的步数数据。", "No step data is available for \(periodDescription) yet.", "\(periodDescription)はまだ利用可能な歩数データがありません。"),
            extras: extras
        )
    }

    private static func stepsFailureResult(_ detail: String) -> CanonicalToolResult {
        healthFailure(
            summary: tr("无法读取步数数据。请确认健康权限已开启。", "Unable to read step data. Please make sure Health permission is enabled.", "歩数データを読み取れません。ヘルスケアの権限が有効になっているか確認してください。"),
            detail: tr("读取步数失败：\(detail)", "Failed to read steps: \(detail)", "歩数の読み取りに失敗：\(detail)"),
            errorCode: "HEALTH_STEPS_READ_FAILED"
        )
    }

    private static func singleDayStepsSummary(periodZh: String, periodEn: String, steps: Int) -> String {
        let (zhComment, enComment) = stepsActivityComment(for: steps)
        if LanguageService.shared.current.isChinese {
            return "\(periodZh)走了 \(steps) 步，\(zhComment)"
        }
        return "\(periodEn), you walked \(steps) steps. \(enComment)"
    }

    private static func stepsRangeSummary(days: Int, total: Int, average: Int) -> String {
        let (zhComment, enComment) = stepsActivityComment(for: average)
        if LanguageService.shared.current.isChinese {
            return "最近 \(days) 天共走了 \(total) 步，日均 \(average) 步，\(zhComment)"
        }
        return "Over the past \(days) days, you walked \(total) steps, averaging \(average) per day. \(enComment)"
    }

    private static func stepsActivityComment(for steps: Int) -> (zh: String, en: String) {
        if steps < 3_000 {
            return (
                "活动量偏少。可以出去散散步。",
                "Activity is on the low side. A short walk may help."
            )
        }
        if steps < 8_000 {
            return (
                "活动量一般。",
                "Activity is about average."
            )
        }
        return (
            "活动量不错。",
            "Nice activity level."
        )
    }

    private static func workoutActivityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running:              return tr("跑步", "Running", "ランニング")
        case .walking:              return tr("步行", "Walking", "ウォーキング")
        case .cycling:              return tr("骑行", "Cycling", "サイクリング")
        case .swimming:             return tr("游泳", "Swimming", "水泳")
        case .yoga:                 return tr("瑜伽", "Yoga", "ヨガ")
        case .hiking:               return tr("徒步", "Hiking", "ハイキング")
        case .functionalStrengthTraining, .traditionalStrengthTraining:
                                    return tr("力量训练", "Strength Training", "筋力トレーニング")
        case .highIntensityIntervalTraining: return "HIIT"
        case .dance:                return tr("舞蹈", "Dance", "ダンス")
        case .elliptical:           return tr("椭圆机", "Elliptical", "エリプティカル")
        case .rowing:               return tr("划船", "Rowing", "ローイング")
        case .stairClimbing:        return tr("爬楼", "Stair Climbing", "階段昇降")
        default:                    return tr("其他运动", "Other Workout", "その他のワークアウト")
        }
    }
}
#else
// macOS: 无 HealthKit, 整个 enum 是 no-op stub. CLI 实际跑的是
// MockToolHandlers.HealthTools (Package.swift exclude Health.swift 的话用 mock,
// 不 exclude 的话用这个 stub — 我们不 exclude, 让源 enum 编译通过为 stub,
// 但 mock 文件里 HealthTools 与本 stub 同名会冲突, 所以 Package.swift 仍 exclude
// 这个文件让 mock 接管).
//
// 实际加载流程 (CLI):
//   - Package.swift exclude 了 Tools/Handlers/Health.swift
//   - MockToolHandlers.swift 提供 enum HealthTools 的 fixture 实现
//   - ToolRegistry.registerBuiltInTools() 调 HealthTools.register → mock
enum HealthTools {
    static func register(into registry: ToolRegistry) {}
}
#endif
