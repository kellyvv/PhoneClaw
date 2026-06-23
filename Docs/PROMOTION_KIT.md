# PhoneClaw Promotion Kit

Short copy, post templates, and positioning notes for sharing PhoneClaw.

## One-line positioning

English:

> PhoneClaw is a private local iPhone Agent powered by Gemma, running inference and Skills on-device.

Chinese:

> PhoneClaw 是运行在 iPhone 本地的私人 Agent，基于 Gemma 端侧推理，支持本机 Skill 调用。

## Short description

English:

> PhoneClaw brings local agent workflows to iPhone: on-device Gemma inference, native iOS Skills, image understanding, voice interaction, HealthKit and Calendar queries, and explicit Web Search when realtime information is needed.

Chinese:

> PhoneClaw 把本地 Agent 带到 iPhone：端侧 Gemma 推理、iOS 原生 Skill、图片理解、语音交互、健康与日历查询，以及用户明确需要时的联网搜索。

## What to emphasize

- Local iPhone Agent, not a cloud chatbot wrapper.
- No cloud model API required.
- Native iOS Skills with permission boundaries.
- Useful personal workflows: schedule, reminders, contacts, Health data, clipboard, images, voice, web search.
- Open source and available on TestFlight.

## What not to overclaim

- Do not call it a full cloud LLM replacement.
- Do not imply unlimited long-context chat.
- Do not imply arbitrary control of every iOS app.
- Do not imply personal data is uploaded for analysis.
- Do not promise background automation that iOS does not allow.

## X / Twitter post

English:

```text
PhoneClaw is an open-source local iPhone Agent powered by Gemma.

It runs inference and native Skills on-device:
- Calendar and reminders
- Contacts and clipboard
- HealthKit summaries
- Image understanding
- Voice interaction
- Web Search when explicitly requested

GitHub: https://github.com/kellyvv/PhoneClaw
TestFlight: https://testflight.apple.com/join/YuUSwq78
```

Chinese:

```text
PhoneClaw 是一个开源的 iPhone 本地 Agent。

基于 Gemma 端侧推理，可以在手机本地调用 Skill：
- 日历 / 提醒事项
- 通讯录 / 剪贴板
- 健康数据摘要
- 图片理解
- 语音交互
- 明确需要时联网搜索

GitHub: https://github.com/kellyvv/PhoneClaw
TestFlight: https://testflight.apple.com/join/YuUSwq78
```

## Hacker News / Reddit style post

```text
Show HN: PhoneClaw - an open-source local iPhone Agent powered by Gemma

PhoneClaw runs inference and Skill calls on-device. The goal is not to replace cloud-scale chat, but to make local personal workflows useful on iPhone: calendar queries, reminders, contacts, HealthKit summaries, clipboard, image understanding, voice, and explicit Web Search.

The Skill system is file-driven: each capability is defined by SKILL.md and backed by permission-scoped native tools.

GitHub: https://github.com/kellyvv/PhoneClaw
TestFlight: https://testflight.apple.com/join/YuUSwq78
```

## Demo scripts

### Calendar and free-time analysis

1. Ask: "What is on my calendar today?"
2. Ask: "How busy am I this week?"
3. Ask: "Find a free slot tomorrow afternoon."

Point to show: native Calendar access plus local summarization.

### Web Search and follow-up

1. Ask: "Search the web for today's AI news."
2. Ask: "Summarize the important ones in Chinese."
3. Ask: "Turn this into a short post."

Point to show: explicit realtime search, then local organization.

### Image understanding

1. Pick or take a photo.
2. Ask: "What are the key things in this image?"
3. Ask: "What should I do next?"

Point to show: multimodal reasoning on iPhone.

## Suggested GitHub topics

```text
gemma
on-device-ai
ios
swift
local-agent
mobile-agent
ai-agent
litert
healthkit
app-intents
```

## Useful links

- GitHub: https://github.com/kellyvv/PhoneClaw
- TestFlight: https://testflight.apple.com/join/YuUSwq78
- On-device Gemma note: ON_DEVICE_GEMMA.md
- Skill system note: SKILL_SYSTEM.md
- iOS memory note: IOS_MEMORY_LIMITS.md
