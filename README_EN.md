<div align="center">

![banner](assets/banner.jpg)

A local AI Agent for iPhone. Offline. Private. Native.

![Swift](https://img.shields.io/badge/Swift-5.10-orange?style=flat-square)
![iOS](https://img.shields.io/badge/iOS-17%2B-blue?style=flat-square)
![License](https://img.shields.io/badge/License-Apache%202.0-green?style=flat-square)

[TestFlight](https://testflight.apple.com/join/YuUSwq78) · [中文](README.md) · [Report an Issue](https://github.com/kellyvv/phoneclaw/issues) · [Request a Feature](https://github.com/kellyvv/phoneclaw/issues)

</div>

<div align="center">

[Core Features](#core-features) · [Built-in Skills](#built-in-skill-examples) · [Technical Notes](#technical-notes) · [Quick Start](#quick-start) · [Mac Remote](#7-use-the-mac-client-for-remote-inference) · [Custom Skills](#custom-skills) · [FAQ](#faq) · [Roadmap](#roadmap)

</div>

## Demo

<div align="center">
  <video src="https://github.com/user-attachments/assets/355bf2bf-d9cc-4354-aae0-c5d5cb0ca1ee" width="100%" height="auto" controls autoplay loop muted></video>
</div>


PhoneClaw is a private local Agent running on iPhone. It ships with multiple on-device models, including Gemma 4 and MiniCPM-V, and performs inference and Skill calls entirely on-device, with no cloud APIs or external model integrations required.

## Latest Updates

**2026-06-08**

- Added the PhoneClaw Gateway Mac client: keep it running on your Mac, advertise it over Bonjour, then pair from the iPhone to use Mac-side Ollama, Codex CLI, or Antigravity CLI as a remote inference source
- Added a `Mac Remote` page in iPhone settings: discover Macs on the same LAN, approve pairing on the Mac, choose a Mac-side model, then use it from the normal chat screen
- Remote models are only used after you explicitly pair a Mac and select one. With Ollama, inference stays on your Mac; with CLI or other upstream providers, data handling follows that provider's behavior

**2026-06-05**

- PhoneClaw is live on TestFlight — [Join TestFlight](https://testflight.apple.com/join/YuUSwq78)
- Rebuilt the overall Agent framework: improved Skill result semantics, Skill routing, tool-call chains, contextual follow-ups, and multi-step task handling, so the model can more reliably choose whether to answer directly, call tools, or continue from the previous result while reducing accidental tool triggers, repeated calls, and off-track follow-ups
- Added Health range reports: summarize steps, distance, active energy, heart rate, sleep, workouts, weight, and HRV across a selected time range, then generate a local health summary, trends, and key metric explanations

<details>
<summary>Update history</summary>

### 2026-06-01

- PhoneClaw is live on TestFlight — [Join TestFlight](https://testflight.apple.com/join/YuUSwq78)
- Added Calendar read support: query today's, tomorrow's, this week's, and next 7 days' schedule, with busyness and free-time analysis
- Improved Web Search and long-answer browsing: realtime information can be summarized, and history remains scrollable while the model is responding

### 2026-05-17

- PhoneClaw is live on TestFlight — [Join TestFlight](https://testflight.apple.com/join/YuUSwq78)
- A private local Agent running on iPhone, performing inference and Skill calls entirely on-device, with no cloud APIs or external model integrations required

### 2026-05-12

- Released v1.4.0 — [Download](https://github.com/kellyvv/PhoneClaw/releases/tag/v1.4.0)
- Added MiniCPM-V 4.6 multimodal model — image Q&A and real-time camera recognition in LIVE mode
- Fixed several known issues in LIVE mode

### 2026-05-07

- Added MTP speculative decoding toggle (experimental — only speeds up Gemma 4 E4B with short replies).

### 2026-04-25

- Released v1.3.1 — [Download](https://github.com/kellyvv/PhoneClaw/releases/tag/v1.3.1)
- Added English LIVE mode
- Fixed some known bugs
- Released v1.3.0 — [Download](https://github.com/kellyvv/PhoneClaw/releases/tag/v1.3.0)
- Added English localization — the app automatically switches based on system language.
- Refactored the download module: resumable downloads, background downloads, and automatic fastest-mirror selection based on current network conditions.

### 2026-04-23

- Released v1.2.2 — added the ability to choose between GPU or CPU inference backend directly from the settings page; CPU is now the default to fit within Sideloadly-signed memory limits.
- ⚠️ **Sideloadly-signed IPA usage note**: due to the memory cap of sideload-signing, **the E4B model only works on CPU** (GPU will fail). We recommend using **the E2B model** — it's fully featured and more stable under the cap.
- 💡 **If you can, build from source with Xcode**: Xcode-signed builds aren't subject to the sideload memory cap — you can run E2B / E4B with GPU enabled for best performance. [Download](https://github.com/kellyvv/PhoneClaw/releases/tag/v1.2.2)

### 2026-04-20

- Released an unsigned IPA — sign and install to iPhone via [Sideloadly](https://sideloadly.io/), no Xcode or Mac development environment required. [Download](https://github.com/kellyvv/PhoneClaw/releases/tag/v1.1.0)

### 2026-04-18

- Added in-app download for LIVE mode voice models — download directly from the settings page and start using LIVE mode

### 2026-04-17

- Added **LIVE Mode**: a new real-time voice interaction mode with natural conversation flow — interrupt anytime without waiting for the model to finish speaking
- LIVE Mode supports **camera input**: the model can recognize and understand the environment, objects, and scenes captured by the camera in real time, enabling multimodal "see and speak" interaction

### 2026-04-10

- Added Health Skill: read HealthKit data including today's/yesterday's steps, weekly step trends, walking distance, active calories, resting heart rate, last night's sleep, weekly sleep summary, and recent workouts — 9 tools total, all data processed locally and never uploaded
- Improved multi-turn response speed: cross-turn KV cache reuse reduces time-to-first-token by ~3.5x for consecutive queries within the same skill
- The 9 health tools are automatically selected by the model based on user intent — no need to specify a query type

### 2026-04-09

- Ongoing framework and infrastructure work. Major improvement to the multi-turn agent framework: the Router now correctly preserves skill context across turns, and even small models can reliably complete multi-turn tool calls.

### 2026-04-08

- Model downloads now include a ModelScope mirror, so users in mainland China can download Gemma 4 without a VPN
- Major rework of memory management: the inference budget is now dynamically derived from actual available memory, with the obsolete prompt-length subtraction removed, so long prompts and long answers are no longer falsely truncated; multi-turn tool calls also keep their context more reliably

### 2026-04-07

- Added voice input, with on-device audio analysis and recognition
- Added Thinking Mode, available from the top-right corner in chat
- Added chat history, with support for new sessions, switching, and deletion
- Improved memory management and inference budgeting for long answers, multimodal requests, and model switching

### 2026-04-06

- The default install flow is back to a shell app, with models downloaded on-device as needed
- The settings page now includes model download, permission status, and bilingual display names
- Contacts, reminders, calendar, device info, and clipboard flows have received a round of stability fixes

</details>

## Core Features

**Private Local Agent**: Run inference and Skill calls directly on iPhone. Use natural language to work with Calendar, Reminders, Contacts, Clipboard, Health data, and other local tasks.

**Mac Remote Inference**: Optionally pair with a Mac on the same LAN through PhoneClaw Gateway and use Mac-side Ollama, Codex CLI, or Antigravity CLI models while keeping the native iPhone chat and Skill experience.

**Image Understanding and LIVE Vision**: Ask questions about photos from the camera or photo picker, or enable the camera in LIVE mode so the model can understand the scene in real time.

**Personal Data Analysis**: Read local schedules, Health data, contacts, reminders, and clipboard content to generate summaries, availability analysis, and next-step suggestions. Personal data is processed on-device by default.

**Realtime Information**: When explicitly requested, search public webpages, fetch readable webpage text, and summarize live information into an actionable answer.

**Voice Interaction**: Supports voice input and LIVE real-time conversation for hands-free questions, notes, and actions.

## Technical and Experience Features

**File-Driven Skill System**: Each capability is defined by a single Markdown file (SKILL.md). Adding or modifying a skill requires no recompilation. Skills are language-agnostic — anyone can write and share them.

**Model Management and Resumable Downloads**: Gemma main models and LIVE voice models can be downloaded, canceled, resumed, and retried directly on iPhone, or bundled into the app at build time.

**Offline by Default with Clear Privacy Boundaries**: Inference and local Skill calls run on-device by default. Requests only leave the iPhone when the user explicitly asks for Web Search, webpage reading, or paired Mac remote inference. Conversations, images, and personal data are not uploaded to PhoneClaw servers; Mac remote inference sends the current request to your paired Mac, and any further upstream access depends on the provider selected in the Mac client.

**Mobile Memory Optimization**: Includes model switching, system prompt editing, cache cleanup, and history trimming tuned for iPhone on-device inference limits.

**Bilingual Experience**: Choose Auto, Chinese, or English in settings. The UI, default system prompt, built-in Skills, tool results, and permission text switch together.

## Technical Notes

- [On-device Gemma on iPhone](docs/ON_DEVICE_GEMMA.md)
- [PhoneClaw Skill System](docs/SKILL_SYSTEM.md)
- [iOS Memory and Context Limits](docs/IOS_MEMORY_LIMITS.md)
- [Promotion Kit](docs/PROMOTION_KIT.md)

## Built-in Skill Examples

**Calendar**: Create calendar events, query schedules, and analyze busyness or free time using natural language.

> "Schedule a meeting at Hightech Park tomorrow at 2pm"

> "What is on my calendar today?"

> "How busy am I this week?"

**Reminders**: Set time-based reminders that fire a system push notification exactly on schedule.

> "Remind me tonight at 8 to send the file to my boss"

**Contacts**: Search, save, update, or delete contacts with name, phone, company, email, and notes. Automatically deduped by phone number.

> "Save Wang's number 13812345678, he's from Bytedance"

> "Check Sarah Lee's phone number"

**Clipboard**: Read and write the system clipboard. Useful as a data relay in multi-step tasks.

> "Copy that text to the clipboard"

**Translate**: Translate between any pair of languages, with automatic source detection.

> "Translate that last line into Japanese"

**Health Data**: Read HealthKit steps, distance, calories, heart rate, sleep, and workout records after user authorization. All data stays on-device.

> "How many steps did I take today?"

> "How did I sleep last night?"

> "How are my steps this week?"

> "What's my resting heart rate?"

**Web Search**: When explicitly requested, search public webpages or read a URL, then summarize realtime information into an answer.

> "Search the web for today's AI news"

> "Read and summarize this page: https://example.com"

## Requirements

- macOS + Xcode 16 or later
- iOS 17.0 or later
- CocoaPods
- A real device with a developer account (Apple ID)

Model recommendation:

| Model | Use case |
|-------|----------|
| Gemma 4 E2B | Lightweight: chat / translation / single-turn queries, A16 and above |
| Gemma 4 E4B | Full-featured: multi-turn tool conversations and complex agent flows, iPhone 15 Pro and above |
| MiniCPM-V 4.6 | Multimodal: image Q&A / real-time camera in LIVE mode, A17 Pro and above recommended |

## Quick Start

Recommended install: [TestFlight](https://testflight.apple.com/join/YuUSwq78). After installing, download a model in `Model Settings`, then enable the Skills you need.

Building from source requires macOS + Xcode 16, iOS 17+, CocoaPods, a real device, and an Apple ID.

### 1. Clone the repository

```bash
git clone https://github.com/kellyvv/phoneclaw.git
cd phoneclaw
```

### 2. Install dependencies

```bash
pod install
```

### 3. Optional: pre-download a model locally

The default recommended flow is now:

1. Install the app shell to the iPhone from Xcode
2. Open the app
3. Go to `Model Settings`
4. Download `Gemma 4 E2B` or `Gemma 4 E4B` directly on the phone

You only need the `Models/` directory on your Mac if you want to bundle a model inside the app itself.

Gemma 4 now runs on LiteRT-LM: each model is a single `.litertlm` file (no MLX weight directory). Install the Hugging Face CLI first:

```bash
brew install hf
# or
pip install -U "huggingface_hub"
```

E2B only (recommended):
```bash
mkdir -p ./Models
hf download litert-community/gemma-4-E2B-it-litert-lm gemma-4-E2B-it.litertlm --local-dir ./Models
```

E4B only:
```bash
mkdir -p ./Models
hf download litert-community/gemma-4-E4B-it-litert-lm gemma-4-E4B-it.litertlm --local-dir ./Models
```

Both models:
```bash
mkdir -p ./Models
hf download litert-community/gemma-4-E2B-it-litert-lm gemma-4-E2B-it.litertlm --local-dir ./Models
hf download litert-community/gemma-4-E4B-it-litert-lm gemma-4-E4B-it.litertlm --local-dir ./Models
```

Expected files after download:

```
Models/
├── gemma-4-E2B-it.litertlm
└── gemma-4-E4B-it.litertlm
```

> `Models/` is gitignored and will not be committed.
> Approximate file sizes: E2B ~2.4 GB, E4B ~3.4 GB.
> In mainland China, set `HF_ENDPOINT=https://hf-mirror.com` to use the mirror, or download the same file from the ModelScope mirror.

**LIVE Mode (voice interaction) additional models**

If you want to use LIVE mode with voice recognition and synthesis, download the ASR and TTS models:

```bash
# ASR — Chinese streaming speech recognition (zipformer, int8, ~160MB)
hf download csukuangfj/sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30 \
  --local-dir ./Models/sherpa-asr-zh \
  --exclude "test_wavs/*" "*.md" ".gitattributes"

# TTS — Chinese text-to-speech (keqing, ~125MB)
hf download csukuangfj/vits-zh-hf-keqing \
  --local-dir ./Models/vits-zh-hf-keqing \
  --exclude "*.py" "*.sh" ".gitattributes"
```

After downloading, add `Models/sherpa-asr-zh` and `Models/vits-zh-hf-keqing` as folder references to `Copy Bundle Resources` in Xcode. Skipping this step won't break the build — LIVE mode will fall back to system speech.

### 4. Open the workspace

```bash
open PhoneClaw.xcworkspace
```

> Do not open `.xcodeproj`. Always open `.xcworkspace`.

### 5. Configure signing and run

1. In Xcode, select the PhoneClaw target
2. Open Signing & Capabilities
3. Set your Team
4. Change the Bundle Identifier to a unique value
5. Connect your iPhone and press ⌘R

On first install, if prompted to trust the developer certificate: Settings → General → VPN & Device Management → Trust

### 6. First use

After opening the app:

- Top-right puzzle icon: Skill management
- Top-right slider icon: Model settings / system prompt / permissions
- If you installed a shell-only app, tap `Download` in the model settings page first

Download a model first, then enable Calendar, Reminders, and Contacts in the permissions page, then try:

```
Remind me tonight at 8 to send the file
Save Wang's phone number 13812345678
Translate that last line into English
```

### 7. Use the Mac client for remote inference

The Mac client turns a Mac on the same LAN into an optional remote inference source for the iPhone app. The iPhone still uses PhoneClaw's chat UI and Skill system, while model inference requests are sent to your paired Mac.

**Start Gateway on the Mac**

```bash
cd PhoneClawGateway
bash build-app.sh
open PhoneClawGateway.app
```

On first launch, allow the macOS Local Network permission prompt. Gateway listens on port `18080` by default and advertises the `_phoneclaw-llm._tcp` Bonjour service.

**Configure the Mac runtime source**

1. Open `PhoneClawGateway.app`
2. Choose a runtime source in the main window: Ollama, Codex CLI, or Antigravity CLI
3. If you use Ollama, install and start Ollama first, then pull a model, for example:

```bash
ollama pull gemma3:4b
```

4. Return to Gateway, scan, and confirm that the model appears in the list

**Pair from the iPhone**

1. Make sure the iPhone and Mac are on the same LAN
2. Open PhoneClaw → top-right slider → `Mac Remote`
3. Tap the Mac, then approve the request in the Mac client
4. After pairing, choose a Mac-side model and return to chat

Remote models appear under the `Remote` section in the model picker. If the iPhone cannot find the Mac, check that the Mac client is running, Local Network permission is allowed, both devices are on the same Wi-Fi, and the macOS firewall allows `PhoneClawGateway.app` to accept LAN connections.

## Default Install Flow and Model Bundling

### Option A — Shell app + on-device model download

This is now the default recommended setup.

Advantages:

1. Much smaller install size from Xcode
2. Faster first-time app installation from the Mac
3. Users can choose E2B or E4B directly on the phone

By default, the project no longer bundles anything from `Models/` into the app.

### Option B — E2B only

1. Keep `Models/gemma-4-E2B-it.litertlm`, remove `Models/gemma-4-E4B-it.litertlm`
2. In Xcode's Project Navigator, delete the unused model file reference and choose Remove Reference
3. In PhoneClaw > Build Phases > Copy Bundle Resources, make sure `gemma-4-E2B-it.litertlm` is included (as a single file, not a folder reference) and confirm only that one remains
4. Edit `allModels` in `LLM/Models/PredefinedModels.swift` to only include the models actually shipped (otherwise the settings page will show options that don't exist)

### Option C — Both E2B and E4B

Download both models:

```bash
brew install hf
mkdir -p ./Models
hf download litert-community/gemma-4-E2B-it-litert-lm gemma-4-E2B-it.litertlm --local-dir ./Models
hf download litert-community/gemma-4-E4B-it-litert-lm gemma-4-E4B-it.litertlm --local-dir ./Models
```

Then add both `.litertlm` files into Xcode's `Copy Bundle Resources`.


## Adding Custom Skills

Create a `SKILL.md` file in the app's data directory and hot-reload in-app:

```
Application Support/PhoneClaw/skills/<skill-id>/SKILL.md
```

```yaml
---
name: MySkill
name-zh: My Skill
description: What this skill does
version: "1.0.0"
icon: star
disabled: false
type: device          # device = native API; content = prompt-only; network = public internet access

triggers:
  - keyword1

allowed-tools:
  - my-tool-name

examples:
  - query: "How a user might phrase it"
    scenario: "What scenario triggers this"
---

# Skill Instructions

Tell the model when to call tools, how to structure arguments, and when to answer directly.
```

The `type` field controls routing: `device` calls native iOS APIs, `content` is prompt-only text processing, and `network` is for explicit live web search or webpage reading. If this skill needs to call native APIs or network tools, register the tool in `Tools/ToolRegistry.swift` (and add a handler under `Tools/Handlers/`). The framework validates `allowed-tools` against the registry at startup, so any typo will surface immediately in the console.


## FAQ

Why are there no permission dialogs after install?
The corresponding Skill has likely not reached the system API call yet. If you previously denied permission, iOS will not prompt again — go to system Settings to re-enable.

Why does the model fail to load after switching?
Verify that the model file name matches `allModels` in `LLM/Models/PredefinedModels.swift`, that the model has finished downloading on-device if you are using the shell-only install flow, or that it was actually included in the app bundle if you are shipping it built-in, and that the device has enough memory.

Why does creating a reminder fail?
The latest code first attempts to reuse an existing writable reminder list. If none is found, it tries to automatically create a PhoneClaw list. If that also fails, the system reminder source itself is likely read-only.

Why can't my iPhone find the Mac client?
Make sure `PhoneClawGateway.app` is running and macOS has allowed Local Network permission. The iPhone and Mac must be on the same LAN. If discovery still fails, check that the macOS firewall allows the app to accept incoming connections, or rebuild the app with `bash PhoneClawGateway/build-app.sh` and open the generated app again.

## Roadmap

### 1. More iOS native APIs

- [ ] File and directory access
- [x] Image picking, description, and Q&A
- [ ] Photo library reading, organization, and search
- [ ] Notes
- [x] Reminder due-time alerts
- [ ] General local notifications
- [ ] Maps and location
- [x] URL webpage reading and context passing
- [ ] Safari / URL Scheme handoff to external apps
- [x] Contacts search, create, update, and delete
- [x] Calendar creation, schedule reading, busyness, and free-time analysis
- [x] Reminder creation
- [x] Read-only HealthKit analysis

### 2. More Skills

Continue breaking capabilities into focused Skills rather than embedding all logic in a single large prompt. Directions worth adding:

- [ ] File management
- [x] Image understanding
- [ ] Photo organization
- [x] Schedule creation, querying, and busyness analysis
- [x] Personal information management: contacts, calendar, reminders, clipboard, and Health data
- [ ] Local knowledge base search
- [x] Voice input / text-to-speech
- [x] Web Search / webpage reading
- [x] Translation

### 3. More local models

Beyond the main chat model, suitable additions include:

- [x] Vision / multimodal model
- [ ] OCR model
- [x] Speech recognition model
- [x] Speech synthesis model
- [ ] Embedding / Reranker model
- [ ] A smaller tool argument extraction model
- [ ] A stronger planning model or multi-model pipeline

This moves PhoneClaw from "one big model doing everything" toward "multiple local models working together."

### 4. Cross-app automation

PhoneClaw will not assume desktop-style control over arbitrary apps. Instead it will use what iOS actually allows:

- [ ] App Intents / Shortcuts
- [ ] URL Scheme / Deep Link
- [ ] Share Sheet extensions
- [x] Clipboard relay
- [x] System reminder notifications
- [ ] System notification wake-up and cross-app orchestration

A realistic goal: pass content between apps, open a specific app to a specific screen, and compress multi-step operations into a single natural language command.

### 5. External hardware and visual input

- [x] LIVE camera real-time recognition
- [ ] External video input
- [ ] Screen understanding
- [ ] External hardware integration

Explore connecting external video input and screen understanding with local models, so PhoneClaw goes beyond answering questions in isolation and develops stronger real-world perception and scheduling capabilities.


## References

- [Hugging Face CLI documentation](https://huggingface.co/docs/huggingface_hub/guides/cli)
- [Hugging Face download guide](https://huggingface.co/docs/huggingface_hub/en/guides/download)
- [Gemma 4 E2B LiteRT model](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm)
- [Gemma 4 E4B LiteRT model](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm)
- [Gemma 4 E2B (ModelScope mirror)](https://modelscope.cn/models/litert-community/gemma-4-E2B-it-litert-lm)
- [Gemma 4 E4B (ModelScope mirror)](https://modelscope.cn/models/litert-community/gemma-4-E4B-it-litert-lm)
- [MiniCPM-V 4.6 model](https://huggingface.co/openbmb/MiniCPM-V-4_6)
- [OpenBMB MiniCPM-V iOS Demo](https://github.com/OpenBMB/MiniCPM-V-Apps)

## License

Apache 2.0
