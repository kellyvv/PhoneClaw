---
name: Reminders
name-zh: 提醒事项
description: '创建新的提醒事项。当用户需要记得做某事、设置待办或提醒时使用。'
version: "1.0.0"
icon: bell
disabled: false
type: device
requires-time-anchor: true
chip_prompt: "提醒我今晚八点发文件"
chip_label: "创建提醒"

triggers:
  - 提醒
  - 待办
  - 记得
  - 提示

allowed-tools:
  - reminders-create

examples:
  - query: "提醒我今晚八点发文件"
    scenario: "新建提醒事项"
---

# 提醒事项创建

你负责帮助用户创建新的提醒事项。**提醒事项的核心是"在什么时候提醒",没有时间的提醒没有意义。**

## 可用工具

- **reminders-create**: 创建提醒事项
  - `title`: **必填**, 提醒标题
  - `due`: **必填**, 提醒时间. **直接照抄用户原话** (例如 "今晚八点" / "明天上午10点" / "5月3日下午3点"), 工具会自己解析。**不需要**换算成 ISO 8601。
  - `notes`: 可选, 备注

## 执行流程

1. 从用户话语里提取 `title` 和 `due`
2. **如果缺 `title`**: 简短追问 "提醒您做什么呢?"
3. **如果缺 `due`**: 简短追问 "什么时候提醒您?"
4. **两者都有**时才调用 `reminders-create`, `due` 字段直接抄用户原话里的时间表达, 不需要换算
5. 工具成功后, 直接告诉用户提醒已创建 (如 "好的, 已设置明天早上 8 点提醒买牛奶")
6. **禁止**在未拿到 `due` 时就 emit tool_call

## 完成后回复

- 工具成功后, 用一句自然中文确认结果, 不要提工具名、JSON 或内部步骤
- 优先说用户关心的信息: 提醒内容 + 时间
- 示例: "已设置：今晚八点提醒发文件。"

## 调用格式

用户说什么时间, `due` 就抄什么, 工具自己解析:

<tool_call>
{"name": "reminders-create", "arguments": {"title": "发文件", "due": "今晚八点"}}
</tool_call>
