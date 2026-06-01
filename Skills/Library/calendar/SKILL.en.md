---
name: Calendar
name-zh: 日历
description: 'Create calendar events, query schedules, and analyze busyness or free time.'
version: "1.1.0"
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
  - agenda
  - availability
  - free time
  - busy

allowed-tools:
  - calendar-create-event
  - calendar-query-events

examples:
  - query: "Create a product review meeting tomorrow at 2pm"
    scenario: "Create a calendar event"
  - query: "What is on my calendar today?"
    scenario: "Query today's schedule"
  - query: "Analyze whether I am busy this week"
    scenario: "Analyze this week's schedule"

# Sync anchor (see scripts/check-skill-sync.sh):
translation-source-commit: bed7561
translation-source-sha256: 6c1618a592a70a1621286d3fd4e785cefc06405eba511c6d39a971d979c01116
---

# Calendar

Strictly follow the parameter rules below. Do not improvise, do not ask redundant questions.

## Tool selection

- Create/add/book/schedule a meeting, appointment, or event → call `calendar-create-event`
- Query today's/tomorrow's/this week's schedule or agenda → call `calendar-query-events`
- Analyze busyness, availability, or free time → call `calendar-query-events` first, then summarize from returned `events` / `busy_minutes` / `free_windows`
- Never invent calendar events before reading them; call the query tool first

## Query and analysis parameters

`calendar-query-events` arguments:
- `period`: preset range. today=`today`, tomorrow=`tomorrow`, this week=`this_week`, next week=`next_week`, next 7 days=`next_7_days`
- `start`: copy the user's time/date/daypart expression verbatim, e.g. "today" / "tomorrow afternoon" / "June 3 2pm"
- `end`: only include when the user gives an explicit end range
- `days`: use a number for "next N days"
- `calendar`: only include when the user names a specific calendar
- `limit`: omit by default
- `include_notes`: do not pass true by default; only pass true if the user explicitly asks for notes/details

Common query mapping:
- "What is on my calendar today?" → `{"period":"today"}`
- "Am I free tomorrow afternoon?" → `{"start":"tomorrow afternoon"}`
- "Am I busy this week?" → `{"period":"this_week"}`
- "My agenda for the next 7 days" → `{"period":"next_7_days"}`

After querying:
- Briefly summarize event count, key events, and busyness
- If the user asks whether they are free, use `free_windows`; if there is enough free time, say so, otherwise point out the conflict window
- Do not output JSON, tool names, or internal field names

## Creation parameters

**Hard params** (required, ask a short clarifying question once if missing):
- `start`: the time expression from the user's utterance, **copied verbatim**. The tool will parse it.
- `title`: event title / subject / what it's about

**Soft params** (omit the field if the user didn't mention them; never ask):
- `end`: end time (same as start, copy verbatim)
- `location`: location
- `notes`: notes

### start extraction rules

**Any time cue in the user's utterance counts as `start` being provided**. Copy that time expression verbatim into the `start` field:
- Relative time: "tomorrow at 2pm" / "tonight at 8" / "noon the day after tomorrow"
- Absolute time: "May 3 at 15:00" / "evening of April 10"
- Already machine format: "2026-04-07T14:00:00"

**Important**: You do NOT need to convert "tomorrow at 2pm" into "2026-04-XXTHH:MM:SS". The tool will do that.
Just write `"start": "tomorrow at 2pm"`. Manual conversion is error-prone — leave it to the tool.

**Forbidden**: if the user has already given a relative time, do NOT ask "which day?".

If the user provided no time at all (e.g. "book a meeting"), ask a short "When?" question.

### title extraction rules

- If the user's utterance contains a noun phrase ("product review meeting" / "meet with Lee") → use it directly as title
- If only a bare action ("book a meeting" / "schedule a meeting at 3pm tomorrow") → **ask once**: "About what?" / "What's the topic?"
- User's follow-up fragments (e.g. "product review, with design team") → combine into title ("product review - design team")
- If the user is still vague after you ask → fall back to title = "Meeting", do NOT ask a second time

### Cross-turn parameter merge (key)

When deciding "are all parameters provided", you must **merge all user messages from the full conversation history**, not just the current turn:

- Previous turn: user said "book a meeting at 3pm tomorrow" → `start` is provided
- This turn: user says "product review, with design team" → `title` is now provided
- Both hard params present → emit tool_call immediately, **do not** ask for start again

**Anti-pattern** (don't do this): previous turn gave the time, this turn gave the topic, and you still ask "when should I schedule it?" — that's ignoring the previous user message, which is wrong.

### Creation behavior

- **Both hard params present (no matter which turn supplied them)** → emit tool_call immediately, no explanation
- **Either start or title missing across the full history** → ask one short question for the missing one, **do not emit tool_call**
- Never ask for end/location/notes (soft params)

### Reply after creation

- After the tool succeeds, confirm the result in one natural sentence. Do not mention tool names, JSON, or internal steps.
- Prioritize what the user cares about: event title + time.
- Example: "Created: Product review meeting, tomorrow at 2pm."

## Invocation format

Copy the user's literal time expression into `start`; the tool parses it:

<tool_call>
{"name": "calendar-create-event", "arguments": {"title": "Product review meeting", "start": "tomorrow at 2pm"}}
</tool_call>

<tool_call>
{"name": "calendar-query-events", "arguments": {"period": "today"}}
</tool_call>
