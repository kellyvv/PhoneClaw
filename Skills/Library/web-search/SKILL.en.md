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
translation-source-commit: e61fd26
translation-source-sha256: 3696b06cbd9ab32d63fb1549a0e1a2b936d30ffec44cef0331d1093897412325
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

1. Turn the user's need into a concise search query, preserving the primary entity/event, time range, and location; for "latest/today/news" requests, include the current year or date by default. Treat "today", "today's", "latest", and "current" as time modifiers, not search subjects; for "today's AI news", search for "artificial intelligence news 2026" or "AI news June 1 2026", never "today" alone.
2. By default call `web-search` with `max_results` = 5.
3. First decide whether the results actually answer the user's question: usable news/fact entries should have a concrete title, event, source, and preferably a date.
4. If the user asks to summarize a specific webpage, or one search result is clearly the primary source but the snippet is insufficient, you may call `web-fetch` once for that URL.
5. If results are only homepages, category pages, search entry points, or site descriptions, do not present them as "latest news"; say no clearly verifiable item was found, and list those links only as sources to check.
6. If a result is labeled "related, not exact match", do not treat it as news about the object the user asked for.
7. Fetch at most one webpage in the same turn. Do not repeatedly fetch multiple pages.

## Answer Requirements

- Answer only from tool-returned titles, snippets, page text, and URLs. Do not invent details the tool did not provide.
- Keep source links or source names in the answer; for current information, mention the search time or result time when available.
- Start with the conclusion: either "Found X usable result(s)" or "This search did not return clearly verifiable latest information."
- For each usable result, use one line with "fact/update + source + date/search time + URL"; news, rumor, and release-related results must include the URL, and you must not repeat media self-descriptions or category blurbs.
- If free search sources are rate-limited, return no results, or a page cannot be read, clearly say that live search has no usable result right now. Do not use old knowledge while pretending it is current.
- For a specific product, model, or company release, prioritize official sites, official blogs, release notes, or concrete mainstream-media reports; if no official or dated source appears, say it is unconfirmed. Results using "unannounced/reported/rumor/allegedly/expected/may/could" wording must be treated as rumors or reports, not as released facts.
- For medical, legal, financial, or policy questions, summarize search results and advise the user to verify the original sources.

## Call Format

<tool_call>
{"name": "web-search", "arguments": {"query": "search query", "max_results": 5}}
</tool_call>

<tool_call>
{"name": "web-fetch", "arguments": {"url": "https://example.com", "max_characters": 6000}}
</tool_call>
