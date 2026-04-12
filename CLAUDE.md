# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PhoneClaw is a fully offline iPhone AI Agent that runs Gemma 4 language models on-device via MLX. No cloud connectivity — all inference, chat history, and personal data stay on the phone. The UI and Skill definitions are in Chinese; code identifiers are in English.

## Build & Run

```bash
pod install                        # install CocoaPods deps (Yams for YAML parsing)
open PhoneClaw.xcworkspace         # always .xcworkspace, never .xcodeproj
# Xcode: select PhoneClaw target → set Team & Bundle ID → ⌘R on a real device
```

- **iOS 17+**, **Xcode 16**, **Swift 6.1+**
- Must run on physical device (A16+). Simulator cannot run MLX inference.
- Models are either downloaded on-device at runtime (default) or bundled via `Build Phases > Copy Bundle Resources`. The `Models/` directory is gitignored.
- CocoaPods only pulls **Yams**. MLX dependencies come via SPM through the local `Packages/InferenceKit/` package (a slimmed fork of mlx-swift-lm keeping only MLXLLM, MLXVLM, MLXLMCommon).

## Architecture

### 5-Path Routing (ADR-001)

`AgentEngine.processInput` routes every user message into one of five paths:

| Path | When | LLM calls |
|------|------|-----------|
| **VLM** | Image or audio attached | 1 (vision/audio model) |
| **Planner** | Multiple skills match | 2 (selection → planning) |
| **Preflight** | Heuristic regex extracts tool args directly | 0 (<100ms) |
| **Agent** | Single skill matched | 1+ (tool chain loop) |
| **Light** | No skill triggers, pure chat | 1 (no skill context injected) |

This split is deliberate — small on-device models (2B–4B) can't reliably run a unified ReAct loop. See `doc/architecture-decisions.md` for the full ADR set.

### Skill System (file-driven)

Each Skill is a `SKILL.md` with YAML frontmatter in `Skills/Library/<id>/`. Users can override at runtime via `Application Support/PhoneClaw/skills/<id>/SKILL.md`.

- **`type: device`** — calls native iOS APIs via tool_call; only fires on explicit user request
- **`type: content`** — pure prompt transformation (translate, summarize); no tools

`SkillLoader` parses frontmatter (triggers, allowed-tools, type). `SkillRegistry` holds loaded skills. `Router` matches user input against trigger keywords; sticky routing keeps context across turns.

### Tool System

`Tools/ToolRegistry.swift` holds a flat registry of `RegisteredTool` structs. Each domain registers via a static `register(into:)` method in `Tools/Handlers/<Domain>.swift` (Calendar, Reminders, Contacts, Clipboard, Health).

`ToolChain` executes the loop: LLM emits `<tool_call>` → `ToolCallParser` extracts it → registry dispatches → result fed back → repeat until `parseToolCall() == nil` or maxRounds (ADR-002).

Heuristic argument extraction (`heuristicArgumentsForTool`) lives in Swift, not YAML — these are hand-tuned Chinese regexes that skip the LLM entirely for common patterns (ADR-006).

### LLM Layer

`LLM/MLX/MLXLocalLLMService.swift` wraps Gemma 4 E2B/E4B inference. Key behaviors:
- Dynamic memory budgeting based on actual device memory (no hardcoded prompt cutoffs)
- Cross-turn KV cache reuse for faster follow-up responses
- GPU lifecycle managed via Metal (`GPULifecycle.swift`)
- Prompt formatting uses Gemma 4 turn markers: `<|turn>role\n...<turn|>` (see `PromptBuilder.swift`)

### Adding a New Tool

1. Create `Tools/Handlers/<Name>.swift` with a static `register(into:)` method
2. Call it from `ToolRegistry.registerBuiltInTools()`

### Adding a New Skill

1. Create `Skills/Library/<skill-id>/SKILL.md` with YAML frontmatter (name, triggers, allowed-tools, type, examples)
2. Register in `SkillRegistry.registerBuiltIn(id:)` — the framework auto-validates that `allowed-tools` entries exist in `ToolRegistry`

## Key Design Decisions

- **Capability flags over model IDs** (ADR-005): Branch on `supportsStructuredPlanning` etc., not hardcoded model names
- **Two-step planning** (ADR-003): Selection and Planning are separate LLM calls ("external CoT") for reliability with small models
- **E2B doesn't auto-chain** (ADR-004): When multiple skills match, execute the first and clarify — 2B can't reliably pass params between steps
- **No test target**: Testing is manual on-device. No unit test suite exists.

## Entitlements

The app requests: Calendar, Reminders, Contacts, Microphone, HealthKit (read-only). The `com.apple.developer.kernel.increased-memory-limit` entitlement is required for LLM inference.
