# PhoneClaw Architecture Decision Records (ADR)

> 日期：2026-04-07
> 上下文：五轮交叉评审（对比 OpenClaw / Claude Skills / Vera），确认端侧小模型推理的架构边界。

---

## ADR-001：拒绝统一 ReAct 循环取代多路分叉

**决策**：保留 processInput 的 5 路分流（VLM / Planner / Preflight / Agent / Light）。

**理由**：
- 端侧每次 LLM 调用延迟 3-8 秒，统一 ReAct 会将所有请求（包括纯聊天）暴露在 Skill 注入开销下
- Light 路径不注入任何 Skill 信息，节省 context window
- Preflight 路径跳过 LLM，<100ms 响应高频操作
- 2B 模型无法在 ReAct 循环中可靠地自主链式调用多个工具
- Vera 的统一 ReAct 依赖云端 100B+ 模型（200-500ms/次），前提不同

**重评条件**：端侧模型能力达到可靠自主链式调用（预计需要 8B+ 量级）且推理延迟降至 <1s。

---

## ADR-002：拒绝 [STATUS:COMPLETED] 终止标记

**决策**：继续使用 `parseToolCall() == nil` 作为工具链终止条件。

**理由**：
- Gemma 4 E2B/E4B 对受约束格式的遵从度不足（空格/大小写/位置不稳定）
- 强制要求输出 `[STATUS:COMPLETED]` 引入新的故障面（不输出 / 位置错 / 格式变体）
- 现有终止逻辑（无 tool_call + maxRounds=10 + validation failure + shouldSkipToolFollowUp）已足够健壮

**重评条件**：Gemma 格式遵从度显著提升，或切换到支持结构化输出的模型。

---

## ADR-003：拒绝合并 Planner Selection + Planning 为单一 Prompt

**决策**：保留 Selection → Planning 两步 LLM 调用。

**理由**：
- 分两步是"外置 CoT"——让小模型一次只做一件事，更可靠
- ≤3 个候选时 Selection 已走本地快捷路径（L732），不调 LLM
- 合并后单个 prompt 更长，JSON 遵从度下降
- Selection 有独立的 `validateSkillSelection()` 验证，失败可以便宜重试；合并后重试成本翻倍

**重评条件**：埋点证实 `matchedSkills > 3` 触发频率 > 5%（此时改为 Selection 短路跳过，不合并 prompt）。

---

## ADR-004：拒绝 E2B Keyword Sequential Fallback

**决策**：E2B 遇到多 Skill 请求时不尝试自动串行执行。

**理由**：
- 步骤间参数传递需要 intent 信息（"把 step1 的什么传给 step2"），仅靠 keyword 无法确定
- 让 2B 模型用 LLM 来补全参数传递 → 回到了"2B 能否自主链式调用"的问题，形成死循环
- "降级执行第一个 + 明确告知"是更诚实的 UX 选择

**重评条件**：2B 模型 CoT 能力提升到能可靠理解步骤间依赖关系。

---

## ADR-005：拒绝硬编码模型 ID 做路径分岔

**决策**：使用 `supportsStructuredPlanning` 等能力标志替代 `!= e2bModelID`。

**理由**：
- 硬编码模型 ID 是技术债，加新模型需要改逻辑代码
- 能力标志只需修改模型元数据表，未来可扩展

**状态**：P1-a，已纳入 v4 实施计划。

---

## ADR-006：拒绝 YAML 声明式正则快速路径（parameter-hints）

**决策**：`heuristicArgumentsForTool` 的 per-tool 正则保持 Swift 硬编码，不迁移到 SKILL.md。

**理由**：
- 中文正则在 YAML 里不可维护（无 IDE 补全、无类型安全、无测试覆盖）
- 当前 Swift 正则是反复调参的产物（如 contacts-search 有两层 fallback），YAML 声明式无法复现
- ReDoS 风险需要额外防护层
- 内置 vs 第三方的体验分层是合理的产品取舍（参考 Anthropic Claude）

**推迟到 N≥15 的改动**：
1. **top-K skill 注入**：system prompt 改为只注入 top-K 匹配项
2. **`quick-paths` frontmatter**（仅 keyword，无 regex）：第三方 Skill 声明关键词→工具名映射

**永久拒绝**：YAML regex `parameter-hints`。

**不重评条件**：若 Skill 数量长期保持 <15，推迟项永不重评。

---

## ADR-007：无 Prompt Prefix Caching

**决策**：不针对 KV cache 前缀命中率调整 prompt 结构。

**理由**：
- `MLXLocalLLMService.generateStream` 每次推理前调用 `MLX.GPU.clearCache()`
- 每次推理从头构建完整 KV cache，prompt 前缀稳定性不影响延迟
- 任何"缓存友好 prompt 重构"需先实现实际的 prefix caching

**重评条件**：PhoneClaw 实现跨请求 KV cache 持久化 + 前缀匹配。

---

## 三级 Skill 体验模型

| 级别 | 来源 | LLM 次数 | 响应 |
|------|------|---------|------|
| 一等 | 内置 Swift heuristic | 0 | <1s |
| 二等（未来） | 第三方 + `quick-paths` keyword | 1 | 3-8s |
| 三等 | 第三方裸装 | 2 | 6-16s |

这不是缺陷，是取舍。内置 Skill 经过手工调优，不可迁移到 YAML。第三方 Skill 走 LLM 路径功能完整，只是慢一些。
