# PhoneClaw

[English](./README_EN.md)

PhoneClaw 是一个运行在 iPhone 上的本地 AI Agent。  
它使用 **Gemma 4 + MLX + Metal GPU** 在设备端完成推理，不依赖云端，不上传聊天内容，适合做一个真正离线、可调用原生能力的私人助手。

## 这是什么

PhoneClaw 不是普通聊天壳，它是一个 `LLM + SKILL` 的本地 Agent：

- LLM 负责理解用户意图
- `SKILL.md` 负责描述某项能力该怎么做
- 原生工具负责真正执行设备内操作

当前已经打通的原生能力包括：

- 剪贴板读写
- 设备信息读取
- 文本处理
- 日历事件创建
- 提醒事项创建
- 通讯录联系人创建/更新

## 项目特点

- 完全离线运行，默认不联网
- 支持图片输入
- 基于文件的 Skill 系统，新增能力不需要重写整个 Agent
- 支持多轮工具调用
- 已内置权限管理、System Prompt 编辑、模型切换
- 针对 iPhone 内存上限做了缓存清理和历史裁剪

## 运行要求

- macOS + Xcode 16 或更新版本
- iOS 17.0 或更新版本
- CocoaPods
- 真机调试账号

模型建议：

- `Gemma 4 E2B`：更稳，更适合默认分发
- `Gemma 4 E4B`：效果更强，但更吃内存，建议高端机型使用

## 5 分钟快速开始

### 1. 安装依赖

```bash
pod install
```

### 2. 下载模型

先选择你要打包的模型。PhoneClaw 当前识别的目录名必须和下面保持一致。

推荐先安装 Hugging Face CLI：

```bash
brew install hf
```

或者：

```bash
pip install -U "huggingface_hub"
```

只下载 `E2B`：

```bash
mkdir -p ./Models/gemma-4-e2b-it-4bit
hf download mlx-community/gemma-4-e2b-it-4bit --local-dir ./Models/gemma-4-e2b-it-4bit
```

只下载 `E4B`：

```bash
mkdir -p ./Models/gemma-4-e4b-it-4bit
hf download mlx-community/gemma-4-e4b-it-4bit --local-dir ./Models/gemma-4-e4b-it-4bit
```

两个都下载：

```bash
mkdir -p ./Models/gemma-4-e2b-it-4bit
mkdir -p ./Models/gemma-4-e4b-it-4bit
hf download mlx-community/gemma-4-e2b-it-4bit --local-dir ./Models/gemma-4-e2b-it-4bit
hf download mlx-community/gemma-4-e4b-it-4bit --local-dir ./Models/gemma-4-e4b-it-4bit
```

下载后目录大致如下：

```text
Models/
├── gemma-4-e2b-it-4bit/
│   ├── config.json
│   ├── tokenizer.json
│   ├── processor_config.json
│   ├── chat_template.jinja
│   ├── model.safetensors
│   └── model.safetensors.index.json
└── gemma-4-e4b-it-4bit/
```

说明：

- `Models/` 已在 `.gitignore` 中忽略，不会被提交到仓库
- 当前 Hugging Face 模型页显示的仓库体积大约是：`E2B 3.58 GB`、`E4B 5.22 GB`
- 如果你不想用 CLI，也可以直接从模型页面手动下载后放到对应目录

### 3. 打开工程

```bash
open PhoneClaw.xcworkspace
```

不要打开 `.xcodeproj`，请始终打开 `.xcworkspace`。

### 4. 配置签名并运行

在 Xcode 中：

1. 选择 `PhoneClaw` target
2. 打开 `Signing & Capabilities`
3. 选择你的 `Team`
4. 把 `Bundle Identifier` 改成你自己的唯一值
5. 连接 iPhone
6. 按 `⌘R`

首次安装后，如果系统要求信任开发者证书，请在手机里完成信任。

### 5. 首次使用

打开 App 后：

- 右上角拼图按钮：Skill 管理
- 右上角滑杆按钮：模型设置 / 系统提示词 / 权限

建议先在权限页开启：

- 日历
- 提醒事项
- 通讯录

然后直接试下面几句：

- `这台手机的设备信息是什么`
- `提醒我今晚八点发文件`
- `帮我存一下王总的电话 13812345678`

## 如何只打包一个模型

这是最常见的发布方式，尤其是你只想发 `E2B` 时。

### 方案 A：只打包 `E2B`

保留：

```text
Models/gemma-4-e2b-it-4bit
```

移除：

```text
Models/gemma-4-e4b-it-4bit
```

然后做两步：

1. 在 Xcode 的 Project Navigator 里删除不用的模型 folder reference，选择 `Remove Reference`
2. 在 `PhoneClaw > Build Phases > Copy Bundle Resources` 里确认只剩你要打包的模型

最后，修改 [LLM/MLXLocalLLMService.swift](./LLM/MLXLocalLLMService.swift) 里的 `availableModels`，只保留实际会随 App 分发的模型。  
否则配置页仍然会显示不存在的模型选项。

### 方案 B：同时打包 `E2B + E4B`

保留两个目录和两个 Xcode 资源引用即可。  
用户可在 App 的 `模型设置 / Model Settings` 页里切换。

## 内置 Skill

| Skill | 工具 |
| --- | --- |
| 剪贴板 | `clipboard-read`, `clipboard-write` |
| 设备 | `device-info`, `device-name`, `device-model`, `device-system-version`, `device-memory`, `device-processor-count` |
| 文本 | `calculate-hash`, `text-reverse` |
| 日历 | `calendar-create-event` |
| 提醒事项 | `reminders-create` |
| 通讯录 | `contacts-upsert` |

## 自定义 Skill

新增一个 Skill 的最小成本方式，是在应用目录里增加一个 `SKILL.md`。

示例结构：

```text
Application Support/PhoneClaw/skills/<skill-id>/SKILL.md
```

示例：

```yaml
---
name: MySkill
name-zh: 我的能力
description: 这个 Skill 的作用
version: "1.0.0"
icon: star
disabled: false

triggers:
  - 关键词1

allowed-tools:
  - my-tool-name

examples:
  - query: "用户会怎么说"
    scenario: "什么场景会触发"
---

# Skill 指令

告诉模型何时调用工具、如何组织参数、何时直接回答。
```

如果这个 Skill 需要真正调用系统能力，再去 [Skills/ToolRegistry.swift](./Skills/ToolRegistry.swift) 注册对应工具。

## 关键目录

```text
PhoneClaw/
├── App/                         # App 入口
├── Agent/                       # Agent 循环与多轮工具调用
├── LLM/                         # MLX 本地推理与 Prompt 构建
├── Skills/                      # Skill 解析、工具注册、数据模型
├── UI/                          # 聊天界面、Skill 管理、配置页面
├── Models/                      # 本地模型目录（默认不入库）
├── PhoneClaw.xcworkspace
└── README.md
```

## 实际执行链路

```text
用户输入
→ PromptBuilder 组装提示词
→ Gemma 4 本地推理
→ 需要能力时调用 load_skill
→ 读取对应 SKILL.md
→ 执行原生工具
→ 返回最终中文结果
```

## 常见问题

### 为什么安装后看不到权限弹窗？

通常是因为对应 Skill 还没有真正执行到系统 API。  
如果之前已经拒绝过一次，iOS 也不会反复弹框，需要到系统设置里手动开启。

### 为什么切模型后加载失败？

先确认：

- 模型目录名和代码里的 `availableModels` 一致
- 该模型确实被打进了 App 包
- 设备内存足够

### 为什么提醒事项创建失败？

最新代码会先尝试复用现有提醒列表；如果系统里没有可写列表，会再尝试自动创建一个 `PhoneClaw` 提醒列表。  
如果这一步仍失败，通常是系统提醒源本身不可写。

## 后续计划

PhoneClaw 接下来的方向，不只是“多加几个工具”，而是把它逐步做成一个真正可用的本地 iPhone Agent。

### 1. 扩展更多 iOS 原生 API

计划继续补充更多系统能力，例如：

- 文件与目录操作
- 照片读取、整理、描述、检索
- 备忘录 / Notes
- 本地通知
- 地图 / 位置相关能力
- Safari / URL 打开与上下文传递
- 更多通讯录、日历、提醒事项的读写能力

### 2. 扩展更多 Skill

后续会继续把能力拆成更清晰的 Skill，而不是把所有逻辑都堆在一个大 Prompt 里。

适合继续追加的 Skill 方向：

- 文件管理
- 照片理解与整理
- 日程规划
- 个人信息管理
- 本地知识库检索
- 语音输入 / 语音播报

### 3. 串联更多本地模型

除了主聊天模型之外，后续适合接入的本地模型还包括：

- OCR 模型
- 语音识别模型
- 语音合成模型
- Embedding / Reranker 模型
- 更小的工具参数提取模型
- 更强的规划模型或多模型协作链路

这会让 PhoneClaw 从“一个大模型做所有事”，逐渐演进成“多个本地模型协同工作”的架构。

### 4. 跨 App 自动化

这是很重要的方向，但会严格遵守 iOS 的安全边界。  
PhoneClaw 不会假设自己能像桌面系统那样任意操控所有 App，而是优先走 iOS 真正允许的能力：

- `App Intents`
- `Shortcuts`
- `URL Scheme / Deep Link`
- `Share Sheet / 分享扩展`
- 剪贴板中转
- 系统通知与唤起

更现实的目标是：

- 在 App 之间传递内容
- 拉起指定 App 到指定页面
- 把本地理解能力和快捷指令工作流串起来
- 把多步操作压缩成一条自然语言命令

### 5. 外部硬件与视觉扩展

除了手机内部能力之外，PhoneClaw 后续也会探索和外部硬件配合的形态。  
例如把外部视频输入、屏幕画面理解和本地模型串起来，让 PhoneClaw 不只是“在手机里回答问题”，而是逐步具备更强的现实世界感知与调度能力。

这部分暂时不展开太多，后面会留一些更有意思的玩法。

### 6. 我建议优先做的方向

如果按“最容易尽快做出体验差异”的顺序，我会建议优先做：

1. 文件 / 照片 / 备忘录 三类高频 API
2. Shortcuts / App Intents 集成
3. OCR + 语音识别
4. 本地知识库检索
5. 更细的自动化 Skill 编排

这样很快就能把 PhoneClaw 从“会聊天的本地模型”推进到“能真正帮用户做事的本地助手”。

## 参考链接

- Hugging Face CLI 文档: <https://huggingface.co/docs/huggingface_hub/guides/cli>
- Hugging Face 下载文档: <https://huggingface.co/docs/huggingface_hub/en/guides/download>
- Gemma 4 E2B MLX 模型: <https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit>
- Gemma 4 E4B MLX 模型: <https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit>

## License

MIT
