import CoreImage
import Foundation
#if canImport(UIKit)
import UIKit
// 跨平台 image 类型别名 —— iOS 真编 UIKit 路径, macOS CLI 自动走 CIImage.
// AgentEngine 的 processInput(images:) 签名用这个别名, 调用端在各自平台用
// 自己的自然类型; iOS 二进制行为零改变 (UIImage == PlatformImage).
typealias PlatformImage = UIImage
#else
// macOS CLI: 不测图像输入场景, PlatformImage 只是签名占位.
typealias PlatformImage = CIImage
#endif

func log(_ message: String) {
    print(message)
}

// MARK: - Agent Engine
//
// 核心类: 持有所有运行时依赖 (inference / catalog / coordinator / sessionStore),
// 声明 @Observable 属性供 SwiftUI 绑定。
//
// 实际逻辑分布在多个 extension 文件中:
//   - EngineLifecycle.swift:         setup / config / session / cancel / retry
//   - ProcessInput.swift:            processInput / streamLLM / generation tracking
//   - PromptPipelineHelpers.swift:   prompt shape / plan / budget / observation
//   - ImageFollowUp.swift:           image follow-up routing + repair
//   - ToolChain.swift:               tool call execution chain
//   - Planner.swift:                 multi-skill planning
//   - Router.swift:                  skill matching / routing
//   - OutputCleaner.swift:           streaming output cleanup
//   - ToolCallParser.swift:          tool_call XML parsing
//   - ChatAttachments.swift:         attachment encoding helpers

@Observable
@MainActor
class AgentEngine {

    // MARK: - Core Dependencies

    let inference: InferenceService
    let catalog: ModelCatalog
    let installer: ModelInstaller
    let coordinator: ModelRuntimeCoordinator
    let sessionStore: ChatSessionStore

    // MARK: - Observable State

    var messages: [ChatMessage] = [] {
        didSet {
            sessionStore.scheduleSave(messages: messages)
        }
    }
    var isProcessing = false
    var didSetup = false
    var config = ModelConfig()

    // MARK: - Skill System

    let skillRegistry = SkillRegistry()
    let toolRegistry = ToolRegistry.shared
    let toolResultCanonicalizer: ToolResultCanonicalizer
    var skillEntries: [SkillEntry] = []

    // MARK: - Prompt Pipeline State

    let plannerRevision = "planner-v3-local-selection"
    var lastTurnMatchedSkillIds: [String] = []
    let legacyContextBudgetPlanner: ContextBudgetPlanner
    let hotfixContextBudgetPlanner: ContextBudgetPlanner
    var promptObservationBuffer = HotfixTurnObservationRingBuffer()
    var previousPromptShape: PromptShape?
    var previousSessionGroup: SessionGroup?
    var recentImageFollowUpContexts: [RecentImageFollowUpContext] = []

    // MARK: - Computed Properties

    var enabledSkillInfos: [SkillInfo] {
        skillEntries.filter(\.isEnabled).map {
            SkillInfo(name: $0.id, description: $0.description,
                     displayName: $0.name, icon: $0.icon,
                     type: $0.type, requiresTimeAnchor: $0.requiresTimeAnchor,
                     samplePrompt: $0.samplePrompt,
                     chipPrompt: $0.chipPrompt,
                     chipLabel: $0.chipLabel)
        }
    }

    var availableModels: [ModelDescriptor] {
        catalog.availableModels
    }

    // MARK: - Coordinator Convenience (Phase 3c)

    /// Model is loaded and ready to accept generation requests.
    /// Replaces UI reads of `inference.isLoaded` — driven by coordinator's
    /// validated state machine rather than raw inference-layer booleans.
    var isModelReady: Bool {
        coordinator.sessionState.canGenerate
    }

    /// A generation is in progress (coordinator has an active transaction).
    /// Replaces UI reads of `inference.isGenerating`.
    var isModelGenerating: Bool {
        coordinator.sessionState.isGenerating
    }

    // MARK: - Init

    init(
        inference: InferenceService? = nil,
        catalog: ModelCatalog? = nil,
        installer: ModelInstaller? = nil
    ) {
        // LiteRT 是 iOS-only (xcframework 没有 macOS slice)。Mac harness / CLI
        // 编译时 LiteRTLMSwift 不在作用域, 相应的 LiteRTCatalog / LiteRTBackend /
        // LiteRTModelStore 也被 SwiftPM target 配置 exclude。
        //
        // iOS 分支: 默认 fallback 创建 LiteRT 实例 (历史行为不变)。
        // 非 iOS 分支: 要求调用方必须显式注入 catalog/installer/inference,
        //              CLI 本来就总是注入, 不受影响。
        #if canImport(PhoneClawEngine)
        let resolvedCatalog: ModelCatalog = catalog ?? LiteRTCatalog()
        let resolvedInstaller: ModelInstaller = installer ?? LiteRTModelStore()
        #else
        guard let resolvedCatalog = catalog,
              let resolvedInstaller = installer else {
            fatalError("AgentEngine: non-LiteRT build requires explicit catalog + installer injection")
        }
        #endif
        self.catalog = resolvedCatalog
        self.installer = resolvedInstaller
        self.legacyContextBudgetPlanner = LegacyBudgetPlanner()
        self.hotfixContextBudgetPlanner = HotfixBudgetPlanner()
        self.toolResultCanonicalizer = LegacyToolCanonicalizer()

        if let inference {
            self.inference = inference
        } else {
            #if canImport(PhoneClawEngine)
            let liteRT = LiteRTBackend(
                modelPathResolver: { modelID in
                    guard let desc = resolvedCatalog.availableModels.first(where: { $0.id == modelID }) else { return nil }
                    return resolvedInstaller.artifactPath(for: desc)
                },
                onModelLoaded: { [weak resolvedCatalog] modelID in
                    if let cat = resolvedCatalog,
                       let desc = cat.availableModels.first(where: { $0.id == modelID }) {
                        cat.markLoaded(desc)
                    }
                },
                onModelUnloaded: { [weak resolvedCatalog] in
                    resolvedCatalog?.markUnloaded()
                }
            )

            // MiniCPM-V backend: bundleResolver 从 descriptor.companionFiles 找
            // 真实文件名 (按 CompanionRole 查), 不再硬编码命名约定。
            let miniCPMV = MiniCPMVBackend(bundleResolver: { modelID in
                guard let desc = resolvedCatalog.availableModels.first(where: { $0.id == modelID }),
                      desc.artifactKind == .ggufBundle,
                      let llmPath = resolvedInstaller.artifactPath(for: desc) else {
                    return nil
                }
                let baseDir = llmPath.deletingLastPathComponent()

                guard let mmprojCompanion = desc.companionFiles.first(where: { $0.role == .multimodalProjector }) else {
                    return nil
                }
                let mmprojCanonicalPath = baseDir.appendingPathComponent(mmprojCompanion.localResourceName)

                // Backward compat: legacy sideload name vs canonical OBS name.
                let mmprojLegacyPath = baseDir.appendingPathComponent("MiniCPM-V-4_6-mmproj-f16.gguf")
                let mmprojPath: URL
                if FileManager.default.fileExists(atPath: mmprojCanonicalPath.path) {
                    mmprojPath = mmprojCanonicalPath
                } else if FileManager.default.fileExists(atPath: mmprojLegacyPath.path) {
                    mmprojPath = mmprojLegacyPath
                } else {
                    return nil
                }

                let resolvedCoreml: URL? = desc.companionFiles
                    .first(where: { $0.role == .coreMLVisionEncoder })
                    .map { baseDir.appendingPathComponent($0.localResourceName) }
                    .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

                return MTMDPathBundle(
                    modelPath: llmPath,
                    mmprojPath: mmprojPath,
                    coremlPath: resolvedCoreml
                )
            })

            self.inference = BackendDispatcher(
                liteRT: liteRT,
                miniCPMV: miniCPMV,
                modelLookup: { modelID in
                    resolvedCatalog.availableModels.first(where: { $0.id == modelID })
                }
            )
            #else
            fatalError("AgentEngine: non-LiteRT build requires explicit inference injection")
            #endif
        }

        self.coordinator = ModelRuntimeCoordinator(
            inference: self.inference,
            installer: resolvedInstaller
        )
        self.sessionStore = ChatSessionStore()

        loadSkillEntries()
    }
}
