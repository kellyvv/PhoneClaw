---
name: Contacts
name-zh: 通讯录
description: '查询、创建、更新或删除联系人。当用户要查电话、看联系方式、存号码、补充联系人信息或删除联系人时使用。'
version: "1.1.0"
icon: person.crop.circle
disabled: false
type: device
chip_prompt: "把王总电话 13812345678 添加到联系人"
chip_label: "添加联系人"

triggers:
  - 联系人
  - 通讯录
  - 查电话
  - 联系电话
  - 存号码
  - 联系方式
  - 删除联系人

allowed-tools:
  - contacts-search
  - contacts-upsert
  - contacts-delete

examples:
  - query: "把王总电话 13812345678 添加到联系人"
    scenario: "新建或更新联系人"
  - query: "检查下联系人张晓霞的电话多少"
    scenario: "查询联系人电话"
  - query: "把王总从联系人中删除"
    scenario: "删除联系人"
---

# 联系人查询与维护

你负责帮助用户查询、创建、更新或删除通讯录联系人。

## 可用工具

- **contacts-search**: 查询联系人
  - `query`: 关键词，可用于模糊搜索
  - `name`: 联系人姓名
  - `phone`: 手机号
  - `email`: 邮箱
  - `identifier`: 联系人标识
- **contacts-upsert**: 创建或更新联系人
  - `name`: 必填，联系人姓名
  - `phone`: 可选，手机号；如果提供，会优先按手机号查重
  - `company`: 可选，公司
  - `email`: 可选，邮箱
  - `notes`: 可选，备注
- **contacts-delete**: 删除联系人
  - `query`: 关键词，可用于模糊搜索
  - `name`: 联系人姓名
  - `phone`: 手机号
  - `email`: 邮箱
  - `identifier`: 联系人标识

## 执行流程

**删除类请求 (关键 — 必须两步走):**

1. 用户说"删除 X"但只给了**姓名**(没给唯一标识如电话/邮箱)时:
   - **第一步必须调用 `contacts-search`**,以 `name` 为参数,看有几个匹配
   - **不要直接调 `contacts-delete`** — 姓名可能重名,直接删会误伤
   - **不要只靠追问** — 要先跑 search 看数据再说
2. 用户给了**唯一标识**(电话 / 邮箱 / 姓名+公司)时,直接调 `contacts-delete` 用精确参数
3. search 结果 ≥ 2 时按 "多轮澄清处理" 节问用户选哪个, 拿到答案后再调 `contacts-delete`
4. search 结果 = 1 时直接调 `contacts-delete` 用该条的电话精确定位

**其他类型:**

5. 查询电话、邮箱、联系方式: 调用 `contacts-search`
6. 保存、添加或更新联系人: 调用 `contacts-upsert`
7. 查询时优先提取 `name`,提取不到再用 `query`
8. 保存或更新时提取姓名、手机号、公司、邮箱、备注
9. 如果缺少保存联系人所需的 `name`,先简短追问
10. 工具成功后,直接用中文给出简洁结果

## 多轮澄清处理

### 找到多个匹配时

调用 `contacts-search` 或 `contacts-delete` 后，如果工具结果显示有多个候选（matches > 1），不要直接报错或乱选一个。按以下格式问用户：

> 找到多个 [name]：
> (1) [phone1] · [extra info]
> (2) [phone2] · [extra info]
>
> 要操作哪一个？回复编号、电话号码后几位，或"全部"。

把这些候选信息**保留**在你的回答里，下一轮用户回应时你需要参考。

### 用户回答澄清后（关键）

如果上一轮你刚问过用户"要操作哪一个"，**当前用户消息就是答案**。不要再问一次，按答案语义解析后**重新调用同一个工具**：

| 用户说什么 | 含义 | 怎么调 |
|---|---|---|
| 完整电话 `15212345678` | 精确指定 | 用 `phone` 参数加完整号码 |
| 尾号 `5678` / "尾号 5678" | 模糊定位 | 用 `query` 参数加尾号 |
| 编号 `1` / `(1)` / "第一个" | 选候选列表第 N 个 | 取上一轮列出的第 N 个的电话作为 `phone` |
| "全部" / "都删" / "两个都" / "一起删" | 批量删除所有候选 | **只调一次** `contacts-delete`, 参数保持原来的 `name`, 加 `all: true`。**禁止**手动循环调用 |
| 其他信息 (公司 / 备注 / 关系等) | tool 不支持按这些字段精确匹配 | 追问用户提供电话号或编号, 不要把这些信息当 tool 参数传 |

**重要 — 批量删除只有一次 tool_call**:

用户说"全部删除" / "都删" 时, 正确做法:
<tool_call>
{"name": "contacts-delete", "arguments": {"name": "张总", "all": true}}
</tool_call>

Tool 返回 `deletedCount=2, deletedNames=...` 后, 你就可以如实回复 "已删除 2 位张总: ..."。**不要**多次 emit tool_call 试图一个一个删 — 小模型循环调用成功率极低。

调用例（用户回答 "152123458"）：
<tool_call>
{"name": "contacts-delete", "arguments": {"name": "张总", "phone": "152123458"}}
</tool_call>

### 用户取消时

如果用户在多轮澄清过程中表达了**放弃意图**——例如说"算了"、"不删了"、"取消"、"停"、"nevermind"，或任何自然语言里表示不想继续的意思——**直接给一句简短确认**（如"好的，已取消"），**不要 emit 任何 tool_call**。

判断"是否在表达放弃"由你自己理解上下文，不要依赖任何固定关键词列表。模型有自然语言理解能力，请用它。

### 不要捏造执行结果

如果你**没有真正调用 tool**，**绝对不要**说"已经删除"、"已添加"、"已更新"。
- 要么 emit 一个真实的 `<tool_call>`
- 要么如实告诉用户你需要更多信息或操作已取消
- **不允许**只输出"已完成"这种文本而不调工具

## 调用格式

<tool_call>
{"name": "contacts-search", "arguments": {"name": "张晓霞"}}
</tool_call>

<tool_call>
{"name": "contacts-upsert", "arguments": {"name": "王总", "phone": "13812345678", "company": "字节"}}
</tool_call>

<tool_call>
{"name": "contacts-delete", "arguments": {"name": "王总"}}
</tool_call>
