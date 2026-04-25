<div align="center">

![banner](assets/banner.jpg)

A local AI Agent for iPhone. Offline. Private. Native.

![Swift](https://img.shields.io/badge/Swift-5.10-orange?style=flat-square)
![iOS](https://img.shields.io/badge/iOS-17%2B-blue?style=flat-square)
![License](https://img.shields.io/badge/License-Apache%202.0-green?style=flat-square)

[中文](README.md) · [Report an Issue](https://github.com/kellyvv/phoneclaw/issues) · [Request a Feature](https://github.com/kellyvv/phoneclaw/issues)

</div>

<div align="center">

[Core Features](#core-features) · [Built-in Skills](#built-in-skill-examples) · [Quick Start](#5-minute-quick-start) · [Custom Skills](#custom-skills) · [FAQ](#faq) · [Roadmap](#roadmap)

</div>

## Demo

<div align="center">
  <video src="https://github.com/user-attachments/assets/be57bb84-ef68-406f-9dd2-5e214db1b191" width="100%" height="auto" controls autoplay loop muted></video>
</div>


PhoneClaw is a local AI Agent that runs entirely on your iPhone. No internet connection. No data uploads. No cloud dependency.

## 2026-04-25 Update

- Released v1.3.1 — [Download](https://github.com/kellyvv/PhoneClaw/releases/tag/v1.3.1)
- Added English LIVE mode
- Fixed some known bugs
- Released v1.3.0 — [Download](https://github.com/kellyvv/PhoneClaw/releases/tag/v1.3.0)
- Added English localization — the app automatically switches based on system language.
- Refactored the download module: resumable downloads, background downloads, and automatic fastest-mirror selection based on current network conditions.

## 2026-04-23 Update

- Released v1.2.2 — added the ability to choose between GPU or CPU inference backend directly from the settings page; CPU is now the default to fit within Sideloadly-signed memory limits.
- ⚠️ **Sideloadly-signed IPA usage note**: due to the memory cap of sideload-signing, **the E4B model only works on CPU** (GPU will fail). We recommend using **the E2B model** — it's fully featured and more stable under the cap.
- 💡 **If you can, build from source with Xcode**: Xcode-signed builds aren't subject to the sideload memory cap — you can run E2B / E4B with GPU enabled for best performance. [Download](https://github.com/kellyvv/PhoneClaw/releases/tag/v1.2.2)

## 2026-04-20 Update

- Released an unsigned IPA — sign and install to iPhone via [Sideloadly](https://sideloadly.io/), no Xcode or Mac development environment required. [Download](https://github.com/kellyvv/PhoneClaw/releases/tag/v1.1.0)

## 2026-04-18 Update

- Added in-app download for LIVE mode voice models — download directly from the settings page and start using LIVE mode

## 2026-04-17 Update

- Added **LIVE Mode**: a new real-time voice interaction mode with natural conversation flow — interrupt anytime without waiting for the model to finish speaking
- LIVE Mode supports **camera input**: the model can recognize and understand the environment, objects, and scenes captured by the camera in real time, enabling multimodal "see and speak" interaction

## 2026-04-10 Update

- Added Health Skill: read HealthKit data including today's/yesterday's steps, weekly step trends, walking distance, active calories, resting heart rate, last night's sleep, weekly sleep summary, and recent workouts — 9 tools total, all data processed locally and never uploaded
- Improved multi-turn response speed: cross-turn KV cache reuse reduces time-to-first-token by ~3.5x for consecutive queries within the same skill
- The 9 health tools are automatically selected by the model based on user intent — no need to specify a query type

## 2026-04-09 Update

- Ongoing framework and infrastructure work. Major improvement to the multi-turn agent framework: the Router now correctly preserves skill context across turns, and even small models can reliably complete multi-turn tool calls.

## 2026-04-08 Update

- Model downloads now include a ModelScope mirror, so users in mainland China can download Gemma 4 without a VPN
- Major rework of memory management: the inference budget is now dynamically derived from actual available memory, with the obsolete prompt-length subtraction removed, so long prompts and long answers are no longer falsely truncated; multi-turn tool calls also keep their context more reliably

## 2026-04-07 Update

- Added voice input, with on-device audio analysis and recognition
- Added Thinking Mode, available from the top-right corner in chat
- Added chat history, with support for new sessions, switching, and deletion
- Improved memory management and inference budgeting for long answers, multimodal requests, and model switching

## 2026-04-06 Update

- The default install flow is back to a shell app, with models downloaded on-device as needed
- The settings page now includes model download, permission status, and bilingual display names
- Contacts, reminders, calendar, device info, and clipboard flows have received a round of stability fixes



## Core Features

**Image Understanding (Multimodal)**: Take a photo or pick one from your library, then ask questions directly. Identify objects, read charts, describe scenes — all inference happens on your device, and your photos never leave your phone.

**File-Driven Skill System**: Each capability is defined by a single Markdown file (SKILL.md). Adding or modifying a skill requires no recompilation. Skills are language-agnostic — anyone can write and share them.

**100% Offline & Private**: All inference runs entirely on your iPhone. No network connections are made by default. Your conversations, images, and personal data are never uploaded or routed through any third-party server.

**Flexible Model Management**: Supports Gemma 4 E2B and E4B. Download models directly on your iPhone, or bundle them into the app at build time. Includes a built-in model switcher, system prompt editor, and automatic history trimming for iPhone memory constraints.

## Built-in Skill Examples

**Calendar**: Create calendar events using natural language — title, time, and location all supported.

> "Schedule a meeting at Hightech Park tomorrow at 2pm"

**Reminders**: Set time-based reminders that fire a system push notification exactly on schedule.

> "Remind me tonight at 8 to send the file to my boss"

**Contacts**: Save or update contacts with name, phone, company, email, and notes. Automatically deduped by phone number.

> "Save Wang's number 13812345678, he's from Bytedance"

**Clipboard**: Read and write the system clipboard. Useful as a data relay in multi-step tasks.

> "Copy that text to the clipboard"

**Translate**: Translate between any pair of languages, with automatic source detection.

> "Translate that last line into Japanese"

**Health Data**: Read HealthKit steps, distance, calories, heart rate, sleep, and workout records. All data stays on-device.

> "How many steps did I take today?"
> "How did I sleep last night?"
> "How are my steps this week?"
> "What's my resting heart rate?"

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

## Quick Start

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

Directory names must match exactly as shown below. Install the Hugging Face CLI first:

```bash
brew install hf
# or
pip install -U "huggingface_hub"
```

E2B only (recommended):
```bash
mkdir -p ./Models/gemma-4-e2b-it-4bit
hf download mlx-community/gemma-4-e2b-it-4bit --local-dir ./Models/gemma-4-e2b-it-4bit
```

E4B only:
```bash
mkdir -p ./Models/gemma-4-e4b-it-4bit
hf download mlx-community/gemma-4-e4b-it-4bit --local-dir ./Models/gemma-4-e4b-it-4bit
```

Both models:
```bash
mkdir -p ./Models/gemma-4-e2b-it-4bit ./Models/gemma-4-e4b-it-4bit
hf download mlx-community/gemma-4-e2b-it-4bit --local-dir ./Models/gemma-4-e2b-it-4bit
hf download mlx-community/gemma-4-e4b-it-4bit --local-dir ./Models/gemma-4-e4b-it-4bit
```

Expected directory structure after download:

```
Models/
├── gemma-4-e2b-it-4bit/
│   ├── config.json
│   ├── tokenizer.json
│   ├── processor_config.json
│   ├── chat_template.jinja
│   ├── model.safetensors
│   └── model.safetensors.index.json
└── gemma-4-e4b-it-4bit/
```

> `Models/` is gitignored and will not be committed.
> Approximate repository sizes on Hugging Face: E2B ~3.58 GB, E4B ~5.22 GB.
> You can also download manually from the model page and place files in the correct directory.

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

## Default Install Flow and Model Bundling

### Option A — Shell app + on-device model download

This is now the default recommended setup.

Advantages:

1. Much smaller install size from Xcode
2. Faster first-time app installation from the Mac
3. Users can choose E2B or E4B directly on the phone

By default, the project no longer bundles anything from `Models/` into the app.

### Option B — E2B only

1. Keep `Models/gemma-4-e2b-it-4bit`, remove `Models/gemma-4-e4b-it-4bit`
2. In Xcode's Project Navigator, delete the unused model folder reference and choose Remove Reference
3. In PhoneClaw > Build Phases > Copy Bundle Resources, manually add back the model you want to ship and confirm only that one remains
4. Edit `availableModels` in `LLM/MLX/MLXLocalLLMService.swift` to only include the models actually shipped (otherwise the settings page will show options that don't exist)

### Option C — Both E2B and E4B

Download both models:

```bash
brew install hf
mkdir -p ./Models/gemma-4-e2b-it-4bit ./Models/gemma-4-e4b-it-4bit
hf download mlx-community/gemma-4-e2b-it-4bit --local-dir ./Models/gemma-4-e2b-it-4bit
hf download mlx-community/gemma-4-e4b-it-4bit --local-dir ./Models/gemma-4-e4b-it-4bit
```

Then add both folder references back into Xcode's `Copy Bundle Resources`.


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

If this skill needs to call native iOS APIs, register the tool in `Tools/ToolRegistry.swift` (and add a handler under `Tools/Handlers/`). The framework validates `allowed-tools` against the registry at startup, so any typo will surface immediately in the console.


## FAQ

Why are there no permission dialogs after install?
The corresponding Skill has likely not reached the system API call yet. If you previously denied permission, iOS will not prompt again — go to system Settings to re-enable.

Why does the model fail to load after switching?
Verify that the model directory name matches `availableModels` in code, that the model has finished downloading on-device if you are using the shell-only install flow, or that it was actually included in the app bundle if you are shipping it built-in, and that the device has enough memory.

Why does creating a reminder fail?
The latest code first attempts to reuse an existing writable reminder list. If none is found, it tries to automatically create a PhoneClaw list. If that also fails, the system reminder source itself is likely read-only.

## Roadmap

### 1. More iOS native APIs

- File and directory access
- Photos — reading, organizing, describing, searching
- Notes
- Local notifications
- Maps and location
- Safari / URL opening and context passing
- More read/write coverage for contacts, calendar, and reminders

### 2. More Skills

Continue breaking capabilities into focused Skills rather than embedding all logic in a single large prompt. Directions worth adding:

- File management
- Photo understanding and organization
- Schedule planning
- Personal information management
- Local knowledge base search
- Voice input / text-to-speech

### 3. More local models

Beyond the main chat model, suitable additions include:

- OCR model
- Speech recognition model
- Speech synthesis model
- Embedding / Reranker model
- A smaller tool argument extraction model
- A stronger planning model or multi-model pipeline

This moves PhoneClaw from "one big model doing everything" toward "multiple local models working together."

### 4. Cross-app automation

PhoneClaw will not assume desktop-style control over arbitrary apps. Instead it will use what iOS actually allows:

- App Intents / Shortcuts
- URL Scheme / Deep Link
- Share Sheet extensions
- Clipboard relay
- System notifications and app launching

A realistic goal: pass content between apps, open a specific app to a specific screen, and compress multi-step operations into a single natural language command.

### 5. External hardware and visual input

Explore connecting external video input and screen understanding with local models, so PhoneClaw goes beyond answering questions in isolation and develops stronger real-world perception and scheduling capabilities.


## References

- [Hugging Face CLI documentation](https://huggingface.co/docs/huggingface_hub/guides/cli)
- [Hugging Face download guide](https://huggingface.co/docs/huggingface_hub/en/guides/download)
- [Gemma 4 E2B MLX model](https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit)
- [Gemma 4 E4B MLX model](https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit)
- [Gemma 4 E2B (ModelScope mirror)](https://modelscope.cn/models/mlx-community/gemma-4-e2b-it-4bit)
- [Gemma 4 E4B (ModelScope mirror)](https://modelscope.cn/models/mlx-community/gemma-4-e4b-it-4bit)

## License

Apache 2.0
