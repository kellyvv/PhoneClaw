---
name: Reminders
name-zh: 提醒事项
description: 'Create a new reminder. Use when the user needs to remember to do something, set a to-do, or be reminded.'
version: "1.0.0"
icon: bell
disabled: false
type: device
requires-time-anchor: true
chip_prompt: "Remind me to send the file at 8pm tonight"
chip_label: "Create Reminder"

triggers:
  - remind
  - reminder
  - todo
  - to-do
  - remember
  - alert

allowed-tools:
  - reminders-create

examples:
  - query: "Remind me to send the file at 8pm tonight"
    scenario: "Create a new reminder"

# Sync anchor (see scripts/check-skill-sync.sh):
translation-source-commit: 034c373
translation-source-sha256: 41d06aedebcbcd4f33370798ac393df2be8d1113f987c9b520977eba22efa4fc
---

# Reminder Creation

You are responsible for helping the user create new reminders. **The core of a reminder is "when to remind" — a reminder without a time is meaningless.**

## Available Tools

- **reminders-create**: Create a reminder
  - `title`: **required**, the reminder title
  - `due`: **required**, the reminder time. **Copy the user's wording verbatim** (e.g. "8pm tonight" / "10am tomorrow" / "3pm on May 3"), the tool will parse it. You do **not** need to convert to ISO 8601.
  - `notes`: optional, notes

## Execution Flow

1. Extract `title` and `due` from the user's utterance
2. **If `title` is missing**: briefly ask "What would you like to be reminded about?"
3. **If `due` is missing**: briefly ask "When should I remind you?"
4. Only call `reminders-create` when **both are present**. Copy the user's verbatim time expression straight into the `due` field — no conversion needed
5. After the tool succeeds, tell the user the reminder has been created (e.g. "Done, I've set a reminder to buy milk at 8am tomorrow")
6. **Do not** emit a tool_call before `due` has been provided

## Invocation Format

Whatever time the user says, copy it into `due` verbatim; the tool parses it:

<tool_call>
{"name": "reminders-create", "arguments": {"title": "Send the file", "due": "8pm tonight"}}
</tool_call>
