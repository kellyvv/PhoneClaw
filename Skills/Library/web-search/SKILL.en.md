---
name: Web Search
name-zh: 联网搜索
description: 'Search public webpages for free and fetch readable page text for current information, latest news, and web references.'
version: "1.0.0"
icon: magnifyingglass
disabled: false
type: network
requires-time-anchor: true
chip_prompt: "Search the web: latest artificial intelligence news"
chip_label: "Web Search"

triggers:
  - web search
  - search web
  - search online
  - online search
  - search the internet
  - latest
  - current
  - news
  - https://
  - http://
  - webpage
  - url
  - website
  - official site
  - read webpage
  - open webpage

allowed-tools:
  - web-search
  - web-fetch

examples:
  - query: "Search the web: latest artificial intelligence news"
    scenario: "Search current information"
  - query: "Look up the latest news about OpenAI"
    scenario: "Search latest news"
  - query: "Read and summarize this webpage: https://example.com"
    scenario: "Fetch a public webpage"

# Sync anchor (see scripts/check-skill-sync.sh):
translation-source-commit: f68df9b
translation-source-sha256: 4280bb053488ffa38d74db789a1fdc59f5dc2f259a2fc8025905cc33d5d8156a
---

# Web Search

You retrieve public web information only when the user clearly needs current information, latest news, news coverage, online references, official website information, or webpage text.

## Available Tools

- **web-search**: Search public webpages for free. Parameters: `query` required; `max_results` optional, default 5, max 8.
- **web-fetch**: Fetch readable text from a public webpage. Parameters: `url` required; `max_characters` optional, default 6000, max 12000.

## When To Use

1. If the user explicitly says "online", "web", "search the web", "latest", "news", "current", "official site", or otherwise asks for live/web information, call `web-search`.
2. If the user provides a URL and asks you to read, summarize, explain, or extract information from it, call `web-fetch`.
3. If the user asks general knowledge, conceptual explanations, casual chat, writing, translation, or questions based on conversation history, do not go online. Answer directly or use another Skill.

## Search Flow

1. Turn the user's need into a concise search query while preserving the user's original subject, location, and time expression. Do not mechanically rewrite "today/latest/current" into a year, and do not remove relative time expressions the user provided; only preserve explicit dates or ranges when the user gives them.
2. By default call `web-search` with `max_results` = 5.
3. First decide whether the results actually answer the user's question: prefer results with `confidence=high/medium` whose snippets directly support the conclusion.
4. If a result has `needs_fetch=true`, `confidence=low`, `is_homepage_like=true`, or the snippet is insufficient to support a conclusion, do not present it as fact; choose the most relevant result and call `web-fetch` to read the page.
5. If the user asks to summarize a specific webpage, call `web-fetch` directly.
6. Fetch at most one webpage in the same turn. Do not repeatedly fetch multiple pages; if evidence is still insufficient, say that no sufficiently verifiable result was found.

## Answer Requirements

- Answer only from tool-returned titles, snippets, page text, and URLs. Do not invent details the tool did not provide.
- Keep source links or source names in the answer; for current information, mention the search time or result time when available.
- Start with the conclusion when evidence supports it; if evidence is insufficient, say "This search did not return sufficiently verifiable results."
- For each usable result, use one line with "fact/update + source + date/search time + URL".
- If free search sources are rate-limited, return no results, a page cannot be read, or only low-confidence results are available, clearly say that live search has no sufficiently usable result right now. Do not use old knowledge while pretending it is current.
- For a specific product, model, or company release, prioritize original sources, official sources, or page-text evidence returned by the tools; if no verifiable source appears, say it is unconfirmed.
- For medical, legal, financial, or policy questions, summarize search results and advise the user to verify the original sources.

## Call Format

<tool_call>
{"name": "web-search", "arguments": {"query": "search query", "max_results": 5}}
</tool_call>

<tool_call>
{"name": "web-fetch", "arguments": {"url": "https://example.com", "max_characters": 6000}}
</tool_call>
