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
        registerSleepLastNight(into: registry)
        registerSleepWeek(into: registry)
        registerWorkoutRecent(into: registry)
    }

    // ── health-steps-today ──
    private static func registerStepsToday(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-steps-today",
            description: tr("读取用户今日步数 (从本地 0 点到当前时间的累计步数)。仅读取,不修改。", "Read the user's step count for today (cumulative steps from local midnight to now). Read-only, no modifications."),
            parameters: tr("无", "None"),
            isParameterless: true,
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
            description: tr("读取用户昨日步数 (昨天本地 0 点到 23:59:59 的累计步数)。仅读取,不修改。", "Read the user's step count for yesterday (cumulative steps from yesterday local midnight to 23:59:59). Read-only, no modifications."),
            parameters: tr("无", "None"),
            isParameterless: true,
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
            description: tr("读取用户昨晚的睡眠数据 (最近 24 小时内的睡眠记录)。返回总时长和分阶段明细。", "Read the user's sleep data for last night (sleep records within the past 24 hours). Returns total duration and per-stage breakdown."),
            parameters: tr("无", "None"),
            isParameterless: true,
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
            description: tr("读取用户最近 7 天的睡眠汇总 (每晚总时长 + 7 天平均)。", "Read a sleep summary for the user's past 7 days (total duration per night + 7-day average)."),
            parameters: tr("无", "None"),
            isParameterless: true,
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
            description: tr("读取用户最近 7 天的运动记录 (类型、时长、消耗)。", "Read the user's workout records for the past 7 days (type, duration, calories burned)."),
            parameters: tr("无", "None"),
            isParameterless: true,
            execute: { args in
                try await workoutRecentCanonical(args).detail
            },
            executeCanonical: { args in
                try await workoutRecentCanonical(args)
            }
        ))
    }

    // ── health-distance-today ──
    private static func registerDistanceToday(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-distance-today",
            description: tr("读取用户今日步行+跑步距离 (从本地 0 点到当前时间, 单位 km)。仅读取。", "Read the user's walking+running distance for today (from local midnight to now, in km). Read-only."),
            parameters: tr("无", "None"),
            isParameterless: true,
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
            description: tr("读取用户今日活动消耗的卡路里 (从本地 0 点到当前时间)。仅读取。", "Read the user's active calories burned today (from local midnight to now). Read-only."),
            parameters: tr("无", "None"),
            isParameterless: true,
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
            description: tr("读取用户最近的静息心率 (最近 24 小时平均, 单位 BPM)。仅读取。", "Read the user's recent resting heart rate (average over the past 24 hours, in BPM). Read-only."),
            parameters: tr("无", "None"),
            isParameterless: true,
            execute: { args in
                try await heartRateRestingCanonical(args).detail
            },
            executeCanonical: { args in
                try await heartRateRestingCanonical(args)
            }
        ))
    }

    // ── health-steps-range ──
    private static func registerStepsRange(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "health-steps-range",
            description: tr("读取最近 N 天的每日步数。返回每日列表 + 总数 + 日均。", "Read daily step counts for the past N days. Returns a daily list + total + daily average."),
            parameters: tr("{\"days\":{\"type\":\"integer\",\"description\":\"查询天数 (1-30)\",\"required\":true}}", "{\"days\":{\"type\":\"integer\",\"description\":\"Number of days to query (1-30)\",\"required\":true}}"),
            requiredParameters: ["days"],
            isParameterless: false,
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
            let summary = tr("今天走了 \(rounded) 步。", "You walked \(rounded) steps today.")
            return healthSuccess(
                summary: summary,
                extras: ["steps": rounded, "unit": tr("步", "steps"), "date": isoDateString(now)]
            )
        case .noData:
            return stepsNoDataResult(periodDescription: tr("今天", "today"), extras: ["date": isoDateString(now)])
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
            let summary = tr("昨天走了 \(rounded) 步。", "You walked \(rounded) steps yesterday.")
            return healthSuccess(
                summary: summary,
                extras: ["steps": rounded, "unit": tr("步", "steps"), "date": isoDateString(yesterdayStart)]
            )
        case .noData:
            return stepsNoDataResult(periodDescription: tr("昨天", "yesterday"), extras: ["date": isoDateString(yesterdayStart)])
        case .failure(let error):
            return stepsFailureResult(error)
        }
    }

    private static func sleepLastNightCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        let now = Date()
        let start = Calendar.current.date(byAdding: .hour, value: -24, to: now)!
        switch await fetchSleepAnalysisResult(start: start, end: now) {
        case .success(let stages):
            let totalMin = stages.reduce(0) { $0 + $1.minutes }
            let hours = totalMin / 60
            let mins = totalMin % 60
            let stageList = stages.map { ["stage": $0.stage, "minutes": $0.minutes] as [String: Any] }
            let summary = tr("昨晚睡了 \(hours) 小时 \(mins) 分钟。", "You slept \(hours) h \(mins) min last night.")
            return healthSuccess(
                summary: summary,
                extras: ["total_minutes": totalMin, "hours": hours, "minutes": mins, "stages": stageList]
            )
        case .noData:
            return healthEmpty(
                summary: tr("最近 24 小时没有睡眠记录", "No sleep records in the past 24 hours"),
                extras: ["total_minutes": 0, "stages": [] as [Any]]
            )
        case .failure(let error):
            return healthFailure(
                summary: tr("无法读取睡眠数据。请确认健康权限已开启。", "Unable to read sleep data. Please make sure Health permission is enabled."),
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
            let totalMin = stages.reduce(0) { $0 + $1.minutes }
            let avgMin = totalMin / 7
            let avgH = avgMin / 60
            let avgM = avgMin % 60
            let summary = tr("最近 7 天日均睡眠 \(avgH) 小时 \(avgM) 分钟。", "Your 7-day sleep average is \(avgH) h \(avgM) min.")
            return healthSuccess(
                summary: summary,
                extras: ["total_minutes": totalMin, "avg_minutes": avgMin, "days": 7]
            )
        case .noData:
            return healthEmpty(
                summary: tr("最近 7 天没有睡眠记录", "No sleep records in the past 7 days"),
                extras: ["nights": [] as [Any], "avg_minutes": 0]
            )
        case .failure(let error):
            return healthFailure(
                summary: tr("无法读取睡眠数据。请确认健康权限已开启。", "Unable to read sleep data. Please make sure Health permission is enabled."),
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
            let summary = tr("最近 7 天有 \(workouts.count) 次运动，共 \(totalMin) 分钟。", "\(workouts.count) workouts in the past 7 days, \(totalMin) min total.")
            return healthSuccess(
                summary: summary,
                extras: ["workouts": list, "count": workouts.count, "total_minutes": totalMin]
            )
        case .noData:
            return healthEmpty(
                summary: tr("最近 7 天没有运动记录", "No workout records in the past 7 days"),
                extras: ["workouts": [] as [Any], "count": 0]
            )
        case .failure(let error):
            return healthFailure(
                summary: tr("无法读取运动数据。请确认健康权限已开启。", "Unable to read workout data. Please make sure Health permission is enabled."),
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
            let summary = tr("今天步行约 \(km) 公里。", "You walked about \(km) km today.")
            return healthSuccess(
                summary: summary,
                extras: ["distance_km": km, "distance_m": Int(meters.rounded()), "date": isoDateString(now)]
            )
        case .noData:
            return healthEmpty(
                summary: tr("今天还没有可用的步行距离数据。", "No walking distance data available yet today."),
                extras: ["distance_km": 0, "distance_m": 0, "date": isoDateString(now)]
            )
        case .failure(let error):
            return healthFailure(
                summary: tr("无法读取距离数据。请确认健康权限已开启。", "Unable to read distance data. Please make sure Health permission is enabled."),
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
            let summary = tr("今天活动消耗约 \(rounded) 千卡。", "You burned about \(rounded) active kcal today.")
            return healthSuccess(
                summary: summary,
                extras: ["calories": rounded, "unit": "kcal", "date": isoDateString(now)]
            )
        case .noData:
            return healthEmpty(
                summary: tr("今天还没有可用的活动能量数据。", "No active energy data available yet today."),
                extras: ["calories": 0, "unit": "kcal", "date": isoDateString(now)]
            )
        case .failure(let error):
            return healthFailure(
                summary: tr("无法读取能量消耗数据。请确认健康权限已开启。", "Unable to read active energy data. Please make sure Health permission is enabled."),
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
            let summary = tr("静息心率是 \(rounded) BPM。", "Your resting heart rate is \(rounded) BPM.")
            return healthSuccess(
                summary: summary,
                extras: ["bpm": rounded, "unit": "BPM"]
            )
        case .noData:
            return healthEmpty(
                summary: tr("最近 24 小时还没有可用的静息心率数据。", "No resting heart rate data available in the past 24 hours."),
                extras: ["bpm": 0, "unit": "BPM"]
            )
        case .failure(let error):
            return healthFailure(
                summary: tr("无法读取心率数据。请确认健康权限已开启。", "Unable to read heart rate data. Please make sure Health permission is enabled."),
                detail: error,
                errorCode: "HEALTH_HEART_RATE_READ_FAILED"
            )
        }
    }

    private static func stepsRangeCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        let rawDays = (args["days"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let days = (args["days"] as? Int) ?? rawDays.flatMap(Int.init) else {
            return healthFailure(
                summary: tr("请告诉我查询最近几天，1 到 30 天。", "Please tell me how many days to query, between 1 and 30."),
                detail: tr("缺少 days 参数 (1-30 的整数)", "Missing `days` parameter (integer 1-30)"),
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
            let summary = tr("最近 \(clampedDays) 天共走了 \(total) 步，日均 \(avg) 步。", "Over the past \(clampedDays) days, you walked \(total) steps, averaging \(avg) per day.")
            return healthSuccess(
                summary: summary,
                extras: ["days": clampedDays, "total": total, "daily_avg": avg, "daily": dailyList]
            )
        case .noData:
            return stepsNoDataResult(periodDescription: tr("最近 \(clampedDays) 天", "the past \(clampedDays) days"), extras: ["days": clampedDays])
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
            return tr("设备不支持 HealthKit", "This device does not support HealthKit")
        }
        do {
            try await store.requestAuthorization(toShare: [], read: types)
        } catch {
            return tr("健康数据授权失败: \(error.localizedDescription)", "Health data authorization failed: \(error.localizedDescription)")
        }
        return nil
    }

    private static func fetchQuantitySumResult(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async -> HealthQueryOutcome<Double> {
        guard let qType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            return .failure(tr("不支持的数据类型：\(identifier.rawValue)", "Unsupported data type: \(identifier.rawValue)"))
        }
        if let err = await requestReadAuth(for: [qType]) {
            print("[Health] auth request error: \(err)")
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
                    continuation.resume(
                        returning: .failure(tr("Health 查询失败：\(error.localizedDescription)", "Health query failed: \(error.localizedDescription)"))
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
            return .failure(tr("不支持的数据类型：\(identifier.rawValue)", "Unsupported data type: \(identifier.rawValue)"))
        }
        if let err = await requestReadAuth(for: [qType]) {
            print("[Health] auth request error: \(err)")
            return .failure(err)
        }
        let cal = Calendar.current
        let now = Date()
        let endOfToday = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now)!)
        let start = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: now))!
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
                    continuation.resume(
                        returning: .failure(tr("Health 查询失败：\(error.localizedDescription)", "Health query failed: \(error.localizedDescription)"))
                    )
                    return
                }
                guard let results else {
                    continuation.resume(returning: .failure(tr("Health 查询没有返回结果", "Health query returned no results")))
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
            return .failure(tr("不支持的数据类型：\(identifier.rawValue)", "Unsupported data type: \(identifier.rawValue)"))
        }
        if let err = await requestReadAuth(for: [qType]) {
            print("[Health] auth error: \(err)")
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
                    continuation.resume(
                        returning: .failure(tr("Health 查询失败：\(error.localizedDescription)", "Health query failed: \(error.localizedDescription)"))
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

    /// 查询睡眠分析数据 (HKCategoryType)。
    /// 返回 [(stage: String, minutes: Int)] 数组。
    private static func fetchSleepAnalysisResult(
        start: Date,
        end: Date
    ) async -> HealthQueryOutcome<[(stage: String, minutes: Int)]> {
        guard let sleepType = HKObjectType.categoryType(
            forIdentifier: .sleepAnalysis
        ) else { return .failure(tr("不支持的数据类型：sleepAnalysis", "Unsupported data type: sleepAnalysis")) }
        if let err = await requestReadAuth(for: [sleepType]) {
            print("[Health] auth error: \(err)")
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
                    continuation.resume(
                        returning: .failure(tr("Health 查询失败：\(error.localizedDescription)", "Health query failed: \(error.localizedDescription)"))
                    )
                    return
                }

                guard let samples = samples as? [HKCategorySample] else {
                    continuation.resume(returning: .failure(tr("Health 查询没有返回结果", "Health query returned no results")))
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
            print("[Health] auth error: \(err)")
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
                    continuation.resume(
                        returning: .failure(tr("Health 查询失败：\(error.localizedDescription)", "Health query failed: \(error.localizedDescription)"))
                    )
                    return
                }

                guard let workouts = samples as? [HKWorkout] else {
                    continuation.resume(returning: .failure(tr("Health 查询没有返回结果", "Health query returned no results")))
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

    private static func healthSuccess(
        summary: String,
        extras: [String: Any] = [:]
    ) -> CanonicalToolResult {
        CanonicalToolResult(
            success: true,
            summary: summary,
            detail: successPayload(result: summary, extras: extras)
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
        CanonicalToolResult(
            success: false,
            summary: summary,
            detail: failurePayload(error: detail, extras: ["error_code": errorCode]),
            errorCode: errorCode
        )
    }

    private static func stepsNoDataResult(
        periodDescription: String,
        extras: [String: Any] = [:]
    ) -> CanonicalToolResult {
        healthEmpty(
            summary: tr("\(periodDescription)还没有可用的步数数据。", "No step data is available for \(periodDescription) yet."),
            extras: extras
        )
    }

    private static func stepsFailureResult(_ detail: String) -> CanonicalToolResult {
        healthFailure(
            summary: tr("无法读取步数数据。请确认健康权限已开启。", "Unable to read step data. Please make sure Health permission is enabled."),
            detail: tr("读取步数失败：\(detail)", "Failed to read steps: \(detail)"),
            errorCode: "HEALTH_STEPS_READ_FAILED"
        )
    }

    private static func workoutActivityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running:              return tr("跑步", "Running")
        case .walking:              return tr("步行", "Walking")
        case .cycling:              return tr("骑行", "Cycling")
        case .swimming:             return tr("游泳", "Swimming")
        case .yoga:                 return tr("瑜伽", "Yoga")
        case .hiking:               return tr("徒步", "Hiking")
        case .functionalStrengthTraining, .traditionalStrengthTraining:
                                    return tr("力量训练", "Strength Training")
        case .highIntensityIntervalTraining: return "HIIT"
        case .dance:                return tr("舞蹈", "Dance")
        case .elliptical:           return tr("椭圆机", "Elliptical")
        case .rowing:               return tr("划船", "Rowing")
        case .stairClimbing:        return tr("爬楼", "Stair Climbing")
        default:                    return tr("其他运动", "Other Workout")
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
