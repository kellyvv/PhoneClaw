<div align="center">

![banner](assets/banner.jpg)

A local AI Agent for iPhone. Offline. Private. Native.

![Swift](https://img.shields.io/badge/Swift-5.10-orange?style=flat-square)
![iOS](https://img.shields.io/badge/iOS-17%2B-blue?style=flat-square)
![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)

[中文](README.md) · [Report an Issue](https://github.com/kellyvv/phoneclaw/issues) · [Request a Feature](https://github.com/kellyvv/phoneclaw/issues)

</div>

PhoneClaw is a local AI Agent that runs entirely on your iPhone. No internet connection. No data uploads. No cloud dependency.

## Core Features

**Image Understanding (Multimodal)**: Take a photo or pick one from your library, then ask questions directly. Identify objects, read charts, describe scenes — all inference happens on your device, and your photos never leave your phone.

**File-Driven Skill System**: Each capability is defined by a single Markdown file (SKILL.md). Adding or modifying a skill requires no recompilation. Skills are language-agnostic — anyone can write and share them.

**100% Offline & Private**: All inference runs entirely on your iPhone. No network connections are made by default. Your conversations, images, and personal data are never uploaded or routed through any third-party server.

**Flexible Model Management**: Supports Gemma 4 E2B and E4B. Download models directly on your iPhone, or bundle them into the app at build time. Includes a built-in model switcher, system prompt editor, and automatic history trimming for iPhone memory constraints.

## Built-in Skills

**Calendar**: Create calendar events using natural language — title, time, and location all supported.

> "Schedule a meeting at Hightech Park tomorrow at 2pm"

**Reminders**: Set time-based reminders that fire a system push notification exactly on schedule.

> "Remind me tonight at 8 to send the file to my boss"

**Contacts**: Save or update contacts with name, phone, company, email, and notes. Automatically deduped by phone number.

> "Save Wang's number 13812345678, he's from Bytedance"

**Clipboard**: Read and write the system clipboard. Useful as a data relay in multi-step tasks.

> "Copy that text to the clipboard"

**Device Info**: Query device name, OS version, available memory, processor count, and more.

> "What's the device info for this phone?"

**Text Tools**: Hash calculation, text reversal, and other basic text utilities.

> "Calculate the MD5 of this text"


## Requirements

- macOS + Xcode 16 or later
- iOS 17.0 or later
- CocoaPods
- A real device with a developer account (Apple ID)

Model recommendation:

| Model | Use case |
|-------|----------|
| Gemma 4 E2B | More stable, recommended for general distribution, A16 and above |
| Gemma 4 E4B | Stronger output, higher memory usage, recommended for iPhone 15 Pro and above |

## Quick Start

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
What is this device's information?
Remind me tonight at 8 to send the file
Save Wang's phone number 13812345678
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
4. Edit `availableModels` in `LLM/MLXLocalLLMService.swift` to only include the models actually shipped (otherwise the settings page will show options that don't exist)

### Option C — Both E2B and E4B

Keep both directories, then manually add both folder references back into `Copy Bundle Resources`. Users can switch in the app's model settings page.

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

If this skill needs to call native iOS APIs, register the tool in `Skills/ToolRegistry.swift`.


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

### Suggested priority order

If ordered by "fastest path to meaningful experience improvement":

1. Files / Photos / Notes — three high-frequency API categories
2. Shortcuts / App Intents integration
3. OCR + speech recognition
4. Local knowledge base search
5. Finer-grained automated Skill orchestration

## References

- [Hugging Face CLI documentation](https://huggingface.co/docs/huggingface_hub/guides/cli)
- [Hugging Face download guide](https://huggingface.co/docs/huggingface_hub/en/guides/download)
- [Gemma 4 E2B MLX model](https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit)
- [Gemma 4 E4B MLX model](https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit)

## License

MIT
