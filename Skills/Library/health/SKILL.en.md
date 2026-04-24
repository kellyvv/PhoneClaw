---
name: Health
name-zh: 健康数据
description: 'Read the user''s activity/step data from HealthKit and generate a summary locally. Read-only; data never leaves the device.'
version: "1.1.0"
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
  - workout
  - yesterday's steps
  - walked yesterday
  - this week
  - recently
  - last few days
  - distance
  - how far
  - kilometers
  - calories
  - burned
  - energy
  - heart rate
  - heartbeat
  - sleep
  - slept
  - last night's sleep
  - this week's sleep
  - fitness
  - training

allowed-tools:
  - health-steps-today
  - health-steps-yesterday
  - health-steps-range
  - health-distance-today
  - health-active-energy-today
  - health-heart-rate-resting
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

# Sync anchor (see scripts/check-skill-sync.sh):
translation-source-commit: 034c373
translation-source-sha256: a37b853870edd73ce311efa0291df26139d0839158edc35ae9b27718d35858fa
---

# Health Data Query

You are responsible for reading the user's health data and providing a brief interpretation. All data is processed locally and is not uploaded.

## Tool Selection

| User Intent | Tool |
|-------------|------|
| How many steps today / today's activity / today's activity level | health-steps-today |
| How many steps yesterday / yesterday's activity | health-steps-yesterday |
| This week / last N days step count | health-steps-range (days=7 for this week; infer the number of days from user intent) |
| How far did I walk today / walking distance | health-distance-today |
| How many calories did I burn today / energy / kcal | health-active-energy-today |
| Resting heart rate / heartbeat | health-heart-rate-resting |
| How long did I sleep last night / sleep quality | health-sleep-last-night |
| Sleep over the last week | health-sleep-week |
| Recent workouts / fitness records | health-workout-recent |

Note: "activity" / "activity level" defaults to step count (health-steps-today). Only use health-active-energy-today when the user explicitly mentions "calories" / "kcal" / "energy" / "burned".

## Execution Flow

1. Based on user intent, choose the correct tool and call it immediately — do not ask follow-up questions.
2. Once you have the step count, give a **short** natural-language reply:
   - Daily steps < 3000: "You walked Y steps X, activity is on the low side — maybe go out for a walk."
   - 3000 ≤ daily steps < 8000: "You walked Y steps X, activity is average."
   - Daily steps ≥ 8000: "You walked Y steps X, nice activity level."
   (X = "today"/"yesterday", Y = the number returned by the tool)
3. For range queries (health-steps-range), return the total steps and daily average, and provide a short summary using the total and average.
4. **Do not** make up step counts yourself — always use the real numbers returned by the tool.
5. **Do not** say "I don't have permission" or "I don't know" before calling the tool — call the tool first, then speak.

## When Permission Is Denied

If the tool returns a failurePayload and the error mentions "authorization denied" or "settings", tell the user:

> I wasn't able to read your step data. Please go to Settings → Privacy & Security → Health → PhoneClaw, confirm that step-reading permission is enabled, and then ask me again.

Do not repeatedly retry calling the tool.
