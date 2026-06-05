---
name: 連絡先
name-zh: 通讯录
description: '連絡先を検索、作成、更新、削除します。電話番号の確認、連絡先詳細の表示、番号の保存、連絡先情報の入力、削除に使います。'
version: "1.1.0"
icon: person.crop.circle
disabled: false
type: device
chip_prompt: "John Smith 555-123-4567 を連絡先に追加して"
chip_label: "連絡先を追加"

triggers:
  - contact
  - contacts
  - phone number
  - address book
  - save number
  - contact info
  - delete contact
  - 連絡先
  - 電話番号
  - アドレス帳
  - 番号を保存
  - 連絡先情報
  - 連絡先を削除

allowed-tools:
  - contacts-search
  - contacts-upsert
  - contacts-delete

examples:
  - query: "John Smith 555-123-4567 を連絡先に追加して"
    scenario: "連絡先を作成または更新"
  - query: "Sarah Lee の電話番号は?"
    scenario: "連絡先の電話番号を検索"
  - query: "John Smith を連絡先から削除して"
    scenario: "連絡先を削除"

# Sync anchor (see scripts/check-skill-sync.sh):
translation-source-commit: 034c373
translation-source-sha256: 68c61e791b64028f30754419ba40b49d8595ef64bb9e6e36223cf5e73411eaae
---

# 連絡先の検索と管理

ユーザーがアドレス帳の連絡先を検索、作成、更新、削除できるように支援します。

## 利用可能なツール

- **contacts-search**: 連絡先を検索
  - `query`: キーワード。あいまい検索に使える
  - `name`: 連絡先名
  - `phone`: 電話番号
  - `email`: メールアドレス
  - `identifier`: 連絡先識別子
- **contacts-upsert**: 連絡先を作成または更新
  - `name`: 必須。連絡先名
  - `phone`: 任意。電話番号。指定されていれば重複判定で優先される
  - `company`: 任意。会社名
  - `email`: 任意。メールアドレス
  - `notes`: 任意。メモ
- **contacts-delete**: 連絡先を削除
  - `query`: キーワード。あいまい検索に使える
  - `name`: 連絡先名
  - `phone`: 電話番号
  - `email`: メールアドレス
  - `identifier`: 連絡先識別子

## 実行フロー

**削除リクエスト(重要 — 必ず2段階):**

1. ユーザーが「X を削除」と言い、**名前だけ**を指定している場合(電話番号/メールなど一意な識別子がない場合):
   - **最初に必ず `contacts-search` を呼び出す**。`name` をパラメータにして、一致件数を確認する
   - **いきなり `contacts-delete` を呼び出してはいけない**。同姓同名があり得るため、誤削除の危険がある
   - **質問だけに頼らない**。まず検索して実データを見てから進める
2. ユーザーが一意な識別子(電話番号 / メール / 名前+会社など)を指定した場合は、正確なパラメータで `contacts-delete` を直接呼び出す
3. 検索結果が2件以上なら、「複数候補の確認」セクションに従ってどれかを尋ね、回答を得てから `contacts-delete` を呼び出す
4. 検索結果が1件なら、その候補の電話番号を使って `contacts-delete` を直接呼び出す

**その他の操作:**

5. 電話番号、メール、連絡先情報の照会: `contacts-search` を呼び出す
6. 保存、追加、更新: `contacts-upsert` を呼び出す
7. 照会ではできるだけ `name` を抽出し、不明なら `query` を使う
8. 保存/更新では name, phone, company, email, notes を抽出する
9. 保存に必須の `name` が欠けている場合だけ、短く質問する
10. ツール成功後は、結果を日本語で簡潔に返す

## 完了後の返信

- 検索: 見つかった連絡先情報だけを伝える。ツール名、JSON、内部手順は言わない。
- 作成/更新: 「X を連絡先に保存しました。」と短く確認する。
- 削除: 「X を削除しました。」または「N 件の連絡先を削除しました: ...」と短く確認する。
- 見つからない場合やユーザーの選択が必要な場合は、次の手順を自然な一文で説明する。

## 複数候補の確認

### 複数候補が見つかった場合

`contacts-search` または `contacts-delete` の結果が複数候補(matches > 1)を示した場合、エラーにしたり勝手に1つ選んだりしない。次の形式でユーザーに確認する:

> 複数の [name] が見つかりました:
> (1) [phone1] · [extra info]
> (2) [phone2] · [extra info]
>
> どれですか? 番号、電話番号の下4桁、または「全部」と答えてください。

**候補を返信内に残すこと**。次のユーザーターンで参照するために必要です。

### ユーザーが確認に回答した場合(重要)

前のターンで「どれですか?」と尋ねた直後なら、現在のユーザーメッセージはその回答です。再度質問せず、意味を解釈して**同じツールを再呼び出し**します:

| ユーザーの回答 | 意味 | 呼び出し方 |
|---|---|---|
| 完全な電話番号 `5551234567` | 正確に選択 | `phone` パラメータに完全な番号を渡す |
| 下4桁 `4567` / "4567で終わる番号" | あいまいに絞り込み | `query` パラメータに末尾の数字を渡す |
| `1` / `(1)` / "1番目" | N番目の候補を選択 | 前ターンの N 番目候補の電話番号を `phone` として使う |
| "全部" / "両方" / "全員削除" | すべて削除 | **`contacts-delete` を1回だけ呼び出し**、元の `name` を保ち、`all: true` を追加する。手動ループは禁止 |
| その他の情報(会社、メモ、関係など) | ツールでは精密照合できない | 電話番号または候補番号を尋ねる。これらをツールパラメータに渡さない |

**重要 — 一括削除は単一 tool_call**:

ユーザーが「全部削除」「両方」と言った場合の正しい方法:
<tool_call>
{"name": "contacts-delete", "arguments": {"name": "John Smith", "all": true}}
</tool_call>

ツールが `deletedCount=2, deletedNames=...` を返したら、「John Smith という連絡先を2件削除しました: ...」と正確に返せます。**1件ずつ削除する複数 tool_call を出してはいけません**。

例(ユーザーが "5551234" と答えた場合):
<tool_call>
{"name": "contacts-delete", "arguments": {"name": "John Smith", "phone": "5551234"}}
</tool_call>

### ユーザーがキャンセルした場合

複数候補確認中にユーザーが「やめて」「削除しない」「キャンセル」「もういい」など、続行しない意思を自然言語で示した場合は、短く了承し(例:「わかりました、キャンセルしました」)、**tool_call を出さない**。

キャンセル意図の判断は文脈理解に基づいて行う。固定キーワードだけに頼らない。

### 実行結果を作り上げない

実際にツールを呼び出していない場合、**絶対に**「削除しました」「追加しました」「更新しました」と言ってはいけません。
- 実際の `<tool_call>` を出す
- または追加情報が必要/操作がキャンセルされたことを正直に伝える
- ツール未実行で「完了」とだけ言うのは禁止

## 呼び出し形式

<tool_call>
{"name": "contacts-search", "arguments": {"name": "Sarah Lee"}}
</tool_call>

<tool_call>
{"name": "contacts-upsert", "arguments": {"name": "John Smith", "phone": "5551234567", "company": "Acme"}}
</tool_call>

<tool_call>
{"name": "contacts-delete", "arguments": {"name": "John Smith"}}
</tool_call>
