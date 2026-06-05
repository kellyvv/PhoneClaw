---
name: Web検索
name-zh: 联网搜索
description: '公開Webページを無料で検索し、読み取り可能なページ本文を取得します。最新情報、ニュース、Web上の参照が必要なときに使います。'
version: "1.0.0"
icon: magnifyingglass
disabled: false
type: network
requires-time-anchor: true
chip_prompt: "Webで検索: 最新の人工知能ニュース"
chip_label: "Web検索"

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
  - Web検索
  - 検索して
  - ネットで
  - オンライン
  - 最新
  - ニュース
  - 公式サイト
  - ウェブページ
  - URL

allowed-tools:
  - web-search
  - web-fetch

examples:
  - query: "Webで検索: 最新の人工知能ニュース"
    scenario: "最新情報を検索"
  - query: "OpenAI の最新ニュースを調べて"
    scenario: "最新ニュースを検索"
  - query: "このページを読んで要約して: https://example.com"
    scenario: "公開Webページを取得"

# Sync anchor (see scripts/check-skill-sync.sh):
translation-source-commit: f68df9b
translation-source-sha256: 4280bb053488ffa38d74db789a1fdc59f5dc2f259a2fc8025905cc33d5d8156a
---

# Web検索

ユーザーが現在の情報、最新ニュース、報道、オンライン参照、公式サイト情報、またはWebページ本文を明確に必要としている場合だけ、公開Web情報を取得します。

## 利用可能なツール

- **web-search**: 公開Webページを無料で検索する。パラメータ: `query` 必須; `max_results` 任意、既定 5、最大 8。
- **web-fetch**: 公開Webページから読み取り可能なテキストを取得する。パラメータ: `url` 必須; `max_characters` 任意、既定 6000、最大 12000。

## いつ使うか

1. ユーザーが明示的に「オンライン」「Web」「Webで検索」「最新」「ニュース」「現在」「公式サイト」などと言う、またはライブ/Web情報を求めている場合は `web-search` を呼び出す。
2. ユーザーがURLを提示し、それを読んで要約/説明/抽出するよう求めた場合は `web-fetch` を呼び出す。
3. 一般知識、概念説明、雑談、文章作成、翻訳、会話履歴に基づく質問ではオンラインに行かない。直接回答するか、別の Skill を使う。

## 検索フロー

1. ユーザーの要求を簡潔な検索クエリにする。元の主題、場所、時間表現は保持する。"today/latest/current" を機械的に年へ置き換えたり、ユーザーが指定した相対時刻を削除したりしない。明示的な日付や範囲がある場合だけ保持する。
2. 既定では `web-search` を `max_results` = 5 で呼び出す。
3. まず検索結果が実際に質問へ答えているか判断する。結論を直接支える `confidence=high/medium` の結果を優先する。
4. 結果に `needs_fetch=true`、`confidence=low`、`is_homepage_like=true` がある場合、またはスニペットだけでは結論を支えられない場合は、それを事実として提示しない。最も関連する結果を選び、`web-fetch` でページを読む。
5. ユーザーが特定ページの要約を求めている場合は、直接 `web-fetch` を呼び出す。
6. 同じターンで取得するWebページは最大1つ。複数ページを繰り返し取得しない。証拠がまだ不足する場合は、十分に検証できる結果が見つからなかったと伝える。

## 回答要件

- ツールが返したタイトル、スニペット、ページ本文、URLだけに基づいて答える。ツールが返していない詳細を作らない。
- 回答にはソースリンクまたはソース名を残す。現在情報では、可能なら検索時刻または結果時刻に触れる。
- 証拠が結論を支える場合は結論から始める。証拠が不足する場合は「この検索では十分に検証できる結果が見つかりませんでした。」と伝える。
- 使える結果ごとに「事実/更新内容 + ソース + 日付/検索時刻 + URL」を一行で示す。
- 無料検索ソースがレート制限、結果なし、ページ読み取り不可、低信頼結果のみの場合は、今はライブ検索で十分に使える結果がないと明確に言う。古い知識を現在情報のように見せない。
- 特定の製品、モデル、企業リリースについては、ツールが返した一次情報、公式情報、ページ本文の証拠を優先する。検証可能なソースがない場合は未確認と伝える。
- 医療、法律、金融、政策の質問では、検索結果を要約し、元ソースの確認を勧める。

## 呼び出し形式

<tool_call>
{"name": "web-search", "arguments": {"query": "search query", "max_results": 5}}
</tool_call>

<tool_call>
{"name": "web-fetch", "arguments": {"url": "https://example.com", "max_characters": 6000}}
</tool_call>
