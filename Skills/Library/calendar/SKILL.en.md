---
name: Calendar
name-zh: 日历
description: 'Create a new calendar event (meeting / appointment / schedule).'
version: "1.0.0"
icon: calendar
disabled: false
type: device
requires-time-anchor: true
chip_prompt: "Create a product review meeting tomorrow at 2pm"
chip_label: "Create Event"

triggers:
  - calendar
  - event
  - meeting
  - appointment
  - schedule
  - book

allowed-tools:
  - calendar-create-event

examples:
  - query: "Create a product review meeting tomorrow at 2pm"
    scenario: "Create a calendar event"

# Sync anchor (see scripts/check-skill-sync.sh):
translation-source-commit: 034c373
translation-source-sha256: 810069bcade6953c301f2840ba2f592066a0344c2d92758e3783f854aabcd8e0
---

# Calendar Event Creation

Strictly follow the parameter rules below. Do not improvise, do not ask redundant questions.

## Parameters

**Hard params** (required, ask a short clarifying question once if missing):
- `start`: the time expression from the user's utterance, **copied verbatim**. The tool will parse it.
- `title`: event title / subject / what it's about

**Soft params** (omit the field if the user didn't mention them; never ask):
- `end`: end time (same as start, copy verbatim)
- `location`: location
- `notes`: notes

## start extraction rules

**Any time cue in the user's utterance counts as `start` being provided**. Copy that time expression verbatim into the `start` field:
- Relative time: "tomorrow at 2pm" / "tonight at 8" / "noon the day after tomorrow"
- Absolute time: "May 3 at 15:00" / "evening of April 10"
- Already machine format: "2026-04-07T14:00:00"

**Important**: You do NOT need to convert "tomorrow at 2pm" into "2026-04-XXTHH:MM:SS". The tool will do that.
Just write `"start": "tomorrow at 2pm"`. Manual conversion is error-prone — leave it to the tool.

**Forbidden**: if the user has already given a relative time, do NOT ask "which day?".

If the user provided no time at all (e.g. "book a meeting"), ask a short "When?" question.

## title extraction rules

- If the user's utterance contains a noun phrase ("product review meeting" / "meet with Lee") → use it directly as title
- If only a bare action ("book a meeting" / "schedule a meeting at 3pm tomorrow") → **ask once**: "About what?" / "What's the topic?"
- User's follow-up fragments (e.g. "product review, with design team") → combine into title ("product review - design team")
- If the user is still vague after you ask → fall back to title = "Meeting", do NOT ask a second time

## Cross-turn parameter merge (key)

When deciding "are all parameters provided", you must **merge all user messages from the full conversation history**, not just the current turn:

- Previous turn: user said "book a meeting at 3pm tomorrow" → `start` is provided
- This turn: user says "product review, with design team" → `title` is now provided
- Both hard params present → emit tool_call immediately, **do not** ask for start again

**Anti-pattern** (don't do this): previous turn gave the time, this turn gave the topic, and you still ask "when should I schedule it?" — that's ignoring the previous user message, which is wrong.

## Behavior

- **Both hard params present (no matter which turn supplied them)** → emit tool_call immediately, no explanation
- **Either start or title missing across the full history** → ask one short question for the missing one, **do not emit tool_call**
- Never ask for end/location/notes (soft params)

## Reply after completion

- After the tool succeeds, confirm the result in one natural sentence. Do not mention tool names, JSON, or internal steps.
- Prioritize what the user cares about: event title + time.
- Example: "Created: Product review meeting, tomorrow at 2pm."

## Invocation format

Copy the user's literal time expression into `start`; the tool parses it:

<tool_call>
{"name": "calendar-create-event", "arguments": {"title": "Product review meeting", "start": "tomorrow at 2pm"}}
</tool_call>
