import XCTest

final class SkillRouterCompatibilityContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PhoneClawCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testProductionSourcesDoNotImportIOS27OnlyFrameworksWithoutGuards() throws {
        let productionDirectories = ["Agent", "LLM", "Shared", "Skills", "Tools", "UI", "Live", "App"]
        let forbiddenImports = ["import FoundationModels", "import CoreAI"]
        let fileManager = FileManager.default

        for directory in productionDirectories {
            let root = repoRoot.appendingPathComponent(directory)
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                for forbiddenImport in forbiddenImports {
                    guard content.contains(forbiddenImport) else { continue }
                    XCTAssertTrue(
                        fileURL.lastPathComponent.hasPrefix("IOS27") && content.contains("#if canImport("),
                        "\(fileURL.path) must guard \(forbiddenImport) behind an iOS 27 compatibility boundary"
                    )
                }
            }
        }
    }

    func testGuardedDirectAnswerBlocksModelIntentFallback() throws {
        let processInput = try source("Agent/Engine/ProcessInput.swift")

        XCTAssertTrue(processInput.contains("guardedRouteBlocksModelIntent"))
        XCTAssertTrue(processInput.contains("!guardedRouteBlocksModelIntent"))
        XCTAssertTrue(processInput.contains("guardedRouteDecision?.action == .answerDirectly"))
    }

    func testIOS27FoundationRouterIsAutoEnabledAndFallbackOnly() throws {
        let flags = try source("Agent/HotfixFeatureFlags.swift")
        let processInput = try source("Agent/Engine/ProcessInput.swift")
        let router = try source("Agent/Engine/Router.swift")
        let ios27Router = try source("Agent/Engine/IOS27FoundationSkillRouter.swift")

        XCTAssertTrue(flags.contains("ENABLE_IOS27_FOUNDATION_ROUTER"))
        XCTAssertTrue(flags.contains("value(for: .enableIOS27FoundationRouter, defaultValue: true)"))
        XCTAssertTrue(processInput.contains("ios27FoundationSkillRouteDecision"))
        XCTAssertTrue(processInput.contains("!guardedRouteBlocksModelIntent"))
        XCTAssertTrue(processInput.contains("!ios27RouteBlocksModelIntent"))
        XCTAssertTrue(router.contains("shouldAttemptIOS27FoundationSkillRoute"))
        XCTAssertTrue(ios27Router.contains("#if canImport(FoundationModels)"))
        XCTAssertTrue(ios27Router.contains("if #available(iOS 27.0, *)"))
    }

    func testIOS27FoundationRouterUsesIOS27ModelAPIsWithDiagnostics() throws {
        let router = try source("Agent/Engine/Router.swift")
        let ios27Router = try source("Agent/Engine/IOS27FoundationSkillRouter.swift")

        XCTAssertTrue(ios27Router.contains("session.prewarm()"))
        XCTAssertTrue(ios27Router.contains("GenerationOptions("))
        XCTAssertTrue(ios27Router.contains("toolCallingMode: .disallowed"))
        XCTAssertTrue(ios27Router.contains("ContextOptions(includeSchemaInPrompt: true)"))
        XCTAssertTrue(ios27Router.contains("metadata: ["))
        XCTAssertTrue(ios27Router.contains("response.usage.input.totalTokenCount"))
        XCTAssertTrue(ios27Router.contains("response.usage.output.reasoningTokenCount"))
        XCTAssertTrue(router.contains("source=foundation_probe"))
        XCTAssertTrue(router.contains("prewarm_ms="))
        XCTAssertTrue(router.contains("route_ms="))
        XCTAssertTrue(router.contains("total_tokens="))
    }

    func testRouteSourceLogsAreStandardized() throws {
        let processInput = try source("Agent/Engine/ProcessInput.swift")
        let router = try source("Agent/Engine/Router.swift")

        XCTAssertTrue(processInput.contains("source=trigger"))
        XCTAssertTrue(router.contains("source=guarded"))
        XCTAssertTrue(router.contains("source=foundation"))
        XCTAssertTrue(router.contains("source=model"))
    }
}
