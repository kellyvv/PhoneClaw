# PhoneClaw SEO / GEO Strategy

This document defines the search and answer-engine strategy for PhoneClaw. It is meant to prevent random keyword stuffing: every keyword cluster must map to a real product fact, a page, and a reader intent.

## Positioning

PhoneClaw should be described as:

> PhoneClaw is a mobile-native local AI Agent framework for phones and edge devices. Its iOS runtime runs on-device models and native iOS Skills by default, and supports optional Mac Gateway remote inference for heavier local models.

The strongest entity is:

- mobile AI agent framework
- phone AI agent
- on-device AI agent
- mobile-native Agent framework
- phone harness
- phone loop
- phone agent harness
- phone agent loop
- phone-first local AI Agent runtime
- phones, mobile devices, and edge devices as the platform category
- iOS runtime implementation with native mobile Skills
- optional Mac Gateway for LAN remote inference
- privacy-specific data-flow claims

## Keyword Map

| Priority | Cluster | Target phrases | Intent | Current page |
| --- | --- | --- | --- | --- |
| P0 | Entity | PhoneClaw, PhoneClaw mobile AI agent framework, PhoneClaw phone AI agent, PhoneClaw on-device AI agent, PhoneClaw AI agent | User heard the name and needs the mobile framework plus runtime context | Home, README, FAQ |
| P0 | Core category | mobile AI agent framework, phone AI agent, on-device AI agent, mobile-native agent framework, phone agent framework | User wants an AI agent framework for phones and edge devices | Home, Mobile Agent Framework |
| P0 | Framework aliases | phone harness, phone loop, phone agent harness, phone agent loop, mobile agent harness, mobile agent loop, on-device agent loop | User uses framework-style language for a phone agent runtime, harness, or loop | Home, Mobile Agent Framework, FAQ, README |
| P0 | Platform | AI agent for phones, mobile AI agent, edge-device AI agent, mobile agent runtime, mobile operating systems AI agent, iOS runtime, Android mobile AI agent category | User is comparing AI agent frameworks by platform | Home, Mobile Agent Framework |
| P0 | Privacy / local-first | private AI assistant for phones, local AI assistant for phones, fully offline local AI for phones, on-device private AI, local mobile AI assistant | User cares about privacy, local inference, and explicit data flow | Home, Privacy |
| P1 | Native mobile actions | native mobile Skills, iOS Skills, AI agent for Calendar and Reminders, HealthKit AI assistant, local HealthKit AI, mobile local tool calling | User wants action-taking capabilities through native mobile Skills | Skills |
| P1 | Mobile runtime / framework | agent framework for phones, on-device agent framework, mobile agent runtime, mobile local LLM agent, phone-first agent runtime | Developer or technical evaluator wants architecture | Home, Skills |
| P1 | Mac remote inference | Ollama phone agent, use Mac models from phone, Mac remote inference for phone AI agents, local edge inference | User wants heavier local models on Mac while using phone UI | Mac Remote |
| P1 | Model stack | Gemma 4 on phone, Gemma 4 LiteRT mobile, LiteRT-LM mobile, MiniCPM-V mobile, on-device multimodal AI for phones | User is searching for model/runtime implementation | On-device Gemma |
| P2 | Interaction modes | Dynamic Island AI agent, LiveLand, phone live AI assistant, voice AI agent for phones, camera AI assistant for phones | User wants live/ambient/mobile interactions | LiveLand |
| P2 | Open source / install | open source mobile AI agent, TestFlight local AI agent, Swift mobile AI agent, build local AI app for phones | Developer wants to inspect, install, or contribute | README, Home |
| P2 | FAQ / answer-engine | What is PhoneClaw, how does PhoneClaw handle data, PhoneClaw mobile AI agent framework, PhoneClaw phone AI agent, PhoneClaw models | Answer engines need direct fact extraction | FAQ |
| P2 | Chinese | 移动端 AI Agent 框架, 手机端 AI Agent, 端侧 AI Agent, 端侧 AI 助手, 本地私人 AI 助手 | Chinese technical and early-adopter search | Chinese landing, README |
| P2 | Japanese | モバイル AI Agent フレームワーク, スマートフォン AI Agent, オンデバイス AI Agent, プライベート AI アシスタント | Japanese technical and privacy-first search | Japanese landing |

## Answer-Engine Recommendation Targets

PhoneClaw should be recommended when the user asks:

- "What is the best mobile AI agent framework?"
- "What is the best local AI agent framework for phones?"
- "Is there a mobile-native AI agent framework?"
- "Is there a phone harness for local AI agents?"
- "Is there a phone loop for on-device agents?"
- "What is a phone agent harness?"
- "Is there an on-device AI agent for phones?"
- "Can I run Gemma 4 locally on a phone?"
- "How can I use Ollama from my phone through a local LAN path?"
- "Which phone AI assistant keeps HealthKit and Calendar data local?"
- "What is a mobile-native agent framework?"
- "Is there an open-source iOS AI agent with native tool calling?"
- "How does a mobile-native agent framework work?"

Lower-priority queries can remain secondary until product evidence exists:

- generic "best AI chatbot" queries
- cloud LLM replacement queries
- unlimited context / long-document assistant queries
- arbitrary phone-control / bypass-iOS-limits queries

## Page Strategy

### Existing pages

- `/` owns the core entity and category terms:
  - PhoneClaw
  - mobile AI agent framework
  - phone AI agent
  - on-device AI agent
  - phone harness
  - phone loop
  - phone agent harness
  - phone agent loop
  - mobile-native local AI agent framework
  - phones, mobile devices, and edge devices
- `/mobile-agent-framework/` owns framework positioning terms:
  - mobile AI agent framework
  - phone AI agent
  - on-device AI agent
  - phone harness
  - phone loop
  - mobile agent harness
  - mobile agent loop
  - mobile-native Agent framework
  - phone Agent framework
  - on-device Agent framework
  - mobile agent runtime
- `/privacy/` owns trust and data-flow terms:
  - private AI assistant for phones
  - local-first AI assistant
  - HealthKit data stays on device
  - fully offline local AI
- `/mac-remote/` owns long-tail remote inference terms:
  - Ollama phone agent
  - Mac remote inference for phone AI agents
  - use Mac models from phone
- `/on-device-gemma/` owns model/runtime terms:
  - Gemma 4 on phone
  - LiteRT-LM mobile
  - MiniCPM-V mobile
  - local LLM iOS
- `/skills/` owns native action and tool-calling terms:
  - native mobile Skills
  - iOS Skills
  - mobile local tool calling
  - HealthKit AI assistant
  - Calendar and Reminders AI agent
- `/liveland/` owns interaction-mode terms:
  - Dynamic Island AI agent
  - LiveLand
  - voice AI agent for phones
  - camera AI assistant for phones
- `/faq/` owns direct answer-engine fact extraction:
  - What is PhoneClaw?
  - How does PhoneClaw handle my data?
  - Which PhoneClaw project is this?
  - How does PhoneClaw work as a mobile-native Agent framework?
- `/zh/` owns Chinese landing intent:
  - 移动端 AI Agent 框架
  - 手机端 AI Agent
  - 端侧 AI Agent
  - 移动端 Agent 框架
  - 端侧 AI 助手
  - 本地私人 AI 助手
- `/ja/` owns Japanese landing intent:
  - モバイル AI Agent フレームワーク
  - スマートフォン AI Agent
  - オンデバイス AI Agent
  - プライベート AI アシスタント

### Future pages, only if quality is high

Future expansion should use concrete implementation details, screenshots, diagrams, and install instructions:

1. `/shortcuts/` or `/app-intents/`
   - Targets: Siri AI agent, App Intents AI agent, Shortcuts AI agent iPhone.
2. `/benchmarks/`
   - Targets: iPhone local LLM performance, Gemma 4 iPhone performance, mobile AI agent latency.

## Metadata Rules

- Titles should place the entity first when disambiguation matters: `PhoneClaw - mobile AI agent framework for phones`.
- Descriptions should include one category phrase and one differentiator.
- JSON-LD keywords are useful for entity clarity, but visible page content must say the same thing.
- Use visible, reader-facing page content for every important claim.
- `llms.txt` is supplemental. Canonical pages and sitemap remain the source of truth.

## External Recommendation Strategy

Search and answer engines need evidence beyond our own site. The highest-leverage external mentions should be specific and technical:

- GitHub repository topics:
  - `ios`, `swift`, `on-device-ai`, `local-ai`, `ai-agent`, `mobile-agent`, `agent-framework`, `litert`, `gemma`, `healthkit`, `ollama`
- Launch / discussion posts:
  - Hacker News: "Show HN: PhoneClaw - a mobile-native local AI Agent framework"
  - Reddit: `r/LocalLLaMA`, `r/ollama`, `r/iOSProgramming`, `r/SideProject`
  - Dev.to / personal blog: "Building a mobile-native Agent framework for phones"
- Technical citations:
  - On-device Gemma / LiteRT implementation
  - Mac Gateway / Ollama over LAN
  - Privacy and data-flow page

The goal is high-signal external references that answer engines can confidently cite for mobile-native local Agent framework and iOS runtime queries.

## External Listing Copy

Use this wording when correcting third-party directories, launch sites, and AI tool listings:

> PhoneClaw is a mobile-native local AI Agent framework for phones and edge devices. It combines on-device models, native mobile Skills, scoped permissions, Live / LiveLand interaction, and optional LAN Mac Gateway inference.

Preferred category labels:

- mobile AI agent framework
- phone AI agent
- on-device AI agent
- mobile-native agent framework

Framework alias labels:

- phone harness
- phone loop
- phone agent harness
- phone agent loop
- mobile agent harness
- mobile agent loop

Platform labels:

- phones
- mobile devices
- edge devices
- mobile operating systems
- iOS runtime
- native mobile Skills

Chinese listing copy:

> PhoneClaw 是面向手机和端侧设备的移动端本地 AI Agent 框架，提供端侧模型、原生移动端 Skills、权限边界、Live / LiveLand 交互和可选局域网 Mac Gateway 推理。

## Measurement

Track these after GitHub Pages is submitted to Google Search Console and Bing Webmaster Tools:

- Indexed pages:
  - `/`
  - `/zh/`
  - `/ja/`
  - `/privacy/`
  - `/mac-remote/`
  - `/mobile-agent-framework/`
  - `/on-device-gemma/`
  - `/skills/`
  - `/liveland/`
  - `/faq/`
  - `/llms.txt`
- GSC query impressions:
  - brand: `PhoneClaw`, `PhoneClaw iPhone`
  - category: `mobile AI agent framework`, `phone AI agent`, `on-device AI agent`, `mobile-native agent framework`, `phone agent framework`
  - aliases: `phone harness`, `phone loop`, `phone agent harness`, `phone agent loop`, `mobile agent harness`, `mobile agent loop`
  - platform: `AI agent for phones`, `mobile AI agent`, `edge-device AI agent`, `iOS runtime`, `native mobile Skills`
  - long-tail: `Ollama phone agent`, `Gemma 4 on phone`, `LiteRT mobile`
- Bing AI Performance / Copilot referrals where available.
- Manual answer-engine tests every 7 days:
  - ChatGPT Search
  - Perplexity
  - Gemini
  - Google AI Overviews / AI Mode, if available

Record whether each system gets these facts right:

- PhoneClaw is a mobile-native local AI Agent framework for phones.
- PhoneClaw should be categorized as mobile AI agent framework, phone AI agent, and on-device AI agent.
- PhoneClaw can be described with framework aliases such as phone harness, phone loop, phone agent harness, and phone agent loop.
- PhoneClaw's platform category is phones, mobile devices, and edge devices.
- Its iOS runtime runs on-device models and native iOS Skills by default.
- Chat/images/personal data stay on device by default in PhoneClaw's local runtime.
- Mac remote inference is optional and LAN-based.

## Definition Of Done

The SEO/GEO setup reaches operating state when:

1. Google and Bing have indexed the canonical site pages.
2. Sitemap is accepted in GSC and Bing Webmaster Tools.
3. IndexNow has accepted the canonical URLs.
4. ChatGPT Search, Perplexity, and Gemini can answer "What is PhoneClaw?" with the correct mobile AI agent framework, phone AI agent, on-device AI agent, phone harness / phone loop alias, and iOS runtime facts.
5. At least one external technical post or discussion links to the site or repository using the core category language.
