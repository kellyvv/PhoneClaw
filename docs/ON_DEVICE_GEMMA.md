# On-device Gemma on iPhone

PhoneClaw is a private local iPhone Agent powered by Gemma. It runs inference and Skill calls on-device, without requiring a cloud model API.

## What this means

- The model runs locally on the iPhone.
- Skills call native iOS tools such as Calendar, Reminders, Contacts, Clipboard, HealthKit, and Web Search.
- User data is processed locally by default.
- Public web access is only used when the user explicitly asks for realtime information or webpage reading.

## Why Gemma works well here

Gemma is a good fit for a local mobile agent because it can handle short and medium context tasks while staying small enough for iPhone-class devices. In PhoneClaw, Gemma is used for:

- natural-language task routing
- Skill selection
- tool argument extraction
- multi-turn follow-up
- translation and lightweight analysis

MiniCPM-V is used for image understanding and LIVE camera scenarios.

## Practical model choices

| Model | Practical use |
|-------|---------------|
| Gemma 4 E2B | Lightweight chat, translation, single-turn queries, simple Skills |
| Gemma 4 E4B | More capable multi-turn tool use and agent workflows |
| MiniCPM-V 4.6 | Image Q&A and LIVE camera understanding |

The right model is not only about benchmark quality. On mobile, latency, memory pressure, thermal behavior, and context length matter just as much.

## Mobile constraints

The theoretical context window is not the same as the comfortable mobile context window. On an iPhone, model weights, runtime buffers, Metal memory, app memory, the operating system, and KV cache compete for RAM.

That is why PhoneClaw currently treats short and medium context workflows as the primary product target. The goal is not to replace cloud-scale long-context chat. The goal is to make local personal tasks reliable:

- check today's schedule
- find free time this week
- read HealthKit data
- summarize a webpage after explicit web search
- translate recent text
- understand a photo
- create a reminder or calendar event

## Agent design pattern

PhoneClaw does not expose every tool blindly to the model. It uses:

- `SKILL.md` files for behavior instructions
- native tool implementations for iOS actions
- explicit `allowed-tools` lists
- Skill types such as `device`, `content`, and `network`
- permission-gated access for sensitive data

This keeps local agent behavior more predictable and makes privacy boundaries visible in the codebase.

## Useful links

- [README](../README.md)
- [English README](../README_EN.md)
- [PhoneClaw Skill System](SKILL_SYSTEM.md)
- [iOS Memory and Context Limits](IOS_MEMORY_LIMITS.md)
