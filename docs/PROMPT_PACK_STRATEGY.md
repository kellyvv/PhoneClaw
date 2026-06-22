# Prompt Pack Strategy

PhoneClaw already has strong prompt scaffolding in `PromptBuilder`: locked abilities, compact tool schemas, tool allowlists, argument extraction, web answer repair, and Live voice prompts. Prompt Pack Strategy turns that implementation into named, versioned contracts that can be tested across LiteRT, MiniCPM-V, Remote, and future Foundation Models/Core AI adapters.

## Problems To Solve

- Prompt logic is currently centralized but large.
- Some prompts are framework protocols, while others are skill behavior instructions.
- Foundation Models guided generation needs structured schemas, while legacy runtimes still need text/JSON/XML prompts.
- Prompt changes can regress routing, tool selection, or grounded answers without obvious compile failures.

## Prompt Pack Types

| Pack | Purpose | Output |
|------|---------|--------|
| `IntentRoutingPrompt` | Decide whether a request needs a skill. | `answerDirectly` or `useSkill(skillID)`. |
| `SkillActivationPrompt` | Activate one or more matched skills. | System/prompt block. |
| `ToolSelectionPrompt` | Choose one tool from an allowed set. | Tool name + arguments or clarification. |
| `ArgumentExtractionPrompt` | Extract arguments for a known tool. | JSON object only. |
| `ClarificationPrompt` | Ask for missing required data. | One user-facing question. |
| `AnswerSynthesisPrompt` | Turn tool results into final answer. | User-facing text. |
| `GroundedAnswerRepairPrompt` | Repair missing citations/evidence. | User-facing grounded answer. |
| `NoSkillGatePrompt` | Classify low-value/no-op chatter. | `none` or `accepted`. |
| `LiveLandProgressPrompt` | Map runtime phase to UI text. | Event metadata, not final answer. |

## Prompt Pack Contract

Every prompt pack should declare:

```yaml
id: argument-extraction.v1
owner: Agent/PromptBuilder
inputs:
  - user_question
  - tool_name
  - tool_parameters
outputs:
  format: json
  schema: tool_arguments
providers:
  legacy_text: true
  foundation_models_guided: true
tests:
  - fixture: health-query-steps-today
  - fixture: calendar-create-missing-title
```

## Legacy And Foundation Models Mapping

| Semantic task | Legacy runtime | Foundation Models path |
|---------------|----------------|----------------|
| Structured route | Text prompt + parser | `@Generable` or `DynamicGenerationSchema` |
| Tool selection | Text prompt + allowlist check | Runtime schema + allowlist check |
| Argument extraction | JSON-only prompt | Guided generation where available |
| Skill activation | Preloaded skill block | Skills/Dynamic Profile activation where available |
| History trimming | PromptBuilder/history trim | Profile modifiers where available |

The runtime output must still pass PhoneClaw validation. Structured output improves shape, but it does not replace `ToolRegistry` and `SkillRegistry` checks.

The registry-driven Foundation Models router now uses a runtime schema built from `DynamicGenerationSchema` with `anyOf` choices generated from the active `SkillRegistry` and `ToolRegistry`, so invalid skill IDs and tool names are constrained before generation. The runtime output still goes through local allowlist validation because schema shape does not replace PhoneClaw's registry contracts.

## Progressive Disclosure Rules

1. Start with a compact skill list.
2. If deterministic routing matches a skill, inject only that skill.
3. If a skill has tools, inject only its allowed tools.
4. If a tool is known, ask only for that tool's arguments.
5. If data is missing, ask one clarification question.
6. After tool execution, synthesize from canonical results and evidence.
7. Drop completed tool-call scaffolding from future context when safe.

This mirrors the current `PromptBuilder.PreloadedSkill` behavior while making it explicit and testable.

## Prompt Versioning

Prompt changes should use semantic versions:

- Patch: wording-only changes that keep inputs/outputs stable.
- Minor: new examples, new optional input, or broader supported provider.
- Major: changed output shape, changed activation policy, or changed validation rules.

Golden fixtures should record prompt pack IDs so regressions can be traced to a prompt contract.

## Evaluation Strategy

Use three layers:

- Unit tests for static contracts: no unknown tools, no hardcoded SDK-specific skill lists, required prompt sections exist.
- CLI scenarios for behavior: routing, tool calls, LiveLand activity events, grounded answer synthesis.
- Provider matrix for runtime parity: LiteRT, MiniCPM-V where relevant, Remote, and future Foundation Models adapters.

## Near-Term Work

- Extract a prompt-pack inventory from `PromptBuilder`.
- Add prompt pack IDs to key builder functions.
- Add fixture metadata for expected prompt pack usage.
- Keep Foundation Models prompts and schemas generated from the same skill/tool registry data as legacy prompts.
