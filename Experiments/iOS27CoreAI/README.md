# iOS 27 Core AI Experiment

This package is an isolated research surface for iOS 27 APIs. It is intentionally not wired into `PhoneClaw.xcodeproj`.

## Goals

- Keep current PhoneClaw production runtime untouched.
- Compile on the current non-iOS-27 toolchain.
- Provide a guarded place to test Core AI and Foundation Models once Xcode 27 is installed.
- Validate routing and argument-extraction ideas before changing `AgentEngine`, `BackendDispatcher`, or `ModelRuntimeCoordinator`.

## Local Check

From this directory:

```sh
swift test
```

This only runs the portable planning-model scaffolding.

## Xcode 27 Beta Check

Once Xcode 27 beta is installed, try:

```sh
swift test -Xswiftc -DPHONECLAW_IOS27_BETA_SDK
```

If `CoreAI` or `FoundationModels` APIs shifted, fix this package first before touching the main app.

## Intended Integration Path

1. Use `PlanningModelService` as the future abstraction for Skill routing and argument extraction.
2. Try `FoundationPlanningModelService` for structured routing when Apple Intelligence is available.
3. Use `CoreAIProbe` to measure `.aimodel` load, specialization, function discovery, and cache behavior.
4. Only after benchmarks are convincing, add a production `CoreAIBackend` behind `ArtifactKind.coreAIModel`.
