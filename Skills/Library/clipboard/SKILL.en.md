---
name: Clipboard
name-zh: 剪贴板
description: 'Read and write system clipboard contents. Use when the user needs to read, copy, or manipulate the clipboard.'
version: "1.0.0"
icon: doc.on.clipboard
disabled: false
type: device
chip_prompt: "Read my clipboard"
chip_label: "Read Clipboard"

triggers:
  - clipboard
  - paste
  - copy
  - pasteboard

allowed-tools:
  - clipboard-read
  - clipboard-write

examples:
  - query: "Read my clipboard"
    scenario: "Read the clipboard"
  - query: "Copy this text to the clipboard"
    scenario: "Write to the clipboard"

# Sync anchor (see scripts/check-skill-sync.sh):
translation-source-commit: 034c373
translation-source-sha256: 26bacc9d376bc54c8433cbacd24beaa64c1c6c3034fee7f672fd7b709b81ff4a
---

# Clipboard Operations

You are responsible for helping the user read and write the system clipboard.

## Available Tools

- **clipboard-read**: Read the current contents of the clipboard (no parameters)
- **clipboard-write**: Write text to the clipboard (parameter: text — the text to copy)

## Execution Flow

1. User asks to read → call `clipboard-read`
2. User asks to copy/write → call `clipboard-write`, passing the text parameter
3. Based on the result, answer the user concisely

## Reply after completion

- Reading the clipboard: answer with the content directly. Do not mention tool names or internal steps.
- Writing the clipboard: briefly confirm "Copied to the clipboard."
- If the content is long or non-text, explain it naturally using the tool summary.

## Call Format

<tool_call>
{"name": "clipboard-read", "arguments": {}}
</tool_call>

<tool_call>
{"name": "clipboard-write", "arguments": {"text": "text to copy"}}
</tool_call>
