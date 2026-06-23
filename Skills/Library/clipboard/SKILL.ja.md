---
name: クリップボード
name-zh: 剪贴板
description: 'システムのクリップボード内容を読み書きします。ユーザーがクリップボードを読む、コピーする、または操作したいときに使います。'
version: "1.0.0"
icon: doc.on.clipboard
disabled: false
type: device
chip_prompt: "クリップボードを読んで"
chip_label: "クリップボード"

triggers:
  - clipboard
  - paste
  - copy
  - pasteboard
  - クリップボード
  - コピー
  - ペースト
  - 貼り付け

allowed-tools:
  - clipboard-read
  - clipboard-write

side_effects:
  level: read
  tools:
    clipboard-read:
      level: read
    clipboard-write:
      level: write
      requires_explicit_intent: true

examples:
  - query: "クリップボードを読んで"
    scenario: "クリップボードを読む"
  - query: "この文章をクリップボードにコピーして"
    scenario: "クリップボードに書き込む"

# Sync anchor (see scripts/check-skill-sync.sh):
translation-source-commit: afa08ec1
translation-source-sha256: ccaaf8896152a26a4c0edc9507edbec340c74900ea554ccc068c0a6b3b695d13
---

# クリップボード操作

ユーザーがシステムクリップボードを読み書きできるように支援します。

## 利用可能なツール

- **clipboard-read**: 現在のクリップボード内容を読む(パラメータなし)
- **clipboard-write**: クリップボードにテキストを書き込む(パラメータ: text — コピーするテキスト)

## 実行フロー

1. ユーザーが読むよう求めた場合 → `clipboard-read` を呼び出す
2. ユーザーがコピー/書き込みを求めた場合 → `clipboard-write` を呼び出し、text パラメータを渡す
3. 結果に基づいて、ユーザーへ簡潔に答える

## 完了後の返信

- クリップボードを読んだ場合: 内容を直接答える。ツール名や内部手順には触れない。
- クリップボードに書き込んだ場合: 「クリップボードにコピーしました。」と短く確認する。
- 内容が長い、またはテキストでない場合は、ツールの要約を自然に説明する。

## 呼び出し形式

<tool_call>
{"name": "clipboard-read", "arguments": {}}
</tool_call>

<tool_call>
{"name": "clipboard-write", "arguments": {"text": "text to copy"}}
</tool_call>
