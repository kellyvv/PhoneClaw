# PhoneClaw

[简体中文](./README.md)

PhoneClaw is a local AI agent that runs directly on iPhone.  
It uses **Gemma 4 + MLX + Metal GPU** for on-device inference, so chats and tool calls stay on the device by default.

## What It Is

PhoneClaw is an `LLM + SKILL` style local agent:

- the LLM decides what the user wants
- `SKILL.md` files describe how a capability should behave
- native tools execute the actual device-side action

Built-in native capabilities currently include:

- clipboard read/write
- device info
- text utilities
- calendar event creation
- reminders creation
- contacts create/update

## Highlights

- fully offline by default
- image input supported
- file-driven skill system
- multi-step tool calling
- built-in permissions page, system prompt editor, and model switcher
- memory-aware MLX runtime management for iPhone limits

## Requirements

- macOS + Xcode 16 or newer
- iOS 17.0 or newer
- CocoaPods
- an Apple developer signing identity for real-device testing

Model guidance:

- `Gemma 4 E2B`: better default choice for distribution
- `Gemma 4 E4B`: stronger but heavier, better for high-end devices

## Quick Start

### 1. Install dependencies

```bash
pod install
```

### 2. Download a model

PhoneClaw expects these exact folder names under `Models/`.

Install the Hugging Face CLI first:

```bash
brew install hf
```

or:

```bash
pip install -U "huggingface_hub"
```

Download only `E2B`:

```bash
mkdir -p ./Models/gemma-4-e2b-it-4bit
hf download mlx-community/gemma-4-e2b-it-4bit --local-dir ./Models/gemma-4-e2b-it-4bit
```

Download only `E4B`:

```bash
mkdir -p ./Models/gemma-4-e4b-it-4bit
hf download mlx-community/gemma-4-e4b-it-4bit --local-dir ./Models/gemma-4-e4b-it-4bit
```

Download both:

```bash
mkdir -p ./Models/gemma-4-e2b-it-4bit
mkdir -p ./Models/gemma-4-e4b-it-4bit
hf download mlx-community/gemma-4-e2b-it-4bit --local-dir ./Models/gemma-4-e2b-it-4bit
hf download mlx-community/gemma-4-e4b-it-4bit --local-dir ./Models/gemma-4-e4b-it-4bit
```

Notes:

- `Models/` is already ignored by Git
- the current Hugging Face repo sizes are roughly `3.58 GB` for `E2B` and `5.22 GB` for `E4B`
- you can also download files manually from the model pages if you prefer

### 3. Open the workspace

```bash
open PhoneClaw.xcworkspace
```

Always open the workspace, not the project file.

### 4. Configure signing and run

In Xcode:

1. select the `PhoneClaw` target
2. open `Signing & Capabilities`
3. choose your `Team`
4. set a unique `Bundle Identifier`
5. connect your iPhone
6. press `⌘R`

### 5. First launch

Inside the app:

- top-right puzzle icon: Skill manager
- top-right sliders icon: model settings / system prompt / permissions

It is recommended to enable these permissions first:

- Calendar
- Reminders
- Contacts

Then try:

- `What is this phone's device information?`
- `Remind me to send the file tonight at 8 PM`
- `Save Wang Zong's number 13812345678`

## How to Ship Only One Model

This is the most practical setup for distribution.

### Option A: Ship only `E2B`

Keep:

```text
Models/gemma-4-e2b-it-4bit
```

Remove:

```text
Models/gemma-4-e4b-it-4bit
```

Then do both of the following:

1. remove the unused model folder reference in Xcode with `Remove Reference`
2. verify `PhoneClaw > Build Phases > Copy Bundle Resources` only includes the model you want to ship

Finally, update [LLM/MLXLocalLLMService.swift](./LLM/MLXLocalLLMService.swift) so `availableModels` only contains the model(s) you actually distribute.  
Otherwise the configuration page will still show unavailable options.

### Option B: Ship both `E2B + E4B`

Keep both model folders and both Xcode resource references.  
Users can switch models from the in-app configuration page.

## Built-in Skills

| Skill | Tools |
| --- | --- |
| Clipboard | `clipboard-read`, `clipboard-write` |
| Device | `device-info`, `device-name`, `device-model`, `device-system-version`, `device-memory`, `device-processor-count` |
| Text | `calculate-hash`, `text-reverse` |
| Calendar | `calendar-create-event` |
| Reminders | `reminders-create` |
| Contacts | `contacts-upsert` |

## Custom Skills

The smallest way to add a new capability is to add a new `SKILL.md`:

```text
Application Support/PhoneClaw/skills/<skill-id>/SKILL.md
```

Example:

```yaml
---
name: MySkill
name-zh: 我的能力
description: What this skill does
version: "1.0.0"
icon: star
disabled: false

triggers:
  - keyword

allowed-tools:
  - my-tool-name

examples:
  - query: "How a user might ask for it"
    scenario: "When it should trigger"
---

# Skill instructions

Tell the model when to call tools, how to build arguments, and when to answer directly.
```

If the skill needs real native execution, register the tool in [Skills/ToolRegistry.swift](./Skills/ToolRegistry.swift).

## Key Directories

```text
PhoneClaw/
├── App/
├── Agent/
├── LLM/
├── Skills/
├── UI/
├── Models/
├── PhoneClaw.xcworkspace
└── README.md
```

## Runtime Flow

```text
User input
→ PromptBuilder
→ local Gemma 4 inference
→ load_skill when needed
→ read SKILL.md
→ execute native tool
→ produce final answer
```

## Useful Links

- Hugging Face CLI docs: <https://huggingface.co/docs/huggingface_hub/guides/cli>
- Hugging Face download guide: <https://huggingface.co/docs/huggingface_hub/en/guides/download>
- Gemma 4 E2B MLX model: <https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit>
- Gemma 4 E4B MLX model: <https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit>

## Roadmap

PhoneClaw is meant to grow into a genuinely useful on-device iPhone agent, not just a chat UI with a couple of tools.

### 1. More iOS native APIs

Planned areas include:

- files and folders
- photo reading, organization, and understanding
- Notes integration
- local notifications
- maps and location-related tasks
- Safari / URL handoff
- broader calendar, reminders, and contacts workflows

### 2. More Skills

The long-term direction is to keep capabilities modular through Skills instead of pushing everything into one giant prompt.

Likely next skills:

- file management
- photo understanding and organization
- schedule planning
- personal information management
- local knowledge retrieval
- voice input / voice output

### 3. More local models working together

Beyond the main chat model, good future additions include:

- OCR models
- speech recognition models
- text-to-speech models
- embedding / reranker models
- smaller argument-extraction models
- stronger planners or multi-model orchestration

That would move PhoneClaw from “one model does everything” toward a more practical local multi-model agent stack.

### 4. Cross-app automation

This is a key direction, but it needs to stay realistic within iOS security limits.  
The project is not assuming unrestricted UI control over every app. Instead, the practical path is:

- `App Intents`
- `Shortcuts`
- `URL Schemes / Deep Links`
- `Share Sheet / Share Extensions`
- clipboard handoff
- notification-driven flows

The goal is to make cross-app workflows feel natural while staying inside what iOS actually allows.

### 5. External hardware and visual expansion

Beyond the phone itself, PhoneClaw is also intended to explore workflows that involve external hardware.  
That may include combining external video input, on-device visual understanding, and local models so PhoneClaw can gradually move from “answering inside the phone” toward richer real-world perception and orchestration.

This part is intentionally kept a little vague for now.

### 6. Suggested priorities

If the goal is to improve real user value quickly, the strongest order is:

1. files / photos / notes
2. Shortcuts / App Intents integration
3. OCR + speech recognition
4. local knowledge retrieval
5. richer automation-oriented skill composition

## License

MIT
