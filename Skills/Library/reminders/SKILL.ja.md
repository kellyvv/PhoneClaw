---
name: リマインダー
name-zh: 提醒事项
description: '新しいリマインダーを作成します。ユーザーが何かを覚えておきたい、ToDo を作りたい、通知してほしい場合に使います。'
version: "1.0.0"
icon: bell
disabled: false
type: device
requires-time-anchor: true
chip_prompt: "今夜8時にファイルを送るようリマインドして"
chip_label: "リマインダー"

triggers:
  - remind
  - reminder
  - todo
  - to-do
  - remember
  - alert
  - リマインド
  - リマインダー
  - Todo
  - ToDo
  - 覚えて
  - 通知
  - アラート

allowed-tools:
  - reminders-create

side_effects:
  level: write
  tools:
    reminders-create:
      level: write
      requires_explicit_intent: true
      confirmation: low_confidence

examples:
  - query: "今夜8時にファイルを送るようリマインドして"
    scenario: "新しいリマインダーを作成"

# Sync anchor (see scripts/check-skill-sync.sh):
translation-source-commit: afa08ec1
translation-source-sha256: d79dd0f8a2f9270ec43c0814b1d269881f858f50c832296935d88b36f29ab4a9
---

# リマインダー作成

ユーザーが新しいリマインダーを作成できるように支援します。**リマインダーの中心は「いつ通知するか」です。時刻のないリマインダーは意味がありません。**

## 利用可能なツール

- **reminders-create**: リマインダーを作成
  - `title`: **必須**。リマインダーのタイトル
  - `due`: **必須**。通知時刻。ユーザーの表現を**そのままコピー**する(例: "8pm tonight" / "10am tomorrow" / "3pm on May 3")。ツールが解析します。ISO 8601 に変換する必要はありません。
  - `notes`: 任意。メモ

## 実行フロー

1. ユーザー発話から `title` と `due` を抽出する
2. **`title` が欠けている場合**: 短く「何をリマインドしますか?」と聞く
3. **`due` が欠けている場合**: 短く「いつリマインドしますか?」と聞く
4. **両方が揃っている場合だけ** `reminders-create` を呼び出す。ユーザーの時間表現をそのまま `due` に入れる。変換不要
5. ツール成功後、リマインダーが作成されたことをユーザーに伝える(例:「設定しました: 明日の朝8時に牛乳を買う」)
6. `due` が提供される前に tool_call を出してはいけない

## 完了後の返信

- ツール成功後は、自然な一文で結果を確認する。ツール名、JSON、内部手順は言わない。
- ユーザーが気にする内容(リマインダー本文 + 時刻)を優先する。
- 例: "設定しました: 今夜8時にファイルを送る。"

## 呼び出し形式

ユーザーが言った時刻をそのまま `due` にコピーします。ツールが解析します:

<tool_call>
{"name": "reminders-create", "arguments": {"title": "Send the file", "due": "8pm tonight"}}
</tool_call>
