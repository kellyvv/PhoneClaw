---
name: Web Search
name-zh: 联网搜索
description: '免费联网搜索公开网页并读取网页正文, 用于获取实时信息、最新消息和网页资料。'
version: "1.0.0"
icon: magnifyingglass
disabled: false
type: network
requires-time-anchor: true
chip_prompt: "联网搜索今天的 AI 新闻"
chip_label: "联网搜索"

triggers:
  - 联网搜索
  - 上网搜索
  - 网页搜索
  - 搜索网页
  - 网上查
  - 网上搜
  - 上网查
  - 实时信息
  - 最新消息
  - 新消息
  - 最新新闻
  - 新闻
  - 官网
  - 读取网页
  - 打开网页
  - web search
  - search web
  - search online
  - online search
  - latest
  - current
  - news
  - https://
  - http://
  - webpage
  - url

allowed-tools:
  - web-search
  - web-fetch

examples:
  - query: "联网搜索今天的 AI 新闻"
    scenario: "搜索实时信息"
  - query: "帮我查一下 OpenAI 最近有什么新消息"
    scenario: "搜索最新消息"
  - query: "读取这个网页并总结: https://example.com"
    scenario: "读取公开网页"
---

# 联网搜索

你负责在用户明确需要实时信息、最新消息、新闻、网上资料、官网信息或网页正文时联网检索公开网页。

## 可用工具

- **web-search**: 免费搜索公开网页。参数: `query` 必填; `max_results` 可选, 默认 5, 最多 8。
- **web-fetch**: 读取公开网页正文。参数: `url` 必填; `max_characters` 可选, 默认 6000, 最多 12000。

## 何时使用

1. 用户明确说"联网/上网/网上查/网页搜索/最新/新闻/实时/官网"等实时或网页意图 → 调用 `web-search`。
2. 用户给出 URL 并要求读取、总结、解释、提取信息 → 调用 `web-fetch`。
3. 用户只问常识、概念解释、闲聊、写作、翻译或基于对话历史的问题 → 不要联网, 直接回答或交给其他 Skill。

## 搜索流程

1. 把用户需求整理成简洁搜索词, 保留用户原始的主体、地点和时间表达。不要把"今天/最新/current/today"机械改写成年份, 也不要删除用户给出的相对时间；只有在用户明确指定日期/范围时才把它保留进搜索词。
2. 默认调用 `web-search`, `max_results` 取 5。
3. 先判断结果是否能回答用户问题：优先使用 `confidence=high/medium` 且摘要能直接支持结论的结果。
4. 如果结果标记 `needs_fetch=true`、`confidence=low`、`is_homepage_like=true`, 或摘要不足以支撑结论, 不要直接总结成事实；选择最相关的一条调用 `web-fetch` 读取正文。
5. 如果用户要求总结某个具体网页, 直接调用 `web-fetch`。
6. 同一轮最多读取一个网页。不要连续读取多个网页；如果仍证据不足, 明确说明没有足够可核验结果。

## 回答要求

- 必须基于工具返回的标题、摘要、正文和 URL 回答, 不要编造工具没有给出的细节。
- 回答中保留来源链接或来源名称; 涉及实时信息时说明搜索时间或结果时间。
- 先给结论: 能回答就直接回答; 证据不足就说"这次搜索没有返回足够可核验结果"。
- 对可用结果, 用一行说明"事实/进展 + 来源 + 日期/搜索时间 + URL"。
- 如果免费搜索来源被限流、没有结果、网页不可读或只有低置信结果, 明确告诉用户"实时搜索暂时没有足够可用结果", 不要用旧知识假装最新。
- 如果用户问的是具体产品/模型/公司发布, 优先使用工具返回的原始来源、官方来源或正文证据；没有可核验来源时, 明确说未确认。
- 对医疗、法律、金融、政策等高风险问题, 只概括搜索结果并建议用户核对原始来源。

## 调用格式

<tool_call>
{"name": "web-search", "arguments": {"query": "搜索关键词", "max_results": 5}}
</tool_call>

<tool_call>
{"name": "web-fetch", "arguments": {"url": "https://example.com", "max_characters": 6000}}
</tool_call>
