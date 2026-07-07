# PhoneClaw Promotion Kit

Short copy, post templates, and positioning notes for sharing PhoneClaw.

## One-line positioning

English:

> PhoneClaw turns phones into local AI agent runtimes with on-device models, native mobile Skills, LiveLand, and optional Mac Gateway inference.

Chinese:

> PhoneClaw 把手机变成本地 AI Agent 运行时，提供端侧模型、原生移动端 Skills、LiveLand 和可选 Mac Gateway 推理。

## Short description

English:

> PhoneClaw brings local agent workflows to the phone: on-device Gemma inference, native mobile Skills, image understanding, voice interaction, HealthKit and Calendar queries, LiveLand, and explicit Web Search when realtime information is needed.

Chinese:

> PhoneClaw 把本地 Agent 带到手机：端侧 Gemma 推理、原生移动端 Skills、图片理解、语音交互、健康与日历查询、LiveLand，以及用户明确需要时的联网搜索。

## What to emphasize

- Phone as the local AI agent runtime.
- Fully offline local path with on-device models.
- Native mobile Skills with permission boundaries.
- Useful personal workflows: schedule, reminders, contacts, Health data, clipboard, images, voice, web search.
- LiveLand and LIVE mode as mobile-native interaction surfaces.
- Optional Mac Gateway for heavier local inference over LAN.
- Open source and available on TestFlight.

## Product boundaries

- PhoneClaw focuses on phone-scale local agent workflows.
- Local inference and native Skills run on the device by default.
- Web Search, webpage reading, and Mac Gateway are explicit user-triggered capabilities.
- Native actions follow mobile OS permission boundaries.
- Mac Gateway data handling depends on the Mac-side provider selected by the user.

## X / Twitter post

English:

```text
PhoneClaw is an open-source local AI agent runtime for phones.

It runs models and native mobile Skills on device:
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
PhoneClaw 是一个开源的手机本地 AI Agent 运行时。

基于 Gemma 端侧推理，可以调用原生移动端 Skills：
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
Show HN: PhoneClaw - a local AI agent runtime for phones

PhoneClaw runs inference and Skill calls on device. It is designed for practical phone workflows: calendar queries, reminders, contacts, HealthKit summaries, clipboard, image understanding, voice, LiveLand, and explicit Web Search.

The Skill system is file-driven: each capability is defined by SKILL.md and backed by permission-scoped native mobile tools.

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

Point to show: multimodal reasoning on the phone.

## Suggested GitHub topics

```text
gemma
on-device-ai
local-agent
mobile-agent
ai-agent
phone-harness
phone-loop
litert
swift
ios
```

## Useful links

- GitHub: https://github.com/kellyvv/PhoneClaw
- TestFlight: https://testflight.apple.com/join/YuUSwq78
- On-device Gemma note: ON_DEVICE_GEMMA.md
- Skill system note: SKILL_SYSTEM.md
- iOS memory note: IOS_MEMORY_LIMITS.md
