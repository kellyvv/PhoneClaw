# PhoneClaw Skill System

PhoneClaw uses a file-driven Skill system. Each capability is described by a `SKILL.md` file and backed by native tool implementations when device access is required.

This lets the app grow new abilities without turning the system prompt into one large, fragile block.

## Core idea

A Skill is a small, focused capability package:

- metadata in YAML frontmatter
- behavior instructions in Markdown
- optional examples
- an explicit list of allowed tools

Example shape:

```md
---
name: Calendar
description: Create events, query schedules, and analyze free time.
type: device
requires-time-anchor: true
allowed-tools:
  - calendar-create-event
  - calendar-query-events
examples:
  - query: "What is on my calendar today?"
    scenario: "Schedule query"
---

# Calendar

Use calendar-query-events before answering schedule questions.
```

## Skill types

PhoneClaw separates Skills by behavior and privacy boundary.

| Type | Meaning | Examples |
|------|---------|----------|
| `device` | Reads or writes local iOS data | Calendar, Reminders, Contacts, Health, Clipboard |
| `content` | Transforms text without native tools | Translate |
| `network` | Accesses public web information | Web Search, Web Fetch |

This is important because an iPhone Agent should not treat a translation request, a HealthKit query, and a web search as the same kind of action.

## Tool allowlist

Every tool-capable Skill declares `allowed-tools`. The model can only use the tools exposed by the active Skill.

This prevents a prompt-only Skill from silently gaining access to unrelated device capabilities.

Examples:

- Calendar can use `calendar-create-event` and `calendar-query-events`.
- Health can use read-only HealthKit tools.
- Web Search can use `web-search` and `web-fetch`.
- Translate has no native tools.

## Why not one giant prompt

A single large prompt is easy to start with but becomes hard to control:

- unrelated instructions compete with each other
- the model may over-trigger tools
- privacy-sensitive actions become harder to audit
- bilingual behavior becomes harder to keep in sync
- adding a new ability risks changing old behavior

Focused Skills make the system easier to test, document, and extend.

## Privacy model

Skills do not grant system access by themselves. Device access still requires:

- a native tool implementation
- an iOS permission where applicable
- a matching `allowed-tools` entry
- a user request that actually calls for that capability

This keeps the natural-language layer separate from the system permission layer.

## Built-in Skills

Current built-in Skills include:

- Calendar
- Reminders
- Contacts
- Clipboard
- Translate
- Health
- Web Search

## Future directions

Good future Skills should be permission-scoped and useful on a phone:

- OCR
- Photos
- Files
- Location
- Notifications
- Share Extension
- App Intents / Shortcuts

## Useful links

- [On-device Gemma on iPhone](ON_DEVICE_GEMMA.md)
- [iOS Memory and Context Limits](IOS_MEMORY_LIMITS.md)
- [README](../README.md)
