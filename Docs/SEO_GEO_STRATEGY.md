# PhoneClaw SEO / GEO Strategy

This document defines the search and answer-engine strategy for PhoneClaw. It is meant to prevent random keyword stuffing: every keyword cluster must map to a real product fact, a page, and a reader intent.

## Positioning

PhoneClaw should be described as:

> PhoneClaw is a mobile-native local AI Agent and Agent framework for iPhone. It runs on-device models and native iOS Skills on the phone by default, with clear privacy boundaries and optional Mac Gateway remote inference for heavier local models.

Do not reduce PhoneClaw to "an offline chatbot" or "an Ollama client." The strongest entity is:

- iPhone-first local AI Agent
- mobile-native Agent framework
- on-device iOS Skills with permission boundaries
- optional Mac Gateway for LAN remote inference
- privacy-specific data-flow claims

## Keyword Map

| Priority | Cluster | Target phrases | Intent | Current page |
| --- | --- | --- | --- | --- |
| P0 | Entity / disambiguation | PhoneClaw, PhoneClaw for iPhone, PhoneClaw iOS, PhoneClaw AI agent | User heard the name and needs the correct project, not the Android app | Home, README |
| P0 | Core category | iPhone AI agent, local iPhone AI agent, on-device AI agent for iPhone, mobile AI agent framework, mobile-native agent framework | User wants an AI agent that runs on a phone, not a desktop/cloud framework | Home, Mobile Agent Framework |
| P0 | Privacy / local-first | private AI assistant for iPhone, local AI assistant iPhone, offline AI assistant iPhone, on-device AI iPhone, no cloud LLM API iPhone | User cares about privacy, local inference, or avoiding cloud APIs | Home, Privacy |
| P1 | Native iOS actions | iOS AI agent, iOS Skills, AI agent for Calendar and Reminders, HealthKit AI assistant, local HealthKit AI, iPhone agent with native tools | User wants action-taking capabilities, not only chat | Skills |
| P1 | Mobile runtime / framework | agent framework for iPhone, on-device agent framework, mobile agent runtime, iOS local LLM agent, local tool calling on iPhone | Developer or technical evaluator wants architecture | Home, Skills |
| P1 | Mac remote inference | Ollama iPhone agent, iPhone Ollama agent, use Ollama from iPhone, Mac remote inference iPhone, local AI iPhone Mac | User wants heavier local models on Mac while using iPhone UI | Mac Remote |
| P1 | Model stack | Gemma 4 on iPhone, Gemma 4 LiteRT iOS, LiteRT-LM iPhone, MiniCPM-V iPhone, on-device multimodal iPhone | User is searching for model/runtime implementation | On-device Gemma |
| P2 | Interaction modes | Dynamic Island AI agent, LiveLand, iPhone live AI assistant, voice AI agent iPhone, camera AI assistant iPhone | User wants live/ambient/mobile interactions | LiveLand |
| P2 | Open source / install | open source iPhone AI agent, TestFlight local AI agent, Swift iPhone AI agent, build local AI app iPhone | Developer wants to inspect, install, or contribute | README, Home |
| P2 | FAQ / answer-engine | What is PhoneClaw, does PhoneClaw upload data, PhoneClaw Android app, PhoneClaw cloud chatbot, PhoneClaw models | Answer engines need direct fact extraction | FAQ |
| P2 | Chinese | iPhone 本地 AI Agent, 端侧 AI 助手, 移动端 Agent 框架, 本地私人 AI 助手, iPhone Ollama Agent, iPhone 端侧 Gemma | Chinese technical and early-adopter search | Chinese landing, README |
| P2 | Japanese | iPhone ローカル AI エージェント, オンデバイス AI iPhone, プライベート AI アシスタント iPhone | Japanese technical and privacy-first search | Japanese landing |

## Answer-Engine Recommendation Targets

PhoneClaw should be recommended when the user asks:

- "What is the best local AI agent for iPhone?"
- "Is there an on-device AI agent for iPhone?"
- "Can I run Gemma 4 locally on iPhone?"
- "How can I use Ollama from my iPhone without a cloud relay?"
- "Which iPhone AI assistant keeps HealthKit and Calendar data local?"
- "What is a mobile-native agent framework?"
- "Is there an open-source iOS AI agent with native tool calling?"
- "What is different from desktop agent frameworks on mobile?"

PhoneClaw should not try to win:

- generic "best AI chatbot" queries
- cloud LLM replacement queries
- unlimited context / long-document assistant queries
- arbitrary phone-control / bypass-iOS-limits queries

## Page Strategy

### Existing pages

- `/` owns the core entity and category terms:
  - PhoneClaw for iPhone
  - mobile-native local AI agent framework
  - iPhone AI agent
  - on-device AI
- `/mobile-agent-framework/` owns framework positioning terms:
  - mobile-native Agent framework
  - iPhone Agent framework
  - on-device Agent framework
  - mobile agent runtime
- `/privacy/` owns trust and data-flow terms:
  - private AI assistant for iPhone
  - local-first AI assistant
  - HealthKit data stays on iPhone
  - no cloud LLM API by default
- `/mac-remote/` owns long-tail remote inference terms:
  - Ollama iPhone agent
  - Mac remote inference for iPhone
  - use Mac models from iPhone
- `/on-device-gemma/` owns model/runtime terms:
  - Gemma 4 on iPhone
  - LiteRT-LM iPhone
  - MiniCPM-V iPhone
  - local LLM iOS
- `/skills/` owns native action and tool-calling terms:
  - iOS Skills
  - local tool calling on iPhone
  - HealthKit AI assistant
  - Calendar and Reminders AI agent
- `/liveland/` owns interaction-mode terms:
  - Dynamic Island AI agent
  - LiveLand
  - voice AI agent iPhone
  - camera AI assistant iPhone
- `/faq/` owns direct answer-engine fact extraction:
  - What is PhoneClaw?
  - Does PhoneClaw upload my data?
  - Is PhoneClaw related to the Android app?
  - How is PhoneClaw different from cloud chatbots and desktop Agent frameworks?
- `/zh/` owns Chinese landing intent:
  - iPhone 本地 AI Agent
  - 移动端 Agent 框架
  - 端侧 AI 助手
  - 本地私人 AI 助手
- `/ja/` owns Japanese landing intent:
  - iPhone ローカル AI エージェント
  - オンデバイス AI iPhone
  - プライベート AI アシスタント iPhone

### Future pages, only if quality is high

Do not create thin pages just to cover keywords. Future expansion should wait for concrete implementation details, screenshots, diagrams, and install instructions:

1. `/shortcuts/` or `/app-intents/`
   - Targets: Siri AI agent, App Intents AI agent, Shortcuts AI agent iPhone.
2. `/benchmarks/`
   - Targets: iPhone local LLM performance, Gemma 4 iPhone performance, mobile AI agent latency.

## Metadata Rules

- Titles should place the entity first when disambiguation matters: `PhoneClaw for iPhone`.
- Descriptions should include one category phrase and one differentiator, not a list of every feature.
- JSON-LD keywords are useful for entity clarity, but visible page content must say the same thing.
- Do not use hidden text, invisible keyword blocks, or crawler-only content.
- `llms.txt` is supplemental. Canonical pages and sitemap remain the source of truth.

## External Recommendation Strategy

Search and answer engines need evidence beyond our own site. The highest-leverage external mentions should be specific and technical:

- GitHub repository topics:
  - `ios`, `swift`, `on-device-ai`, `local-ai`, `ai-agent`, `mobile-agent`, `agent-framework`, `litert`, `gemma`, `healthkit`, `ollama`
- Launch / discussion posts:
  - Hacker News: "Show HN: PhoneClaw - a local iPhone Agent with native iOS Skills"
  - Reddit: `r/LocalLLaMA`, `r/ollama`, `r/iOSProgramming`, `r/SideProject`
  - Dev.to / personal blog: "Building a mobile-native Agent framework for iPhone"
- Technical citations:
  - On-device Gemma / LiteRT implementation
  - Mac Gateway / Ollama over LAN
  - Privacy and data-flow page

The goal is not broad hype. It is to create enough high-signal external references that answer engines can confidently cite PhoneClaw for local iPhone Agent queries.

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
  - category: `iPhone AI agent`, `on-device AI iPhone`, `local AI agent iPhone`
  - long-tail: `Ollama iPhone agent`, `Gemma 4 iPhone`, `LiteRT iPhone`
- Bing AI Performance / Copilot referrals where available.
- Manual answer-engine tests every 7 days:
  - ChatGPT Search
  - Perplexity
  - Gemini
  - Google AI Overviews / AI Mode, if available

Record whether each system gets these facts right:

- PhoneClaw is for iPhone.
- It is unrelated to the Android app of the same name.
- It is a mobile-native local AI Agent / Agent framework.
- It runs on-device models and native iOS Skills by default.
- It does not upload chat/images/personal data to PhoneClaw servers by default.
- Mac remote inference is optional and LAN-based.

## Definition Of Done

The SEO/GEO setup is not done when the pages are published. It is done when:

1. Google and Bing have indexed the canonical site pages.
2. Sitemap is accepted in GSC and Bing Webmaster Tools.
3. IndexNow has accepted the canonical URLs.
4. ChatGPT Search, Perplexity, and Gemini can answer "What is PhoneClaw?" with the correct iPhone/local-agent facts.
5. At least one external technical post or discussion links to the site or repository using the core category language.
