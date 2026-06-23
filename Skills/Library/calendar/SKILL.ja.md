---
name: カレンダー
name-zh: 日历
description: 'カレンダー予定の作成、予定照会、忙しさや空き時間の分析を行います。'
version: "1.1.0"
icon: calendar
disabled: false
type: device
requires-time-anchor: true
chip_prompt: "明日の午後2時にプロダクトレビュー会議を作成して"
chip_label: "予定を作成"

triggers:
  - calendar
  - event
  - meeting
  - appointment
  - schedule
  - book
  - agenda
  - availability
  - free time
  - busy
  - カレンダー
  - 予定
  - 会議
  - ミーティング
  - 日程
  - スケジュール
  - 空き時間
  - 忙しい

allowed-tools:
  - calendar-create-event
  - calendar-query-events

side_effects:
  level: read
  tools:
    calendar-create-event:
      level: write
      requires_explicit_intent: true
      confirmation: low_confidence
    calendar-query-events:
      level: read

examples:
  - query: "明日の午後2時にプロダクトレビュー会議を作成して"
    scenario: "カレンダー予定を作成"
  - query: "今日の予定を教えて"
    scenario: "今日の予定を照会"
  - query: "今週忙しいか分析して"
    scenario: "今週の予定を分析"

# Sync anchor (see scripts/check-skill-sync.sh):
translation-source-commit: afa08ec1
translation-source-sha256: ff0c503e4d2982f6a93861a2decdcee8071bb083853bd3fb12c817de382986b0
---

# カレンダー

以下のパラメータ規則に厳密に従ってください。勝手に補完せず、不要な確認質問もしないでください。

## ツール選択

- 会議、予定、アポイントメント、イベントを作成/追加/予約/スケジュールする → `calendar-create-event` を呼び出す
- 今日/明日/今週の予定やアジェンダを確認する → `calendar-query-events` を呼び出す
- 忙しさ、空き時間、都合がよい時間を分析する → まず `calendar-query-events` を呼び出し、返された `events` / `busy_minutes` / `free_windows` から要約する
- カレンダー予定を読まずに予定を作り上げてはいけません。必ず照会ツールを先に呼び出してください

## 照会と分析のパラメータ

`calendar-query-events` の引数:
- `period`: プリセット範囲。today=`today`, tomorrow=`tomorrow`, this week=`this_week`, next week=`next_week`, next 7 days=`next_7_days`
- `start`: ユーザーの日時/日付/時間帯表現をそのままコピーする。例: "today" / "tomorrow afternoon" / "June 3 2pm"
- `end`: ユーザーが明示的な終了範囲を指定した場合だけ含める
- `days`: "next N days" のような依頼では数値を使う
- `calendar`: ユーザーが特定のカレンダー名を言った場合だけ含める
- `limit`: 通常は省略
- `include_notes`: 通常 true を渡さない。ユーザーがメモ/詳細を明示的に求めた場合だけ true

よくある対応:
- "今日の予定は?" → `{"period":"today"}`
- "明日の午後は空いてる?" → `{"start":"tomorrow afternoon"}`
- "今週忙しい?" → `{"period":"this_week"}`
- "今後7日間の予定" → `{"period":"next_7_days"}`

照会後:
- 予定数、主要な予定、忙しさを短く要約する
- ユーザーが空いているか聞いた場合は `free_windows` を使う。十分な空き時間があればそう伝え、なければ衝突する時間帯を示す
- JSON、ツール名、内部フィールド名を出力しない

## 作成パラメータ

**必須パラメータ**(欠けている場合だけ短く一度確認する):
- `start`: ユーザー発話内の時間表現を**そのままコピー**する。ツールが解析します。
- `title`: 予定のタイトル/件名/内容

**任意パラメータ**(ユーザーが言っていなければ省略し、質問しない):
- `end`: 終了時刻(start と同じくそのままコピー)
- `location`: 場所
- `notes`: メモ

### start の抽出規則

ユーザー発話に時間の手がかりがあれば、`start` は提供済みとみなします。その表現をそのまま `start` に入れてください:
- 相対時刻: "tomorrow at 2pm" / "tonight at 8" / "noon the day after tomorrow"
- 絶対時刻: "May 3 at 15:00" / "evening of April 10"
- 機械形式: "2026-04-07T14:00:00"

**重要**: "tomorrow at 2pm" を "2026-04-XXTHH:MM:SS" に変換する必要はありません。ツールが解析します。
そのまま `"start": "tomorrow at 2pm"` と書いてください。手動変換は誤りやすいので避けます。

**禁止**: ユーザーが相対時刻をすでに言っているのに「何日ですか?」と聞かない。

ユーザーがまったく時間を言っていない場合(例: "会議を入れて")だけ、短く「いつですか?」と聞く。

### title の抽出規則

- ユーザー発話に名詞句("プロダクトレビュー会議" / "Lee さんと会う")があれば、そのまま title に使う
- "会議を入れて" / "明日3時に会議を入れて" のように内容がない場合だけ、一度だけ「何の会議ですか?」と聞く
- ユーザーの続き発話("プロダクトレビュー、デザインチームと")は title に統合する("プロダクトレビュー - デザインチーム")
- その後も曖昧な場合は title = "Meeting" にフォールバックし、二度目の確認はしない

### 複数ターンのパラメータ統合(重要)

必須パラメータが揃ったか判断するときは、現在の発話だけでなく会話履歴全体のユーザーメッセージを統合してください:

- 前のターン: ユーザーが "book a meeting at 3pm tomorrow" と言った → `start` は提供済み
- 今のターン: ユーザーが "product review, with design team" と言った → `title` も提供済み
- 両方揃った → すぐ tool_call を出し、`start` を聞き直さない

**アンチパターン**: 前ターンで時間、今ターンで議題をもらっているのに「いつ予定しますか?」と聞くこと。

### 作成時の動作

- 必須パラメータが両方揃っている(どのターンで提供されたかは問わない) → すぐ tool_call、説明不要
- 会話履歴全体で `start` または `title` が欠けている → 欠けている方だけ短く質問し、tool_call は出さない
- `end` / `location` / `notes` については質問しない

### 作成後の返信

- ツール成功後は、自然な一文で結果を確認する。ツール名、JSON、内部手順は言わない
- ユーザーが気にする内容(予定名 + 時刻)を優先する
- 例: "作成しました: プロダクトレビュー会議、明日の午後2時。"

## 呼び出し形式

ユーザーの時間表現をそのまま `start` に入れます。ツールが解析します:

<tool_call>
{"name": "calendar-create-event", "arguments": {"title": "Product review meeting", "start": "tomorrow at 2pm"}}
</tool_call>

<tool_call>
{"name": "calendar-query-events", "arguments": {"period": "today"}}
</tool_call>
