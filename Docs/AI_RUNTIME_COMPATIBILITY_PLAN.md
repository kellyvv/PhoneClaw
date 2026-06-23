# AI Runtime Compatibility Plan

This plan keeps PhoneClaw compatible across current systems while adopting newer Apple AI APIs incrementally. Product code should depend on PhoneClaw contracts (`InferenceService`, `SkillRegistry`, `ToolRegistry`, `PhoneGroundToolContract`), not on a specific model framework or OS version.

## Current Runtime Baseline

The production runtime today is:

- `InferenceService` as the existing model execution abstraction.
- `LiteRTBackend` for Gemma 4 `.litertlm` models.
- `MiniCPMVBackend` for MiniCPM-V GGUF multimodal/live scenarios.
- `RemoteInferenceService` for the LAN Mac/OpenAI-compatible gateway.
- `BackendDispatcher` to select LiteRT, MiniCPM-V, or Remote by `ModelDescriptor.artifactKind`.
- `SkillRegistry`, `ToolRegistry`, `PromptBuilder`, `Router`, and `ToolChain` as the agent orchestration layer.
- `PhoneGroundToolContract` as the evidence/answer contract between tools and answer synthesis.

MLX files still exist in the repository, but `BackendDispatcher` does not route to MLX. `.mlxDirectory` is currently an unsupported artifact kind, so MLX is not part of this compatibility plan unless it is intentionally restored later.

## Apple API Availability Model

Do not treat the whole Foundation Models stack as iOS 27-only.

- Foundation Models is a base framework available before iOS 27 for `LanguageModelSession`, guided generation, transcripts, and tool concepts.
- iOS 27 adds or expands higher-level capabilities such as provider protocols, Dynamic Profiles, Private Cloud Compute, model/provider swapping, and newer context options.
- Core AI is an iOS/macOS 27 model deployment path and must remain isolated until benchmarks prove value.

The implementation rule is feature-gating, not framework-gating:

```swift
#if canImport(FoundationModels)
if #available(iOS 26.0, *) {
    // APIs available in the base Foundation Models framework.
}
if #available(iOS 27.0, *) {
    // Dynamic Profiles, PCC, provider protocol, or Core AI integration points.
}
#endif
```

Exact availability must be checked against the SDK at implementation time. Keep all imports behind `#if canImport(...)`.

## Target Shape

Do not introduce a parallel `AIProvider` or `ModelRuntime` protocol for production. `InferenceService` is already the app's model execution boundary.

Target adapters:

```text
InferenceService
  LiteRTBackend                         existing
  MiniCPMVBackend                       existing
  RemoteInferenceService                existing
  FoundationModelsInferenceService      SDK-gated adapter
  CoreAIInferenceService                future adapter, SDK-gated

Agent contracts
  SkillContract                         activation, side effects, permission, progress
  ToolContract                          schema, allowlist, execution, evidence
  ContextPolicy                         transcript/history/cache behavior
  PromptPack                            prompt/guided-generation shape

Evaluation surfaces, not runtime
  CLI scenarios
  golden prompt fixtures
  provider matrix checks
  Apple Evaluations where available on macOS CI
```

This keeps `AgentEngine` and LiveLand listening to one stable runtime shape while allowing iOS 26/27 APIs to be adapters.

## Compatibility Matrix

| Capability | New Apple path | Existing path | Required contract |
|------------|----------------|---------------|-------------------|
| Text agent | Foundation Models adapter where available | LiteRT | `InferenceService` |
| Live/Vision | Foundation Models image prompts or Core AI when proven | MiniCPM-V, LiteRT | `InferenceService` + media capability flags |
| Tool calling | Foundation Models tools/guided generation | Current XML/JSON tool calls | `ToolRegistry` + `ToolContract` |
| Skill activation | Skills/Dynamic Profiles where available | PromptBuilder preloaded skill blocks | `SkillContract` |
| Context trimming | Dynamic Profile history modifiers where available | PromptBuilder/history trim | `ContextPolicy` |
| Remote model bridge | `LanguageModel`/chat-completions adapter where available | `RemoteInferenceService` | `InferenceService` |
| Evaluation | Apple Evaluations on macOS CI, Python SDK probes | CLI scenarios/golden prompts | `EvaluationPlan`, not runtime |
| Siri/App exposure | App Intents schemas, entities, View Annotations | Existing AppIntents/Shortcuts | `AppExposureContract` |

## Provider Selection

Provider choice should remain capability-driven:

```text
Request
  -> required capabilities
  -> available model adapters on this OS/device
  -> privacy and permission policy
  -> selected InferenceService backend
```

Suggested initial order:

### iOS 27+

1. Foundation Models adapter for structured routing/extraction where Apple Intelligence is available.
2. Core AI adapter for packaged `.aimodel` experiments after benchmarks and memory checks.
3. LiteRT as stable fallback.
4. MiniCPM-V for current vision/live behavior.
5. Remote for LAN or high-performance fallback.

### iOS 26 / Non-iOS 27

1. Foundation Models adapter only for APIs available on that OS and feature flag.
2. LiteRT.
3. MiniCPM-V.
4. Remote.

## Runtime Availability Rules

Do not scatter `if #available(...)` through business logic.

Use these boundaries instead:

- Files that import `FoundationModels` or `CoreAI` must be isolated behind `#if canImport(...)`.
- Public app logic receives capability flags, not framework-specific types.
- Feature flags must guard experimental adapters.
- Legacy fallback must remain available when Apple Intelligence is unavailable, disabled, or not ready.
- Apple Evaluations is a test/CI surface. It must not appear in iOS runtime selection.

## Migration Phases

### Phase 1: Describe Existing Runtime

- Add `SkillContract` documentation and generator scaffolding.
- Keep `InferenceService` intact.
- Convert the Foundation Models router prompt to registry-driven candidates.
- Add focused tests that prevent hardcoded skill/tool lists from returning.

### Phase 2: Adapter Inventory

- Document existing `InferenceService` capabilities for LiteRT, MiniCPM-V, and Remote.
- Record capability flags: text, image, audio, live mode, guided generation, max context, privacy mode.
- Keep UI and `AgentEngine` behavior unchanged.

### Phase 3: Foundation Models Adapter

- Keep the feature-gated `FoundationModelsInferenceService` on the existing `InferenceService` boundary.
- Keep routing and structured extraction on runtime schemas before expanding deeper planning contracts.
- Keep runtime schemas such as `DynamicGenerationSchema` for runtime skill/tool candidate constraints when the SDK supports them.
- Compare output with existing CLI golden scenarios.
- Do not move LiveLand production voice to a separate Foundation Models live token source until latency, cancellation, and recovery match the current persistent Live path.

### Phase 4: Contract-Driven App Exposure

- Map `SkillContract` to App Intents schemas/entities where possible.
- Add View Annotation mapping only after entity ownership and privacy rules are explicit.
- Add App Intents integration tests for Siri/Shortcuts/Spotlight paths.

## Non-Goals For This Branch

- Replacing LiteRT as the default runtime.
- Restoring MLX as a production backend.
- Creating a second model-provider abstraction beside `InferenceService`.
- Moving LiveLand to a separate Foundation Models live token source.
- Shipping Core AI `.aimodel` runtime before benchmarks and device memory checks exist.

## Acceptance Criteria

- The current app still builds without unguarded iOS 26/27 SDK imports in normal files.
- Foundation Models routing consumes registry-driven skill candidates.
- New Skill/Prompt/Runtime docs describe contracts that can be tested.
- SkillKit can validate a draft manifest and generate SKILL.md skeletons into a temp directory without overwriting existing files by default.
- Legacy LiveLand skill progress remains model-provider agnostic.
