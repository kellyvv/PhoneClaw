# Hotfix Release Plan v1.0

## Goal

1. Fix `Max number of tokens reached`
2. Stabilize long-session prompt growth
3. Stabilize `multimodal -> text` transitions
4. Keep the hotfix independently rollbackable

## Scope

In scope:

- prompt/session shape planning
- preflight budget
- canonical tool summaries
- budget-driven history trim
- multimodal/text session isolation
- baseline, golden corpus, and observability

Out of scope:

- rolling summary
- agent KV snapshot/restore
- full PromptBuilder decomposition
- second backend abstraction

## Flags

- `PHONECLAW_USE_HOTFIX_PROMPT_PIPELINE`
- `ENABLE_PREFLIGHT_BUDGET`
- `ENABLE_CANONICAL_TOOL_RESULT`
- `ENABLE_HISTORY_TRIM`
- `ENABLE_MULTIMODAL_SESSION_GROUP`

All flags default to `ON` in the first hotfix release.

## Prompt Shapes

- `lightFull`
- `lightDelta`
- `agentFull`
- `toolFollowup`
- `thinking`
- `multimodal`
- `live`

## Session Groups

- `text`
- `multimodal`
- `live`

Cross-group transitions always reset. `multimodal -> text` uses lazy reopen.
`live` group is still managed by the dedicated `enterLiveMode` / `exitLiveMode` lifecycle; the
session-group hotfix only coordinates `text <-> multimodal`.

## MVP Items

1. Perf baseline + golden corpus + observability ring buffer
2. Prompt shape / session group / reuse decision skeleton
3. Model-level safe context budget
4. Preflight budget gate + auto-trim + hard reject UX
5. Canonical tool results
6. Budget-driven history trim
7. Multimodal/text session isolation

## Acceptance

1. E2B survives `3 x 800-token replies + 2 x tool calls`
2. E4B survives `10` mixed-skill turns with at most one auto-trim
3. Three consecutive text turns succeed after a multimodal turn
4. TTFT regression stays within `+10%`
5. With hotfix flag `OFF`, prompt strings match golden corpus byte-for-byte

## Rollback

- Each Phase 1 item rolls back behind its own flag
- Main flag disables the whole hotfix pipeline
- Legacy path remains for at least one release cycle
