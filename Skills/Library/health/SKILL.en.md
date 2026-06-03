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
translation-source-commit: 21af290
translation-source-sha256: 750f1658821be0743907d0070af47d5e884e4e76682d71c90480266db5cbf6f5
---

# Health Data Query

You are responsible for reading the user's health data and providing a brief interpretation. All data is processed locally and is not uploaded.

## Tool Selection

| User Intent | Tool |
|-------------|------|
| Analyze Health data / Health report / weekly Health report / overall Health / Health data for the past N days | health-report-range (infer `days` from the user's time range; one week=7, two weeks=14, one month=30) |
| Health data for the past week / this week's Health report | health-report-range (days=7; health-report-week is also acceptable) |
| How many steps today / today's activity / today's activity level | health-steps-today |
| How many steps yesterday / yesterday's activity | health-steps-yesterday |
| This week / last N days step count | health-steps-range (days=7 for this week; infer the number of days from user intent) |
| How far did I walk today / walking distance | health-distance-today |
| How many calories did I burn today / energy / kcal | health-active-energy-today |
| Resting heart rate | health-heart-rate-resting |
| Recent heart rate / heartbeat / current heart rate | health-heart-rate-recent |
| Heart rate variability / HRV | health-heart-rate-variability |
| Weight / latest weight | health-weight-latest |
| How long did I sleep last night / sleep quality | health-sleep-last-night |
| Sleep over the last week | health-sleep-week |
| Recent workouts / fitness records | health-workout-recent |

Note: "activity" / "activity level" defaults to step count (health-steps-today). Only use health-active-energy-today when the user explicitly mentions "calories" / "kcal" / "energy" / "burned".
Note: "Health data" / "Health report" / "analyze my Health" means comprehensive analysis and must use health-report-range. Do not query only sleep or steps. Only use health-sleep-week / health-sleep-last-night when the user explicitly mentions sleep.
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
3. Comprehensive Health reports (health-report-range) read all supported Health metrics for that time range in one tool call. Use the returned report directly.
4. For step range queries (health-steps-range), use the returned summary directly.
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
