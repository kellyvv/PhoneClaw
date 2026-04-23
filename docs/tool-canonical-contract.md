# Tool Canonical Contract

## Scope

This contract defines how native tools should produce `CanonicalToolResult` while the hotfix pipeline is enabled.

## Result Semantics

- `success = true` means the tool executed correctly.
- `success = false` means the tool did not execute correctly.
- Empty or zero-match business results are still `success = true`.

Examples:

- clipboard empty → `success = true`
- reminders query with zero matches → `success = true`
- missing title / missing due / permission denied → `success = false`

## Failure Split

- Business failures do **not** throw.
  - Return `CanonicalToolResult(success: false, ...)`
  - Examples: missing parameters, invalid time expression, permission denied, no writable list
- System failures **do** throw.
  - Let the upper `ToolChain` / `Planner` catch path handle them
  - Examples: EventKit save failure, unexpected store/runtime exceptions

### Domain-specific normalization

- If a domain exposes errors through callback-style result channels and those failures are
  predictable enough to classify locally, the handler may normalize them into
  `CanonicalToolResult(success: false, ...)` instead of throwing.
- This is allowed when the goal is to preserve a stable business-level contract for the
  caller rather than surface an opaque runtime exception.
- Example: HealthKit query callbacks returning authorization/query/no-data outcomes.

## Summary vs Detail

- `summary` is the model-facing compact text for follow-up prompting or direct user reply.
- `detail` is the structured payload stored in `.skillResult.content`.
- `detail` should remain JSON-compatible and deterministic.
- Keys prefixed with `_` are framework metadata, not business result fields.

## Determinism

- Tool payload JSON must use sorted keys.
- This is required so prompt/golden comparisons do not flap across process restarts.

## Error Code Naming

- Shared cross-handler validation errors use generic names such as:
  - `TITLE_MISSING`
  - `TIME_MISSING`
  - `TIME_UNPARSEABLE`
- Handler-specific operational errors use a tool family prefix such as:
  - `REMINDERS_PERMISSION_DENIED`
  - `REMINDERS_NO_WRITABLE_LIST`
  - `CALENDAR_PERMISSION_DENIED`
  - `CALENDAR_NO_WRITABLE`

## Extension Note

The current `success` boolean is sufficient for Reminders hotfix scope.

For Contacts / Calendar ambiguous or partial-result flows, evaluate whether a future `result_state` field is needed for:

- ambiguous match
- partial date/time parse
- not found with follow-up actions pending
