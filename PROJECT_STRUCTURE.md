# Project Structure

This repository is being organized in small, low-risk steps. The first pass only
moves documentation, the Mac gateway package, and standalone test harnesses. The
main Xcode app source folders are intentionally left in place to avoid noisy
`project.pbxproj` churn.

## Top-Level Layout

- `App/` - app entry point, lifecycle, and top-level composition.
- `Agent/` - local agent loop, planning, routing, prompt construction, and tool
  orchestration.
- `LLM/` - local, remote, and runtime-specific inference backends.
- `Live/` - live voice mode runtime.
- `LiveLand/` - Dynamic Island / Live Activity surface and LiveLand state flow.
- `Skills/` - skill manifests, prompts, and skill-owned tool definitions.
- `Tools/` - tool handlers, developer utilities, and SkillKit scaffolding.
- `Shared/` - shared models and utilities used across app modules.
- `UI/` - reusable SwiftUI surfaces.
- `PhoneClawCLI/` - command-line harnesses for local routing, skill, and model
  validation.
- `MacGateway/` - macOS gateway app for LAN remote inference.
- `Tests/` - Swift test package plus standalone test harnesses such as
  `Tests/AudioTest/`.
- `Docs/` - product, architecture, runtime, skill, and release documentation.
- `Experiments/` - exploratory code and research prototypes.
- `Packages/` and `LocalPackages/` - vendored or local Swift package
  dependencies.
- `Frameworks/` - binary frameworks required by the app.
- `Assets.xcassets/`, `assets/`, `ja.lproj/`, `zh-Hans.lproj/` - app assets and
  localization resources.
- `scripts/` - repository automation scripts.

## Placement Rules

- Put new documentation under `Docs/`.
- Put Mac gateway changes under `MacGateway/`; keep the built app name
  `PhoneClawGateway.app` for user-facing continuity.
- Put reusable CLI validation in `PhoneClawCLI/`.
- Put standalone or experimental test harnesses under `Tests/` or
  `Experiments/`, depending on whether they are expected to remain part of the
  verification workflow.
- Avoid adding new top-level folders unless the code has a clear long-term
  ownership boundary.

## Deferred Cleanup

The app source directories such as `Agent/`, `App/`, `LLM/`, `LiveLand/`, `UI/`,
and Xcode project references should be reorganized separately. That pass should
be done only with a clean build/test checkpoint because it will touch source
membership and Xcode project metadata.
