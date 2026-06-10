# iOS 27 Core AI Research Plan

> Branch: `codex/ios27-core-ai-research`
>
> Status: research plan, not a production migration.
>
> Date: 2026-06-10

## Objective

Research whether iOS 27 APIs can improve PhoneClaw's multi-model runtime without weakening its current offline-first product model.

The target outcome is a staged technical path for:

- running custom on-device models through Core AI when it is better than LiteRT / GGUF / MLX,
- using Foundation Models as a lightweight structured routing and agent session layer,
- measuring memory, specialization, and termination behavior with the new diagnostics stack.

This branch should not replace the existing LiteRT, MiniCPM-V, or Mac remote inference paths until benchmarks prove a clear win.

Current implementation focus: iOS 27 native APIs that PhoneClaw can use directly and measure safely. The active production-facing path is `FoundationModels` for availability checks, prewarming, structured routing, deterministic generation options, context options, metadata, and token-usage diagnostics. This is an automatic internal capability, not a user-facing setting. `ENABLE_IOS27_FOUNDATION_ROUTER=0` remains only as an engineering kill switch. Automatic creation or editing of the user's Apple Shortcuts is out of scope for this branch because it is not a dependable public API path.

## Official API Baseline

Sources checked on 2026-06-09:

- iOS 27 overview: <https://developer.apple.com/ios/whats-new/>
- Core AI: <https://developer.apple.com/documentation/coreai/>
- Foundation Models: <https://developer.apple.com/documentation/foundationmodels>
- Apple Intelligence overview: <https://developer.apple.com/apple-intelligence/>
- iOS & iPadOS 27 beta release notes: <https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes>

## True-Device Findings

Test device: iPhone 17 Pro Max (`iPhone18,2`) on iOS 27.0.

Probe app: `Experiments/iOS27CoreAIProbeApp`.

Findings on 2026-06-09:

- `FoundationModels` module is present on device.
- `SystemLanguageModel.default.availability` reports `available`.
- `LanguageModelSession.respond(to:)` returns a real response on device.
- `CoreAI` module is present on device.
- `AIModel.deviceArchitectureName` reports `h18p`.
- One simple `LanguageModelSession` response took roughly 2.3 seconds in the first visible manual run.
- Prompt adherence needs deeper testing: a simple instruction asking the model to mention PhoneClaw returned a generic sentence instead.
- A raw JSON router prompt correctly selected `calendar` / `calendar-create-event` for `明天下午两点帮我安排产品评审会议`; the visible manual run took roughly 2.3 seconds.
- The raw JSON router still wrapped its answer in a Markdown code fence despite explicit "no Markdown" instructions, so production code must use structured generation or strict JSON extraction and validation.
- Xcode 27 SDK exposes `@Generable`, `@Guide`, and `LanguageModelSession.respond(to:generating:)`; the probe app includes a guided route test and builds successfully against `iphoneos27.0`.
- The first guided route run returned valid typed output but chose `answerDirectly` / `null` for a calendar scheduling request. Structured generation fixes output shape, not semantic policy. The probe now uses stricter action definitions and reports a `Guided validation` pass/fail line.
- With stricter policy, the guided route test selected `useSkill` / `calendar` / `calendar-create-event` for the same scheduling request and passed validation. The manual run used 603 input tokens, 51 output tokens, 654 total tokens, and took roughly 2.7 seconds.
- The first route matrix run passed 3/5: calendar, reminder, and translate passed; direct-answer and clarification failed. Token counts increased from 765 to 2750 because the matrix reused one `LanguageModelSession`, so later cases were polluted by transcript history.
- The route matrix now uses a fresh `LanguageModelSession` per case and labels the run as `stateless sessions`, which is the correct default for PhoneClaw request routing.
- The stateless route matrix also passed 3/5. Token counts stabilized around 754-770, confirming history contamination was fixed; remaining failures were semantic policy failures: `解释一下什么是本地模型` was incorrectly routed to translate, and a meeting request without date/time was incorrectly routed to calendar creation instead of clarification.
- The probe app now includes a guarded route matrix: deterministic rules handle non-tool explanation requests and missing calendar date/time before falling back to Foundation Models for structured skill selection.
- The first guarded route matrix passed 4/5. Explanation and missing-calendar-info cases were correctly handled by rules, but the calendar case failed because the model treated `明天下午两点` as insufficient date/time information. The guarded router now handles calendar intent plus relative date/time signals as a deterministic calendar route before invoking the model.
- With deterministic calendar intent plus relative date/time signal handling, the guarded route matrix passed 5/5. Calendar, direct-answer, and clarification cases were resolved by rules; reminder and translate fell back to Foundation Models and passed with roughly 917-928 total tokens each.
- The main PhoneClaw branch now has a minimal guarded pre-router between SKILL.md trigger matching and the existing network intent router. It is controlled by `ENABLE_GUARDED_SKILL_ROUTER`, defaults on for this branch, and does not import Foundation Models into the production target.
- Xcode console shows beta system instrumentation noise around Biome / `GenerativeModels.GenerativeFunctions.Instrumentation`; it did not prevent model response.

### Core AI

Core AI is still the most relevant new runtime candidate, but the local iPhoneOS 27 SDK currently exposes only a thin readable `CoreAI.swiftinterface` from the public framework and prebuilt modules for the deeper runtime pieces. The true-device probe confirms `import CoreAI` and `AIModel.deviceArchitectureName`, but the production app should not depend on unverified CoreAI runtime types yet.

PhoneClaw implication: Core AI should be evaluated first for small and medium specialized models: router, argument extractor, OCR, embedding, reranker, speech/vision encoders, and small local language models. Replacing the main Gemma LiteRT path is a later decision, not the first experiment.

### Foundation Models

iOS 27 broadens Foundation Models into a higher-level Swift agent layer:

- `LanguageModel` protocol provider abstraction,
- `LanguageModelSession`,
- Apple Foundation Models on device,
- Private Cloud Compute model access where available,
- third-party or custom providers conforming to `LanguageModel`,
- multimodal prompts,
- Dynamic Profiles for swapping models, tools, and instructions inside a continuous session,
- guided generation with `@Generable`,
- tool calling,
- Vision framework tools such as OCR and barcode readers callable by the model,
- Evaluations framework and Instruments profiling.

PhoneClaw implication: Foundation Models is a strong fit for router and structured planning experiments, especially where PhoneClaw currently relies on the main chat model to choose Skills or extract parameters. It should not be treated as always available: Apple Intelligence support, regional availability, model download state, and user settings must all gate usage.

Production branch status: PhoneClaw now has an automatic `IOS27FoundationSkillRouter` fallback layer between deterministic guarded routing and the existing E2B model-intent router. It uses `SystemLanguageModel.default.availability`, `LanguageModelSession.prewarm()`, `@Generable` structured output, `GenerationOptions`, `ContextOptions`, request metadata, and `LanguageModelSession.Response.usage` for token accounting. The layer is guarded by `#if canImport(FoundationModels)` and `#available(iOS 27.0, *)`, and it only attempts routing for skill-like text so ordinary chat does not pay the extra local-model routing cost. iOS 17-26 devices continue to use the existing path.

### App Intents and Shortcuts

iOS 27 App Intents adds stronger schemas and Siri / Apple Intelligence integration:

- entity schemas for Spotlight semantic indexing,
- intent schemas for natural-language actions,
- View Annotations API for on-screen awareness,
- App Intents Testing framework,
- Shortcuts natural-language automation assembly using app actions.

PhoneClaw implication: every stable device Skill should have an App Intent representation. This makes PhoneClaw actions visible to Siri, Spotlight, and Shortcuts. It still does not imply that PhoneClaw can silently CRUD arbitrary user shortcuts; the practical path is to expose actions well enough that Shortcuts and Siri can assemble workflows from natural language.

### MetricKit

iOS 27 adds useful diagnostics:

- Swift-first `MetricManager`,
- `MemoryExceptionDiagnostic`,
- termination category information,
- developer-defined state reporting integration,
- Metal frame pacing metrics.

PhoneClaw implication: model load, generation, Live mode, backend switch, and Core AI specialization should emit state markers so MetricKit reports can be tied to actual runtime phases.

## Architecture Proposal

### Keep the Existing Runtime Boundary

Current PhoneClaw already has the right top-level seams:

- `ModelDescriptor`
- `ArtifactKind`
- `InferenceService`
- `BackendDispatcher`
- `ModelRuntimeCoordinator`
- `RuntimePolicy`

The research branch should extend these concepts instead of creating a second runtime stack.

Proposed future enum additions, gated behind SDK availability:

```swift
public enum ArtifactKind: String, Sendable {
    case litertlmFile
    case ggufBundle
    case remoteEndpoint
    case mlxDirectory
    case coreAIModel       // .aimodel or compiled Core AI assets
    case foundationModel   // system/provider model with no local file ownership
}
```

Do not add these cases in production code until the iOS 27 SDK is actually available in the local build environment and the compiler gates are known.

### Add a Planning Model Layer

Create a small abstraction above the heavy chat model:

```swift
protocol PlanningModelService {
    func route(_ input: PlanningInput) async throws -> PlanningDecision
    func extractArguments<T: Decodable>(_ input: PlanningInput, as type: T.Type) async throws -> T
}
```

Candidate implementations:

- `FoundationPlanningModelService`: uses `LanguageModelSession` and `@Generable`.
- `CoreAIPlanningModelService`: uses a small `.aimodel` classifier / extractor.
- `FallbackPlanningModelService`: current PhoneClaw main-model path.

This layer should be used for Skill routing, multi-step plan shape, and argument extraction before changing the full text generation path.

### Add Core AI as a Backend Candidate

First Core AI backend should be intentionally narrow:

- load a known `.aimodel`,
- run one inference function,
- measure first-run specialization time,
- measure cached load time,
- measure peak memory and output latency,
- unload cleanly.

Only after the narrow spike works should it conform to `InferenceService`.

Proposed eventual shape:

```swift
final class CoreAIBackend: InferenceService {
    func load(modelID: String) async throws
    func unload()
    func generate(prompt: String) -> AsyncThrowingStream<String, Error>
}
```

If using `CoreAILanguageModel` from Apple's model packages, prefer adapting it through Foundation Models' `LanguageModelSession` before forcing it into PhoneClaw's token-streaming protocol.

### Model Installation and Assets

Core AI changes the install story:

- source artifact: `.aimodel`,
- optional compiled artifacts from `coreai-build`,
- on-device specialization cache: `AIModelCache`,
- optional on-demand delivery through Background Assets.

Research needs to answer:

- whether compiled assets are device-family-specific enough to require per-device packaging,
- whether app-bundled compiled assets are App Store friendly for the target model sizes,
- whether Background Assets is a better fit than the current downloader for large optional `.aimodel` files,
- how `AIModelCache` storage should be surfaced in PhoneClaw's model settings UI.

### App Intents Bridge

Add a generator or hand-written bridge from stable Skills to App Intents:

- one generic `RunPhoneClawCommandIntent` for natural-language commands,
- one explicit App Intent per stable Skill family where system composition benefits from typed parameters,
- App Entity definitions for reusable user content where PhoneClaw owns or indexes it,
- App Intents tests for Siri / Shortcuts pathways.

This is the correct path for the user's "natural language creates shortcut-like automation" goal: expose PhoneClaw actions richly, then let Shortcuts / Siri assemble flows from those actions.

## Research Phases

### Phase 0: Environment Gate

Goal: make the branch compile on non-iOS-27 environments while allowing iOS 27 experiments.

Tasks:

- install Xcode 27 beta on a separate machine or local toolchain slot,
- identify exact Swift compiler and availability gates,
- use `#if canImport(CoreAI)` and runtime availability checks,
- keep the default app target building with the current iOS 17+ path,
- document all beta SDK assumptions in this file.

Exit criteria:

- no production build breaks without Xcode 27,
- at least one iOS 27-only experimental target or file compiles under Xcode 27.

### Phase 1: Core AI Smoke Test

Goal: validate real Core AI runtime behavior on iPhone.

Tasks:

- choose one tiny Core AI model from Apple's sample/model repository or convert a small PyTorch model,
- load it through `AIModel`,
- run one `InferenceFunction`,
- test `AIModelCache`,
- test explicit specialization,
- test AOT compiled asset from `xcrun coreai-build compile MyModel.aimodel --platform iOS`,
- capture cold load, warm load, inference latency, and memory.

Exit criteria:

- a repeatable benchmark note with cold/warm numbers,
- a decision on whether Core AI is suitable for PhoneClaw small models.

### Phase 2: Foundation Models Router Spike

Goal: reduce main-model usage for routing and parameter extraction.

Tasks:

- define `@Generable` structs for `SkillRoute`, `ToolArguments`, and `PlanStep`,
- implement one isolated `FoundationPlanningModelService`,
- compare it against current Router behavior on existing golden prompts,
- handle availability cases:
  - device not eligible,
  - Apple Intelligence disabled,
  - model not ready,
  - unsupported language or locale,
  - context window exceeded.

Exit criteria:

- pass/fail matrix on existing router fixtures,
- fallback behavior verified,
- measured latency and token usage.

Initial status:

- raw JSON true-device smoke passed for one calendar routing prompt,
- guided generation compiles in the iOS 27 probe app and is ready for true-device validation,
- prompt-only JSON is not reliable enough by itself because the model can still emit Markdown wrappers,
- guided generation also needs explicit routing policy and deterministic post-validation before production use,
- one strict guided calendar route has passed,
- a stateful route matrix passed 3/5 but exposed session-history contamination,
- a stateless pure-model route matrix also passed 3/5, confirming deterministic pre-routing is needed for production,
- a guarded route matrix passed 4/5 and exposed the need for deterministic relative-date handling,
- a guarded true-device route matrix with deterministic calendar date/time signal detection passed 5/5,
- the next gate is a minimal PhoneClaw Router integration that uses rules first and keeps Foundation Models optional/fallback-gated.

### Phase 3: Core AI Backend Prototype

Goal: determine whether Core AI can fit PhoneClaw's backend model.

Tasks:

- add experimental `ArtifactKind.coreAIModel` behind compiler gating,
- add a `CoreAIBackend` prototype in an experiments folder or build flag,
- route one model through `BackendDispatcher`,
- verify `ModelRuntimeCoordinator` state transitions still hold,
- test unload and backend switch behavior,
- collect memory and MetricKit diagnostics.

Exit criteria:

- one Core AI model can be selected and run in a dev build,
- no memory overlap during backend switching,
- clear recommendation: adopt, defer, or reject for each model class.

### Phase 4: App Intents and Shortcuts Prototype

Goal: make PhoneClaw Skills first-class system actions.

Tasks:

- add `RunPhoneClawCommandIntent`,
- add explicit intents for Calendar, Reminders, Clipboard, Health, and Web if stable enough,
- define intent schemas and parameter summaries,
- test Siri invocation,
- test Shortcuts natural-language assembly,
- add App Intents Testing coverage where available.

Exit criteria:

- Siri can invoke a PhoneClaw Skill without opening the chat UI first,
- Shortcuts can discover and compose PhoneClaw actions,
- manual shortcut editing is reduced to trigger selection and confirmation where iOS requires it.

### Phase 5: Product Decision

Goal: decide what ships.

Decision matrix:

| Area | Adopt if | Defer if |
|---|---|---|
| Core AI small models | lower memory or latency than current alternatives | SDK churn, poor model availability, weak tooling |
| Core AI main LLM | streaming, KV/state, memory, and quality beat LiteRT | conversion is fragile or slower |
| Foundation router | better tool routing and parameter extraction with acceptable fallback | availability too limited |
| App Intents | Siri/Shortcuts reliability is high | schemas cannot express required Skill behavior |
| MetricKit | diagnostics map cleanly to runtime phases | reports are too delayed or sparse |

## Benchmark Plan

Measure all experiments on the same device class where possible.

| Metric | Why it matters |
|---|---|
| Cold specialization time | first-run UX for downloaded models |
| Warm load time | model switching UX |
| Peak memory | jetsam risk |
| Steady memory after unload | leak / cache pressure |
| Time to first token or first output | perceived latency |
| Tokens per second / outputs per second | sustained quality of experience |
| Energy impact | Live mode and background automations |
| Failure mode | fallback quality |

Every benchmark should record:

- device model,
- iOS build,
- Xcode build,
- model artifact hash and size,
- backend,
- compute unit selection,
- cold or warm cache state,
- PhoneClaw feature flag set.

## Risks

- iOS 27 is beta; APIs and behavior can change.
- Core AI model conversion may be easy for samples but hard for Gemma/MiniCPM-like production models.
- Apple Intelligence and Foundation Models availability is not guaranteed for all users.
- Private Cloud Compute is not a fit for PhoneClaw's default offline promise unless explicitly opt-in.
- AOT compiled assets may complicate distribution across device families.
- Background Assets may require a separate install UX from PhoneClaw's current downloader.
- App Intents improves natural-language composition, but does not remove all iOS confirmation requirements.

## Recommended First PRs on This Branch

1. Add this research plan and keep it updated as findings land.
2. Add an `Experiments/iOS27CoreAI/` folder or Swift package target that is excluded from normal builds. Done in this branch.
3. Add compiler-gated skeletons. Done in this branch:
   - `PlanningModelService`
   - `FoundationPlanningModelService`
   - `CoreAIProbe`
4. Add benchmark logging helpers that reuse `PCLog` and state names from `ModelRuntimeCoordinator`.
5. Only after the probes are stable, consider production-facing enum additions.

## Initial Recommendation

Treat Core AI as the new preferred path for custom on-device specialized models, not as an immediate replacement for the existing main LLM runtime.

Treat Foundation Models as a structured planning and provider abstraction layer, especially for Skill routing and argument extraction.

Treat App Intents as the system automation bridge for PhoneClaw Skills.

Keep LiteRT and MiniCPM-V as the stable production path until iOS 27 APIs prove better on real devices.
