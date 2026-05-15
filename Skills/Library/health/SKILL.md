---
name: Health
name-zh: 健康数据
description: '读取 HealthKit 里的用户运动/步数数据, 在本地生成摘要。只读不写, 数据不离开本机。'
version: "1.1.0"
icon: heart.fill
disabled: false
type: device
chip_prompt: "我今天走了多少步"
chip_label: "今日步数"

triggers:
  - 步数
  - 走了多少
  - 走了多少步
  - 运动
  - 锻炼
  - 健康
  - 健康数据
  - health
  - steps
  - 昨天步数
  - 昨天走了
  - 本周
  - 最近
  - 这几天
  - 距离
  - 走了多远
  - 公里
  - 卡路里
  - 消耗
  - 热量
  - 心率
  - 心跳
  - 睡眠
  - 睡了
  - 昨晚睡
  - 这周睡眠
  - 健身
  - 训练
  - workout

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
  - query: "我今天走了多少步"
    scenario: "查询今日步数"
  - query: "今天运动量怎么样"
    scenario: "今日运动概况"
  - query: "我昨天走了多少步"
    scenario: "查询昨日步数"
  - query: "本周步数怎么样"
    scenario: "查询本周步数"
---

# 健康数据查询

你负责读取用户的健康数据并给出简短解读。数据全部在本地处理, 不上传。

## 工具选择

| 用户意图 | 工具 |
|---------|------|
| 今天走了多少步 / 今天运动量 / 今天活动量 | health-steps-today |
| 昨天走了多少步 / 昨天运动量 | health-steps-yesterday |
| 本周/最近N天步数 | health-steps-range (days=7 表示本周, 按用户意图推断天数) |
| 今天走了多远 / 步行距离 | health-distance-today |
| 今天消耗了多少卡路里 / 热量 / 千卡 | health-active-energy-today |
| 静息心率 / 心跳 | health-heart-rate-resting |
| 昨晚睡了多久 / 睡眠质量 | health-sleep-last-night |
| 最近一周睡眠 | health-sleep-week |
| 最近运动 / 健身记录 | health-workout-recent |

注意: "运动量" / "活动量" 默认查步数 (health-steps-today), 只有明确说"卡路里"/"千卡"/"热量"/"消耗"才用 health-active-energy-today。

## 执行流程

1. 根据用户意图选择正确的工具, 立即调用, 不要追问
2. 拿到步数后, 直接使用返回结果里的自然语言摘要, 不要自己套模板或输出占位符
3. 范围查询 (health-steps-range) 返回总步数和日均, 直接使用返回摘要
4. **不要**自己编造步数, 必须用 tool 返回的真实数字
5. **不要**在没调用 tool 之前说"我没有权限"或"我不知道" — 先调工具再说

## 完成后回复

- 所有健康数据都用简短自然中文说明, 不要提工具名、JSON 或内部步骤
- 睡眠、心率、距离、卡路里、运动记录都只说核心数字和一句轻量解读
- 没有数据时, 直接说明没有可用记录, 不要猜测

## 权限被拒绝时

如果 tool 返回 failurePayload 且 error 里提到"授权被拒绝"或"设置",告诉用户:

> 我没能读到步数数据。请去设置 → 隐私与安全性 → 健康 → PhoneClaw, 确认开启了步数读取权限,然后再问我一次。

不要反复调用 tool 重试。
