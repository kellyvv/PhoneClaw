import SwiftUI
import UIKit

#if canImport(CoreAI)
import CoreAI
#endif

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 27.0, *)
@Generable(description: "A PhoneClaw skill routing decision.")
private struct GuidedSkillRoute {
    @Guide(description: "Routing action. Use useSkill for requests that create, schedule, modify, or execute an action. Use answerDirectly only when PhoneClaw should reply with text and perform no action.", .anyOf(["answerDirectly", "useSkill", "askClarification"]))
    var action: String

    @Guide(description: "Selected skill identifier. For meeting scheduling, choose calendar.", .anyOf(["calendar", "reminders", "clipboard", "health", "translate", "web-search", "null"]))
    var skillID: String

    @Guide(description: "Selected tool name, or null when no tool should run.", .anyOf(["calendar-create-event", "reminders-create", "null"]))
    var toolName: String

    @Guide(description: "Confidence from 0.0 to 1.0.", .range(0.0...1.0))
    var confidence: Double

    @Guide(description: "Short reason for the routing decision.")
    var reason: String
}
#endif

struct ProbeView: View {
    @State private var lines: [String] = ["Ready."]
    @State private var isRunningFoundationTest = false
    @State private var isRunningRouterTest = false
    @State private var isRunningGuidedRouteTest = false
    @State private var isRunningRouteMatrixTest = false
    @State private var isRunningGuardedMatrixTest = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("iOS 27 Core AI Probe")
                        .font(.title2.weight(.semibold))

                    Button("Run Probe") {
                        runProbe()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(isRunningFoundationTest ? "Testing..." : "Test Foundation Response") {
                        Task {
                            await runFoundationResponseTest()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunningFoundationTest)

                    Button(isRunningRouterTest ? "Routing..." : "Test Router JSON") {
                        Task {
                            await runRouterJSONTest()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunningRouterTest)

                    Button(isRunningGuidedRouteTest ? "Guiding..." : "Test Guided Route") {
                        Task {
                            await runGuidedRouteTest()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunningGuidedRouteTest)

                    Button(isRunningRouteMatrixTest ? "Matrix..." : "Test Route Matrix") {
                        Task {
                            await runRouteMatrixTest()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunningRouteMatrixTest)

                    Button(isRunningGuardedMatrixTest ? "Guarded..." : "Test Guarded Matrix") {
                        Task {
                            await runGuardedMatrixTest()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunningGuardedMatrixTest)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding()
            }
            .navigationTitle("Probe")
            .onAppear(perform: runProbe)
        }
    }

    private func runProbe() {
        var result: [String] = []

        result.append("Probe ran: \(Self.timestamp())")
        result.append("Device: \(UIDevice.current.name)")
        result.append("System: iOS \(UIDevice.current.systemVersion)")

        #if canImport(FoundationModels)
        result.append("FoundationModels: module present")
        if #available(iOS 27.0, *) {
            let model = SystemLanguageModel.default
            result.append("SystemLanguageModel: \(String(describing: model.availability))")
        } else {
            result.append("SystemLanguageModel: unavailable before iOS 27")
        }
        #else
        result.append("FoundationModels: module missing")
        #endif

        #if canImport(CoreAI)
        result.append("CoreAI: module present")
        if #available(iOS 27.0, *) {
            result.append("CoreAI architecture: \(AIModel.deviceArchitectureName)")
        } else {
            result.append("CoreAI: unavailable before iOS 27")
        }
        #else
        result.append("CoreAI: module missing")
        #endif

        lines = result
    }

    @MainActor
    private func runFoundationResponseTest() async {
        isRunningFoundationTest = true
        defer { isRunningFoundationTest = false }

        var result = lines
        result.append("")
        result.append("Foundation test started: \(Self.timestamp())")
        lines = result

        #if canImport(FoundationModels)
        if #available(iOS 27.0, *) {
            do {
                let model = SystemLanguageModel.default
                result.append("Availability before response: \(String(describing: model.availability))")
                lines = result

                let session = LanguageModelSession(
                    instructions: "Reply with one short sentence. Do not use Markdown."
                )
                let response = try await session.respond(
                    to: "Say that PhoneClaw can access the iOS 27 system language model."
                )
                result.append("Response: \(response.content)")
            } catch {
                result.append("Foundation test error: \(error.localizedDescription)")
            }
        } else {
            result.append("Foundation test skipped: requires iOS 27")
        }
        #else
        result.append("Foundation test skipped: module missing")
        #endif

        result.append("Foundation test ended: \(Self.timestamp())")
        lines = result
    }

    @MainActor
    private func runRouterJSONTest() async {
        isRunningRouterTest = true
        defer { isRunningRouterTest = false }

        var result = lines
        result.append("")
        result.append("Router test started: \(Self.timestamp())")
        lines = result

        #if canImport(FoundationModels)
        if #available(iOS 27.0, *) {
            do {
                let session = LanguageModelSession(
                    instructions: """
                    You are PhoneClaw's routing model. Return exactly one compact JSON object and no Markdown.
                    Schema:
                    {"action":"answerDirectly|useSkill|askClarification","skillID":"calendar|reminders|clipboard|health|translate|web-search|null","toolName":"string|null","confidence":0.0,"reason":"short"}
                    """
                )
                let prompt = """
                User request: 明天下午两点帮我安排产品评审会议
                Available Skills:
                - calendar: create calendar events, tool calendar-create-event
                - reminders: create reminders, tool reminders-create
                - translate: translate text, no tool
                Choose the best route.
                """

                let response = try await session.respond(to: prompt)
                result.append("Router raw: \(response.content)")

                if let json = Self.extractFirstJSONObject(from: response.content),
                   let data = json.data(using: .utf8),
                   let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let action = object["action"] as? String ?? "?"
                    let skillID = object["skillID"] as? String ?? "?"
                    let toolName = object["toolName"] as? String ?? "?"
                    result.append("Router parsed: action=\(action), skillID=\(skillID), toolName=\(toolName)")
                } else {
                    result.append("Router parse: failed")
                }
            } catch {
                result.append("Router test error: \(error.localizedDescription)")
            }
        } else {
            result.append("Router test skipped: requires iOS 27")
        }
        #else
        result.append("Router test skipped: module missing")
        #endif

        result.append("Router test ended: \(Self.timestamp())")
        lines = result
    }

    @MainActor
    private func runGuidedRouteTest() async {
        isRunningGuidedRouteTest = true
        defer { isRunningGuidedRouteTest = false }

        var result = lines
        result.append("")
        result.append("Guided route started: \(Self.timestamp())")
        lines = result

        #if canImport(FoundationModels)
        if #available(iOS 27.0, *) {
            do {
                let session = LanguageModelSession(
                    instructions: Self.guidedRouteInstructions
                )
                let prompt = Self.guidedRoutePrompt(for: "明天下午两点帮我安排产品评审会议")

                let response = try await session.respond(to: prompt, generating: GuidedSkillRoute.self)
                let route = response.content
                result.append("Guided route: action=\(route.action), skillID=\(route.skillID), toolName=\(route.toolName)")
                result.append("Guided confidence: \(route.confidence)")
                result.append("Guided reason: \(route.reason)")
                result.append("Guided usage: input=\(response.usage.input.totalTokenCount), output=\(response.usage.output.totalTokenCount), total=\(response.usage.totalTokenCount)")
                if route.action == "useSkill", route.skillID == "calendar", route.toolName == "calendar-create-event" {
                    result.append("Guided validation: PASS")
                } else {
                    result.append("Guided validation: FAIL expected calendar-create-event")
                }
            } catch {
                result.append("Guided route error: \(error.localizedDescription)")
            }
        } else {
            result.append("Guided route skipped: requires iOS 27")
        }
        #else
        result.append("Guided route skipped: module missing")
        #endif

        result.append("Guided route ended: \(Self.timestamp())")
        lines = result
    }

    @MainActor
    private func runRouteMatrixTest() async {
        isRunningRouteMatrixTest = true
        defer { isRunningRouteMatrixTest = false }

        var result = lines
        result.append("")
        result.append("Route matrix started: \(Self.timestamp())")
        result.append("Route matrix mode: stateless sessions")
        lines = result

        #if canImport(FoundationModels)
        if #available(iOS 27.0, *) {
            do {
                let cases = Self.routeCases

                var passCount = 0
                for testCase in cases {
                    let session = LanguageModelSession(
                        instructions: Self.guidedRouteInstructions
                    )
                    let response = try await session.respond(
                        to: Self.guidedRoutePrompt(for: testCase.request),
                        generating: GuidedSkillRoute.self
                    )
                    let route = response.content
                    let passed = route.action == testCase.action &&
                        route.skillID == testCase.skillID &&
                        route.toolName == testCase.toolName
                    if passed {
                        passCount += 1
                    }

                    let status = passed ? "PASS" : "FAIL"
                    result.append("[\(status)] \(testCase.label): \(route.action)/\(route.skillID)/\(route.toolName), tokens=\(response.usage.totalTokenCount)")
                    if !passed {
                        result.append("  expected: \(testCase.action)/\(testCase.skillID)/\(testCase.toolName)")
                        result.append("  reason: \(route.reason)")
                    }
                    lines = result
                }

                result.append("Route matrix summary: \(passCount)/\(cases.count) passed")
            } catch {
                result.append("Route matrix error: \(error.localizedDescription)")
            }
        } else {
            result.append("Route matrix skipped: requires iOS 27")
        }
        #else
        result.append("Route matrix skipped: module missing")
        #endif

        result.append("Route matrix ended: \(Self.timestamp())")
        lines = result
    }

    @MainActor
    private func runGuardedMatrixTest() async {
        isRunningGuardedMatrixTest = true
        defer { isRunningGuardedMatrixTest = false }

        var result = lines
        result.append("")
        result.append("Guarded matrix started: \(Self.timestamp())")
        result.append("Guarded matrix mode: rules before model")
        lines = result

        #if canImport(FoundationModels)
        if #available(iOS 27.0, *) {
            do {
                let cases = Self.routeCases
                var passCount = 0

                for testCase in cases {
                    let resolved: ResolvedRoute
                    let source: String
                    var tokens: Int?

                    if let ruleRoute = Self.deterministicRoute(for: testCase.request) {
                        resolved = ruleRoute
                        source = "rule"
                    } else {
                        let session = LanguageModelSession(
                            instructions: Self.guidedRouteInstructions
                        )
                        let response = try await session.respond(
                            to: Self.guidedRoutePrompt(for: testCase.request),
                            generating: GuidedSkillRoute.self
                        )
                        resolved = ResolvedRoute(response.content)
                        source = "model"
                        tokens = response.usage.totalTokenCount
                    }

                    let passed = resolved.action == testCase.action &&
                        resolved.skillID == testCase.skillID &&
                        resolved.toolName == testCase.toolName
                    if passed {
                        passCount += 1
                    }

                    let status = passed ? "PASS" : "FAIL"
                    let tokenText = tokens.map { ", tokens=\($0)" } ?? ""
                    result.append("[\(status)] \(testCase.label): \(resolved.action)/\(resolved.skillID)/\(resolved.toolName), source=\(source)\(tokenText)")
                    if !passed {
                        result.append("  expected: \(testCase.action)/\(testCase.skillID)/\(testCase.toolName)")
                        result.append("  reason: \(resolved.reason)")
                    }
                    lines = result
                }

                result.append("Guarded matrix summary: \(passCount)/\(cases.count) passed")
            } catch {
                result.append("Guarded matrix error: \(error.localizedDescription)")
            }
        } else {
            result.append("Guarded matrix skipped: requires iOS 27")
        }
        #else
        result.append("Guarded matrix skipped: module missing")
        #endif

        result.append("Guarded matrix ended: \(Self.timestamp())")
        lines = result
    }

    private static let guidedRouteInstructions = """
    You are PhoneClaw's deterministic skill router. Use the provided schema.
    Policy:
    - answerDirectly means PhoneClaw only replies with text and performs no action.
    - useSkill means PhoneClaw invokes one of the listed Skills/tools.
    - If the user asks to create, schedule, set, send, open, modify, delete, search, translate, remember, or operate on device/app state, choose useSkill when a matching Skill exists.
    - For calendar event creation or meeting scheduling, date and time are required. If date or time is missing, choose action=askClarification, skillID=calendar, toolName=calendar-create-event.
    - For calendar event creation or meeting scheduling with date and time present, choose action=useSkill, skillID=calendar, toolName=calendar-create-event.
    - For reminder creation with enough time or task information, choose action=useSkill, skillID=reminders, toolName=reminders-create.
    - Translation means converting text from one language to another. Only choose translate when the request explicitly says translate, 翻译, 译成, or asks to convert between languages.
    - Explanation, definition, introduction, or summary requests such as 解释, 介绍, 什么是, summarize, or explain are not translation. Use answerDirectly for those unless another action is requested.
    - Use askClarification only if a matching Skill exists but required information is missing.
    Do not invent skill IDs or tool names.
    """

    private static func guidedRoutePrompt(for request: String) -> String {
        """
        Route this request.

        User request:
        \(request)

        Available Skills:
        - calendar: creates calendar events for meetings, appointments, and schedules. Tool: calendar-create-event.
        - reminders: creates reminders and to-do items. Tool: reminders-create.
        - translate: translates text. Tool: null.

        Decision hints:
        - "安排会议", "创建日程", "schedule a meeting" => use calendar-create-event if date or time is present; otherwise askClarification.
        - "提醒我", "remember to", "remind me" => use reminders-create.
        - "翻译", "译成", "translate" => use translate.
        - "解释", "介绍", "什么是", "explain" => answerDirectly.
        - "帮我安排一次会议" has no date or time, so askClarification.
        - "解释一下什么是本地模型" is not translation, so answerDirectly.
        - Never answerDirectly for a request that should change the calendar, reminders, or another device/app state.
        """
    }

    private static var routeCases: [RouteCase] {
        [
            RouteCase(
                label: "calendar",
                request: "明天下午两点帮我安排产品评审会议",
                action: "useSkill",
                skillID: "calendar",
                toolName: "calendar-create-event"
            ),
            RouteCase(
                label: "reminder",
                request: "晚上八点提醒我喝水",
                action: "useSkill",
                skillID: "reminders",
                toolName: "reminders-create"
            ),
            RouteCase(
                label: "translate",
                request: "把 hello 翻译成中文",
                action: "useSkill",
                skillID: "translate",
                toolName: "null"
            ),
            RouteCase(
                label: "direct",
                request: "解释一下什么是本地模型",
                action: "answerDirectly",
                skillID: "null",
                toolName: "null"
            ),
            RouteCase(
                label: "clarify",
                request: "帮我安排一次会议",
                action: "askClarification",
                skillID: "calendar",
                toolName: "calendar-create-event"
            )
        ]
    }

    private static func deterministicRoute(for request: String) -> ResolvedRoute? {
        if containsAny(request, ["解释", "介绍", "什么是"]) &&
            !containsAny(request, ["翻译", "译成", "translate"]) {
            return ResolvedRoute(
                action: "answerDirectly",
                skillID: "null",
                toolName: "null",
                reason: "Rule: explanation or definition request does not require a Skill."
            )
        }

        if hasCalendarIntent(request) {
            if hasDateOrTimeSignal(request) {
                return ResolvedRoute(
                    action: "useSkill",
                    skillID: "calendar",
                    toolName: "calendar-create-event",
                    reason: "Rule: calendar event request includes a relative date or time signal."
                )
            }

            return ResolvedRoute(
                action: "askClarification",
                skillID: "calendar",
                toolName: "calendar-create-event",
                reason: "Rule: calendar event request is missing date or time."
            )
        }

        return nil
    }

    private static func hasCalendarIntent(_ text: String) -> Bool {
        containsAny(text, ["安排", "会议", "日程", "预约", "约会", "calendar", "meeting", "schedule"])
    }

    private static func hasDateOrTimeSignal(_ text: String) -> Bool {
        containsAny(
            text,
            [
                "今天", "明天", "后天", "大后天", "上午", "下午", "中午", "晚上",
                "点", "半", "周", "星期", "礼拜", "月", "号", "日",
                "today", "tomorrow", "morning", "afternoon", "evening", "pm", "am"
            ]
        )
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    private static func extractFirstJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var isEscaped = false
        var cursor = start

        while cursor < text.endIndex {
            let ch = text[cursor]

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if ch == "\\" {
                    isEscaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...cursor])
                    }
                }
            }

            cursor = text.index(after: cursor)
        }

        return nil
    }

    private struct RouteCase {
        let label: String
        let request: String
        let action: String
        let skillID: String
        let toolName: String
    }

    private struct ResolvedRoute {
        let action: String
        let skillID: String
        let toolName: String
        let reason: String

        init(action: String, skillID: String, toolName: String, reason: String) {
            self.action = action
            self.skillID = skillID
            self.toolName = toolName
            self.reason = reason
        }

        @available(iOS 27.0, *)
        init(_ route: GuidedSkillRoute) {
            self.action = route.action
            self.skillID = route.skillID
            self.toolName = route.toolName
            self.reason = route.reason
        }
    }
}
