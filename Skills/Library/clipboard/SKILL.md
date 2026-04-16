---
name: Clipboard
name-zh: 剪贴板
description: '读写系统剪贴板内容。当用户需要读取、复制或操作剪贴板时使用。'
version: "1.0.0"
icon: doc.on.clipboard
disabled: false
type: device
chip_prompt: "读取我的剪贴板内容"
chip_label: "读剪贴板"

triggers:
  - 剪贴板
  - 粘贴
  - 复制
  - clipboard

allowed-tools:
  - clipboard-read
  - clipboard-write

examples:
  - query: "读取我的剪贴板内容"
    scenario: "读取剪贴板"
  - query: "把这段文字复制到剪贴板"
    scenario: "写入剪贴板"
---

# 剪贴板操作

你负责帮助用户读写系统剪贴板。

## 可用工具

- **clipboard-read**: 读取剪贴板当前内容（无参数）
- **clipboard-write**: 将文本写入剪贴板（参数: text — 要复制的文本）

## 执行流程

1. 用户要求读取 → 调用 `clipboard-read`
2. 用户要求复制/写入 → 调用 `clipboard-write`，传入 text 参数
3. 根据工具返回结果，简洁回答用户

## 调用格式

<tool_call>
{"name": "工具名", "arguments": {}}
</tool_call>
