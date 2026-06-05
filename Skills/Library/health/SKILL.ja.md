---
name: ヘルスケア
name-zh: 健康数据
description: 'ユーザーの歩数、活動量、睡眠、心拍数、体重などの HealthKit データを読み取り、端末内で要約します。読み取り専用で、データは端末外へ送信されません。'
version: "1.3.0"
icon: heart.fill
disabled: false
type: device
chip_prompt: "今日の歩数はどれくらい?"
chip_label: "今日の歩数"

triggers:
  - steps
  - how many steps
  - step count
  - activity
  - exercise
  - health
  - health data
  - health report
  - health analysis
  - weekly report
  - monthly report
  - analyze
  - workout
  - yesterday's steps
  - walked yesterday
  - this week
  - last few days
  - distance
  - how far
  - kilometers
  - calories
  - burned
  - energy
  - heart rate
  - heartbeat
  - resting heart rate
  - heart rate variability
  - HRV
  - weight
  - sleep
  - slept
  - sleeping
  - last night's sleep
  - this week's sleep
  - fitness
  - training
  - 歩数
  - 活動量
  - 運動
  - ヘルスケア
  - 健康データ
  - 健康レポート
  - 睡眠
  - 心拍数
  - 体重
  - 距離
  - 消費カロリー

allowed-tools:
  - health-report-range
  - health-report-week
  - health-steps-today
  - health-steps-yesterday
  - health-steps-range
  - health-distance-today
  - health-active-energy-today
  - health-heart-rate-resting
  - health-heart-rate-recent
  - health-heart-rate-variability
  - health-weight-latest
  - health-sleep-last-night
  - health-sleep-week
  - health-workout-recent

examples:
  - query: "今日の歩数はどれくらい?"
    scenario: "今日の歩数を確認"
  - query: "今日の活動量はどう?"
    scenario: "今日の活動量を確認"
  - query: "昨日は何歩歩いた?"
    scenario: "昨日の歩数を確認"
  - query: "今週の歩数はどう?"
    scenario: "今週の歩数を確認"
  - query: "心拍数はどう?"
    scenario: "最近の心拍数を確認"
  - query: "最新の体重は?"
    scenario: "最新の体重を確認"
  - query: "過去1週間のヘルスケアデータを分析して"
    scenario: "7日間の総合ヘルスケアレポートを生成"
  - query: "過去1か月の健康データを分析して"
    scenario: "30日間の総合ヘルスケアレポートを生成"

# Sync anchor (see scripts/check-skill-sync.sh):
translation-source-commit: 21af290
translation-source-sha256: 750f1658821be0743907d0070af47d5e884e4e76682d71c90480266db5cbf6f5
---

# ヘルスケアデータ照会

ユーザーのヘルスケアデータを読み取り、短く解釈します。すべてのデータは端末内で処理され、アップロードされません。

## ツール選択

| ユーザー意図 | ツール |
|-------------|------|
| ヘルスケアデータの分析 / 健康レポート / 週間ヘルスケアレポート / 全体的な健康状態 / 過去N日間の健康データ | health-report-range (`days` はユーザーの期間から推定。1週間=7、2週間=14、1か月=30) |
| 過去1週間の健康データ / 今週の健康レポート | health-report-range (days=7; health-report-week も可) |
| 今日の歩数 / 今日の活動量 / 今日の活動レベル | health-steps-today |
| 昨日の歩数 / 昨日の活動量 | health-steps-yesterday |
| 今週 / 直近N日間の歩数 | health-steps-range (今週は days=7。ユーザー意図から日数を推定) |
| 今日どれくらい歩いたか / 歩行距離 | health-distance-today |
| 今日の消費カロリー / エネルギー / kcal | health-active-energy-today |
| 安静時心拍数 | health-heart-rate-resting |
| 最近の心拍数 / 脈拍 / 現在の心拍数 | health-heart-rate-recent |
| 心拍変動 / HRV | health-heart-rate-variability |
| 体重 / 最新の体重 | health-weight-latest |
| 昨夜どれくらい寝たか / 睡眠の質 | health-sleep-last-night |
| 直近1週間の睡眠 | health-sleep-week |
| 最近のワークアウト / フィットネス記録 | health-workout-recent |

注: "活動量" / "活動レベル" は既定で歩数(health-steps-today)として扱います。ユーザーが明示的に "カロリー" / "kcal" / "エネルギー" / "消費" と言った場合だけ health-active-energy-today を使います。
注: "健康データ" / "健康レポート" / "健康を分析" は総合分析を意味するため、必ず health-report-range を使います。睡眠や歩数だけを照会してはいけません。health-sleep-week / health-sleep-last-night は、ユーザーが睡眠を明示した場合だけ使います。
初回の Health 権限リクエストでは、歩数、歩行+ランニング距離、活動エネルギー、安静時心拍数、睡眠、ワークアウト、体重、心拍数、HRV の読み取り権限をまとめて求めます。

## 期間推定

- "1週間" / "今週" / "過去1週間" / "7日間" → days=7
- "2週間" / "過去2週間" / "14日間" → days=14
- "1か月" / "過去1か月" / "30日間" → days=30
- "直近数日" で具体的な数がない場合 → days=7
- `days` は 1 から 90 まで。日付のリストに展開せず、日数だけ渡す

## 実行フロー

1. ユーザー意図に基づき、正しいツールを選んですぐ呼び出す。確認質問はしない。
2. ツール結果を得たら、返された要約と数値を根拠に、日本語で自然に短く答える。数値や事実は変えない。
3. 総合ヘルスケアレポート(health-report-range)は、その期間の対応ヘルスケア指標を1回のツール呼び出しで読む。返されたレポートを根拠にする。
4. 歩数範囲照会(health-steps-range)では、返された要約を根拠にする。
5. **ヘルスケアデータを作り上げない**。必ずツールが返した実数値を使う。
6. ツールを呼ぶ前に「権限がない」「わからない」と言わない。まずツールを呼び、その結果に基づいて話す。

## 完了後の返信

- すべてのヘルスケアデータについて、短い自然な日本語で答える。ツール名、JSON、内部手順は言わない。
- 睡眠、心拍数、距離、カロリー、ワークアウト記録では、中心となる数値と軽い解釈を最大1つだけ添える。
- データがない場合は、記録がないと伝える。推測しない。

## 権限が拒否された場合

ツールが failurePayload を返し、エラーに "authorization denied" または "settings" が含まれる場合、ユーザーに次を伝える:

> ヘルスケアデータを読み取れませんでした。設定 → プライバシーとセキュリティ → ヘルスケア → PhoneClaw で、必要なヘルスケアデータの読み取り権限が有効になっているか確認してから、もう一度聞いてください。

同じツール呼び出しを何度も繰り返さない。
