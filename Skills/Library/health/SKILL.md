---
name: Health
name-zh: 健康数据
description: '读取 HealthKit 里的运动、睡眠、心率、体重等健康数据, 在本地生成摘要。只读不写, 数据不离开本机。'
version: "1.3.0"
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
  - 健康报告
  - 健康分析
  - 周报
  - 月报
  - 分析一下
  - health
  - steps
  - 昨天步数
  - 昨天走了
  - 本周
  - 这几天
  - 距离
  - 走了多远
  - 公里
  - 卡路里
  - 消耗
  - 热量
  - 心率
  - 心跳
  - 静息心率
  - 心率变异性
  - HRV
  - 体重
  - 睡眠
  - 睡了
  - 睡得
  - 昨晚睡
  - 这周睡眠
  - 健身
  - 训练
  - workout

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
  - query: "我今天走了多少步"
    scenario: "查询今日步数"
  - query: "今天运动量怎么样"
    scenario: "今日运动概况"
  - query: "我昨天走了多少步"
    scenario: "查询昨日步数"
  - query: "本周步数怎么样"
    scenario: "查询本周步数"
  - query: "我的心率怎么样"
    scenario: "查询最近心率"
  - query: "最近体重是多少"
    scenario: "查询最近体重"
  - query: "分析一下我最近一周健康数据"
    scenario: "生成最近 7 天综合健康报告"
  - query: "分析一下我最近一个月健康数据"
    scenario: "生成最近 30 天综合健康报告"
---

# 健康数据查询

你负责读取用户的健康数据并给出简短解读。数据全部在本地处理, 不上传。

## 工具选择

| 用户意图 | 工具 |
|---------|------|
| 分析健康数据 / 健康报告 / 健康周报 / 整体健康情况 / 最近N天健康数据 | health-report-range (days 按用户时间推断；一周=7，两周=14，一个月=30) |
| 最近一周健康数据 / 本周健康报告 | health-report-range (days=7；也可用 health-report-week) |
| 今天走了多少步 / 今天运动量 / 今天活动量 | health-steps-today |
| 昨天走了多少步 / 昨天运动量 | health-steps-yesterday |
| 本周/最近N天步数 | health-steps-range (days=7 表示本周, 按用户意图推断天数) |
| 今天走了多远 / 步行距离 | health-distance-today |
| 今天消耗了多少卡路里 / 热量 / 千卡 | health-active-energy-today |
| 静息心率 | health-heart-rate-resting |
| 最近心率 / 心跳 / 当前心率 | health-heart-rate-recent |
| 心率变异性 / HRV | health-heart-rate-variability |
| 体重 / 最近体重 | health-weight-latest |
| 昨晚睡了多久 / 睡眠质量 | health-sleep-last-night |
| 最近一周睡眠 | health-sleep-week |
| 最近运动 / 健身记录 | health-workout-recent |

注意: "运动量" / "活动量" 默认查步数 (health-steps-today), 只有明确说"卡路里"/"千卡"/"热量"/"消耗"才用 health-active-energy-today。
注意: "健康数据" / "健康报告" / "分析健康" 是综合分析, 必须用 health-report-range, 不要只查睡眠或步数。只有用户明确说"睡眠"时才用 health-sleep-week / health-sleep-last-night。
首次健康授权会一次请求步数、步行+跑步距离、活动能量、静息心率、睡眠、体能训练、体重、心率、心率变异性读取权限。

## 时间范围推断

- "一周" / "本周" / "最近一周" / "7 天" → days=7
- "两周" / "最近两周" / "14 天" → days=14
- "一个月" / "最近一个月" / "30 天" → days=30
- "这几天" 未给具体天数 → days=7
- `days` 限制在 1 到 90；不要自己把日期展开成列表, 只传天数

## 执行流程

1. 根据用户意图选择正确的工具, 立即调用, 不要追问
2. 拿到工具结果后, 直接使用返回结果里的自然语言摘要, 不要自己套模板或输出占位符
3. 综合健康报告 (health-report-range) 会一次读取该时间范围内所有支持的健康项, 直接使用返回报告
4. 范围步数查询 (health-steps-range) 返回总步数和日均, 直接使用返回摘要
5. **不要**自己编造健康数据, 必须用 tool 返回的真实数字
6. **不要**在没调用 tool 之前说"我没有权限"或"我不知道" — 先调工具再说

## 完成后回复

- 所有健康数据都用简短自然中文说明, 不要提工具名、JSON 或内部步骤
- 睡眠、心率、距离、卡路里、运动记录都只说核心数字和一句轻量解读
- 没有数据时, 直接说明没有可用记录, 不要猜测

## 权限被拒绝时

如果 tool 返回 failurePayload 且 error 里提到"授权被拒绝"或"设置",告诉用户:

> 我没能读到健康数据。请去设置 → 隐私与安全性 → 健康 → PhoneClaw, 确认开启相关健康数据读取权限, 然后再问我一次。

不要反复调用 tool 重试。
