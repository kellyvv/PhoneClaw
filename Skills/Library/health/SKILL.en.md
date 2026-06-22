---
name: Health
name-zh: 健康数据
description: 'Read the user''s activity, sleep, heart rate, weight, and other HealthKit data and generate a summary locally. Read-only; data never leaves the device.'
version: "1.3.0"
icon: heart.fill
disabled: false
type: device
chip_prompt: "How many steps did I take today?"
chip_label: "Today's Steps"

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

allowed-tools:
  - health-activity-summary
  - health-query
  - health-report

examples:
  - query: "How many steps did I take today?"
    scenario: "Check today's step count"
  - query: "How's my activity today?"
    scenario: "Today's activity overview"
  - query: "How many steps did I take yesterday?"
    scenario: "Check yesterday's step count"
  - query: "How are my steps this week?"
    scenario: "Check this week's step count"
  - query: "How is my heart rate?"
    scenario: "Check recent heart rate"
  - query: "What is my latest weight?"
    scenario: "Check latest weight"
  - query: "Analyze my Health data for the past week"
    scenario: "Generate a comprehensive 7-day Health report"
  - query: "Analyze my Health data for the past month"
    scenario: "Generate a comprehensive 30-day Health report"

# Sync anchor (see scripts/check-skill-sync.sh):
translation-source-commit: 950300e5
translation-source-sha256: 7d5cedb223489610c5a48d25aa60f5879639e76485064e7c822ba6fecadf5c15
---

# Health Data Query

You are responsible for reading the user's health data and providing a brief interpretation. All data is processed locally and is not uploaded.

## Tool Selection

| User Intent | Tool |
|-------------|------|
| Today's activity / today's activity level / today's exercise status / today's workout status | health-activity-summary |
| Analyze Health data / Health report / weekly Health report / overall Health / Health data for the past N days | health-report (infer `days` from the user's time range; one week=7, two weeks=14, one month=30) |
| Steps today / yesterday / over the past N days / how many steps | health-query (metric=steps, range=today/yesterday/last_n_days, pass `days` when needed) |
| How far did I walk today / how many kilometers / walking distance / distance traveled | health-query (metric=distance, range=today) |
| How many calories did I burn today / energy / kcal | health-query (metric=active_energy, range=today) |
| Resting heart rate | health-query (metric=resting_heart_rate, range=recent) |
| Recent heart rate / heartbeat / current heart rate | health-query (metric=heart_rate, range=recent) |
| Heart rate variability / HRV | health-query (metric=hrv, range=recent) |
| Weight / latest weight | health-query (metric=weight, range=latest) |
| How long did I sleep last night / sleep quality | health-query (metric=sleep, range=last_night) |
| Sleep over the last week | health-query (metric=sleep, range=week) |
| Recent workouts / fitness records | health-query (metric=workout, range=recent) |

Note: "activity" / "activity level" / "exercise status" defaults to health-activity-summary, not steps only. Only use health-query(metric=steps) when the user explicitly asks for step count.
Note: "how far" / "distance" / "kilometers" / "meters" / "distance traveled" means distance and must use health-query(metric=distance), not steps.
Note: "Health data" / "Health report" / "analyze my Health" means comprehensive analysis and must use health-report. Do not query only sleep or steps. Only use health-query(metric=sleep) when the user explicitly mentions sleep.
Note: If the user only corrects the time range or day count after a previous one-metric query, such as "not 5 days, 7 days", keep the same metric from the previous turn and only change range/days. If the previous query was steps, continue using health-query(metric=steps, range=last_n_days, days=7); do not upgrade to health-report.
The first Health authorization request asks for read access to steps, walking+running distance, active energy, resting heart rate, sleep, workouts, weight, heart rate, and HRV together.

## Time Range Inference

- "one week" / "this week" / "past week" / "7 days" → days=7
- "two weeks" / "past two weeks" / "14 days" → days=14
- "one month" / "past month" / "30 days" → days=30
- "last few days" without a specific number → days=7
- `days` is limited to 1 to 90; do not expand dates into a list, only pass the day count

## Execution Flow

1. Based on user intent, choose the correct tool and call it immediately — do not ask follow-up questions.
2. Once you have the tool result, use the natural-language summary returned by the tool directly. Do not apply your own template or output placeholders.
3. Comprehensive Health reports (health-report) read all supported Health metrics for that time range in one tool call. Use the returned report directly.
4. For one-metric queries (health-query) and today's activity overview (health-activity-summary), use the returned summary directly.
5. **Do not** make up health data yourself — always use the real numbers returned by the tool.
6. **Do not** say "I don't have permission" or "I don't know" before calling the tool — call the tool first, then speak.

## Reply after completion

- For all health data, answer in short natural language. Do not mention tool names, JSON, or internal steps.
- For sleep, heart rate, distance, calories, and workout records, give the core number and at most one light interpretation.
- If there is no data, say that no record is available. Do not guess.

## When Permission Is Denied

If the tool returns a failurePayload and the error mentions "authorization denied" or "settings", tell the user:

> I wasn't able to read your Health data. Please go to Settings → Privacy & Security → Health → PhoneClaw, confirm that the relevant Health data read permissions are enabled, and then ask me again.

Do not repeatedly retry calling the tool.
