# Skill Contract V2

`SKILL.md` is currently both documentation and prompt material. Skill Contract V2 makes the machine-readable contract explicit so routing, prompt building, App Intents, LiveLand progress, and Foundation Models/Core AI adapters can all consume the same source of truth.

## Goals

- Keep Skill behavior data-driven.
- Prevent SDK-specific branches from hardcoding skill names or tools.
- Separate user-facing instructions from execution permissions.
- Make prompt activation, tool access, grounding, history, and UI progress testable.
- Preserve the existing `SKILL.md` workflow while adding a generator path.

## Contract Shape

```yaml
id: health
display_name:
  zh: 健康
  en: Health
type: device
version: 2
availability:
  os: all
  requires_apple_intelligence: false
activation:
  mode: prompt
  lifetime: turn
  allows_deactivation: true
routing:
  triggers:
    - 今天运动情况
    - 步数
  examples:
    - query: 今天运动情况怎么样
      expected_skill: health
tools:
  allowed:
    - health-activity-summary
    - health-query
    - health-report
permissions:
  scopes:
    - health_read
side_effects:
  level: read
grounding:
  evidence_types:
    - health
  answer_contract: groundedDataSummary
  freshness: userScopedData
progress:
  accepted: 已收到，正在理解
  executing: 正在读取健康数据
  summarizing: 正在整理结果
history:
  keep_active_skill: true
  drop_completed_tool_calls: true
  summarize_old_evidence: true
  preserve_pending_clarification: true
prompts:
  pack: health.v1
```

## Required Fields

| Field | Meaning |
|-------|---------|
| `id` | Stable directory and runtime identifier. |
| `type` | `device`, `content`, or `network`. |
| `routing.triggers` | Primary deterministic route signals. |
| `tools.allowed` | Tool allowlist. Empty means content-only skill. |
| `activation.mode` | `prompt`, `instructions`, or `none`. |
| `side_effects.level` | `none`, `read`, `write`, or `destructive`. |
| `grounding.answer_contract` | How answer synthesis must treat tool output. |
| `progress` | Generic LiveLand phase copy. |

## Activation Policy

Apple's Foundation Models utilities distinguish prompt-based skill activation from instructions-based activation. PhoneClaw should mirror that distinction without coupling the contract to one OS version:

| Mode | Use when | Runtime behavior |
|------|----------|------------------|
| `prompt` | Read-only or low-risk tasks | Inject skill content as a tool/output-like prompt block when possible. |
| `instructions` | Device writes, destructive operations, strict policy | Inject into high-priority system/instructions block. |
| `none` | Pure router-only or native-only capability | Do not inject skill prose. |

The existing preloaded skill block in `PromptBuilder` is a Phase 1 implementation of `prompt` activation. A future Foundation Models adapter can map the same policy to Skills or Dynamic Profiles when the active OS and SDK support them.

## Side Effect Policy

| Level | Examples | Requirements |
|-------|----------|--------------|
| `none` | Translate | No native permission required. |
| `read` | Health query, calendar query, clipboard read | Permission and evidence metadata required. |
| `write` | Calendar create, reminder create, contact update | Permission, explicit user intent, and progress events required. |
| `destructive` | Delete contacts, clear data | Confirmation policy required. |

Tool execution must never be granted by prompt text alone. The allowlist in `ToolRegistry` remains the enforcement boundary.

## Grounding Policy

`PhoneGroundToolContract` should remain the minimal runtime contract for tool outputs, but Skill Contract V2 should own the higher-level policy:

- which evidence types are expected
- whether freshness is required
- whether answer repair is allowed
- whether missing permission/data should be surfaced in final answer
- whether LiveLand should show query/read/process copy

## History Policy

Each skill should declare how it participates in multi-turn context:

- `keep_active_skill`: preserve this skill for short follow-up turns.
- `drop_completed_tool_calls`: remove old activation/tool-call scaffolding when safe.
- `summarize_old_evidence`: retain only compact summaries for old evidence.
- `preserve_pending_clarification`: keep missing-parameter state until resolved.

This is the legacy-runtime equivalent of Dynamic Profile history modifiers.

## Prompt Pack Binding

The contract should not embed all prompt text. It should reference a prompt pack:

```yaml
prompts:
  pack: calendar.v2
  locale: zh-Hans
```

Prompt packs own wording, examples, output format, and repair strategies. Skill contracts own permission, tool, route, and progress semantics.

## Compatibility With Current SKILL.md

Phase 1 keeps existing `SKILL.md` frontmatter valid. SkillKit should generate current files from a richer manifest:

```text
skill.json
  -> SKILL.md
  -> SKILL.en.md
  -> SKILL.ja.md
  -> CLI scenario skeleton
  -> prompt fixture skeleton
```

The app continues to load `SKILL.md` until a runtime parser for Skill Contract V2 is introduced.

## Acceptance Criteria

- A new skill can be described once and generate localized `SKILL.md` skeletons.
- The Foundation Models router can build its candidate list from `SkillRegistry` and `ToolRegistry`.
- LiveLand copy is derived from contract metadata or `PhoneGroundToolContract`, not per-skill UI code.
- Tests prevent unknown tools or disabled skills from being selected by model-driven routing.
