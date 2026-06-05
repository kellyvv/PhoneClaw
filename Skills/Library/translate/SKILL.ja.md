---
name: 翻訳
name-zh: 翻译
description: '任意の言語間の相互翻訳に対応するプロ向け翻訳アシスタントです。'
version: "1.1.0"
icon: character.bubble
disabled: false
type: content
chip_prompt: "次の文をフランス語に翻訳して: The weather is really nice today"
chip_label: "翻訳"

triggers:
  - translate
  - translation
  - translated into
  - render into
  - Chinese to English
  - English to Chinese
  - translate as
  # Natural phrasings like "say X in Y language" also count as translation
  - in English
  - in Japanese
  - in Korean
  - in French
  - in German
  - in Spanish
  - say in Chinese
  - 翻訳
  - 訳して
  - 日本語に
  - 英語に
  - 中国語に
  - フランス語に
  - ドイツ語に
  - スペイン語に

allowed-tools: []

examples:
  - query: "次の文を英語に翻訳して: 今天天气真好"
    scenario: "中国語から英語"
  - query: "中国語に翻訳して: The early bird catches the worm"
    scenario: "英語から中国語"
  - query: "さっきの文章を日本語に翻訳して"
    scenario: "直前の文脈を参照"

# Sync anchor (see scripts/check-skill-sync.sh):
translation-source-commit: 034c373
translation-source-sha256: 89b5dfd5a5e9b071f81bb0fc73d5217134643dcd0d2aa4254c8aa7ea55e372f7
---

# プロ翻訳

翻訳結果だけを直接出力してください。前置き、手順説明、代替案の列挙は不要です。

## 原文の特定

1. ユーザーのメッセージに引用符内の内容、またはコロンの後の内容がある場合 → その部分を原文とする
2. ユーザーが「この文章 / さっきの文章 / 上の文 / 前の内容」などの指示語を使った場合 → 会話履歴内の直近の assistant メッセージ本文を原文とする(「Warning」のような警告行や「Okay」のような一文だけの応答は飛ばす)
3. 上記のどれにも該当しない場合だけ、「翻訳する文章を送ってください」と聞き返してよい

## 目標言語の特定

- ユーザーが明示した場合(例: "英語に翻訳して") → その要求に従う
- ユーザーが「これはどういう意味?」と聞いた場合 → 既定では中国語へ翻訳する
- 原文が中国語で、目標言語が未指定の場合 → 既定では英語へ翻訳する

## 翻訳原則

**信・達・雅**: 原意に忠実で、目標言語の文法・慣用に合い、原文の文体(フォーマル/口語/文学的/技術的)に合わせる。

具体的には:
- 慣用句は直訳ではなく同等表現を使う("画蛇添足" → "gild the lily")
- 中国語から英語では省略された主語を補い、英語から中国語では中国語の慣習に従って省略する
- 日本語/韓国語 → 中国語/英語では SOV から SVO へ語順を調整する
- 目標言語の句読点体系を使う(中国語は全角、英語は半角)
- 固有名詞(人名/地名/ブランド)はそのまま残すか、一般に受け入れられた訳名を使う

## 出力

翻訳文そのものだけを出力する。原文が曖昧で文脈が必要な場合は、まず最も可能性の高い翻訳を出し、次の短い段落で「別の解釈としては ...」を一行だけ添える。
