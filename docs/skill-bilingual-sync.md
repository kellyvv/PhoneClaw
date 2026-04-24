# Skill bilingual sync

PhoneClaw 的 skill 库每个 skill 在 `Skills/Library/<id>/` 下有两个 markdown:

- `SKILL.md` — 中文 (authoritative source, 用户/开发者先写这个)
- `SKILL.en.md` — 英文翻译版 (zh 改了之后必须同步重翻)

## 为什么需要同步机制

两份独立 markdown 容易漂移: 改 zh 但忘 en, 几个月后英文用户看到的 skill 规范就跟实际行为不符。

这里用**内容 hash 作为稳定锚点** + **pre-commit 钩子** 组合, 拦住大部分漂移:

```yaml
# Skills/Library/<id>/SKILL.en.md frontmatter 末尾
translation-source-commit: 034c373      # 人类友好的参考 (squash/rebase 可能失效)
translation-source-sha256: <zh hash>    # 稳定锚点 — 跟当前 SKILL.md 实际内容比对
```

## 工作流

### 改 SKILL.md 的流程

```bash
# 1. 改中文版
vim Skills/Library/calendar/SKILL.md
git add Skills/Library/calendar/SKILL.md

# 2. 翻英文版 (目前手动走 AI, 未来自动化脚本)
# 把 SKILL.md 整个内容贴给 Claude Code / ChatGPT, 对照旧 SKILL.en.md 做增量翻译

# 3. 更新 en.md 里的 anchor
NEW_HASH=$(shasum -a 256 Skills/Library/calendar/SKILL.md | awk '{print $1}')
NEW_COMMIT=$(git rev-parse --short HEAD)
# 手动编辑 SKILL.en.md, 替换 translation-source-commit 和 translation-source-sha256
git add Skills/Library/calendar/SKILL.en.md

# 4. commit — pre-commit 会验证 sync, 过了才允许
git commit -m "feat(skills): calendar — add end_time rule"
```

### 新增 skill 的流程

```bash
# 1. 新建 Skills/Library/<id>/SKILL.md (中文)
# 2. 用 Agent 或手翻产出 Skills/Library/<id>/SKILL.en.md
# 3. 给 en.md 加 translation-source-commit + translation-source-sha256 两个字段
# 4. commit, pre-commit 会验证
```

### 手动检查 (不 commit 也想看)

```bash
./scripts/check-skill-sync.sh              # 扫全仓 6 个 skill
./scripts/check-skill-sync.sh calendar     # 只看单个
./scripts/check-skill-sync.sh --staged-only # 只看 staged 的 SKILL.md (pre-commit 用)
```

## 检查会拦住哪些问题

| 场景 | 检查结果 |
|---|---|
| 改了 `SKILL.md` 但 `SKILL.en.md` 没改 (sha256 对不上) | ❌ 拒 commit |
| 新建 `SKILL.md` 但没建 `SKILL.en.md` | ❌ 拒 commit |
| `SKILL.en.md` 缺 `translation-source-commit` 或 `translation-source-sha256` 字段 | ❌ 拒 commit |
| `translation-source-commit` 已经被 squash 历史吞掉 | ⚠️ 警告但不阻塞 (sha256 仍能对齐就 OK) |

## 紧急跳过

非常规场景 (如只改 zh 的注释, 不影响翻译语义) 可以:

```bash
PHONECLAW_SKIP_SKILL_SYNC=1 git commit -m "..."
```

变量**独立**于 `PHONECLAW_SKIP_HARNESS` — 跳 harness 不会顺带跳 skill sync。

## Runtime override 风险 (未覆盖)

当前 `SkillRegistry` 允许用户在配置页编辑 skill, override 存到
`Application Support/skills/<id>/SKILL.md` (只有一份, 无 en override).
英文 locale 用户编辑过某个 skill 后, 下次启动会用到 zh override 的
SKILL.md. 这不属于 repo 内置双语的职责, 但需要未来单独处理 (可以:
新增 override 时同时要求产出 en; 或 runtime 按 locale 选 override 路径).

## 未来路线

- `scripts/translate-skill.sh` — 接 AI API, 一键增量翻译 + 自动更新 anchor
- GitHub Actions CI 跑 `check-skill-sync.sh`, PR 门禁
- 多语言扩展 (3+ locale) 时回到单文件多段落方案重评估
