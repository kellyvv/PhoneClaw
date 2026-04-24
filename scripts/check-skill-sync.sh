#!/bin/bash
# PhoneClaw Skill bilingual sync check.
#
# 拦住的失败模式:
#   1. SKILL.md 存在但 SKILL.en.md 缺失
#   2. SKILL.en.md 缺 translation-source-sha256 / translation-source-commit 字段
#   3. 当前 SKILL.md 的 SHA256 跟 en.md 记录的不一致 (zh 改了, en 没重翻)
#   4. 可选: translation-source-commit 在 git 历史里不存在 (squash/rebase 过)
#
# 用法:
#   scripts/check-skill-sync.sh            # 扫全仓 Skills/Library/*
#   scripts/check-skill-sync.sh calendar   # 只查单个 skill
#
# pre-commit 钩子里只关心当前 commit 里 staged 的 SKILL.md — 走 --staged-only。
#
# 跳过此检查 (仅限真要覆盖, 比如只改注释不影响翻译):
#   PHONECLAW_SKIP_SKILL_SYNC=1 git commit ...
# (跟 PHONECLAW_SKIP_HARNESS 独立, 不会被 harness skip 顺带跳过)

if [[ -n "${PHONECLAW_SKIP_SKILL_SYNC:-}" ]]; then
    echo "[check-skill-sync] PHONECLAW_SKIP_SKILL_SYNC set — 跳过"
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

STAGED_ONLY=0
SKILL_FILTER=""
for arg in "$@"; do
    case "$arg" in
        --staged-only) STAGED_ONLY=1 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) SKILL_FILTER="$arg" ;;
    esac
done

# 收集要检查的 SKILL.md 列表 (bash 3 compatible, 不用 mapfile)
zh_files=()
if [[ "$STAGED_ONLY" == "1" ]]; then
    while IFS= read -r f; do
        [[ -n "$f" ]] && zh_files+=("$f")
    done < <(git diff --cached --name-only --diff-filter=ACMR \
             | grep -E '^Skills/Library/[^/]+/SKILL\.md$')
else
    for f in Skills/Library/*/SKILL.md; do
        [[ -f "$f" ]] && zh_files+=("$f")
    done
fi

if [[ -n "$SKILL_FILTER" ]]; then
    zh_files=( "Skills/Library/$SKILL_FILTER/SKILL.md" )
fi

if [[ ${#zh_files[@]} -eq 0 ]]; then
    echo "[check-skill-sync] 无待检查 SKILL.md"
    exit 0
fi

ERRORS=0

for zh_file in "${zh_files[@]}"; do
    [[ -f "$zh_file" ]] || continue
    skill_dir="$(dirname "$zh_file")"
    skill_id="$(basename "$skill_dir")"
    en_file="$skill_dir/SKILL.en.md"

    # 1. SKILL.en.md 存在吗?
    if [[ ! -f "$en_file" ]]; then
        echo "❌ $skill_id: $en_file 缺失 (新 skill 加 zh 后, 用 scripts/translate-skill.sh 产出 en)"
        ERRORS=$((ERRORS+1))
        continue
    fi

    # 2. 读 frontmatter 里的 anchor
    src_commit=$(awk -F': ' '/^translation-source-commit:/ {print $2; exit}' "$en_file" | tr -d ' ')
    src_sha256=$(awk -F': ' '/^translation-source-sha256:/ {print $2; exit}' "$en_file" | tr -d ' ')

    if [[ -z "$src_commit" || -z "$src_sha256" ]]; then
        echo "❌ $skill_id: $en_file 缺 translation-source-commit / translation-source-sha256"
        echo "   每个 en.md frontmatter 需要两个字段 (sha256 是稳定锚点, commit 只作参考)"
        ERRORS=$((ERRORS+1))
        continue
    fi

    # 3. 当前 zh 的 SHA256 匹配吗?
    current_sha256=$(shasum -a 256 "$zh_file" | awk '{print $1}')

    if [[ "$current_sha256" != "$src_sha256" ]]; then
        echo "⚠️  $skill_id: $zh_file 内容已变化, $en_file 可能过期"
        echo "   anchored sha256:  $src_sha256"
        echo "   current  sha256:  $current_sha256"
        echo "   重翻后更新 en.md 的 translation-source-sha256 字段"

        # 如果能看到 git 历史, 额外提示 diff 基线
        if git cat-file -e "$src_commit" 2>/dev/null; then
            echo "   diff 基线 (从翻译时至今):"
            git --no-pager diff --stat "$src_commit" -- "$zh_file" 2>&1 | sed 's/^/     /' | tail -3
        else
            echo "   注: commit $src_commit 在 git 历史里找不到 (可能被 squash/rebase 过), 只能靠 sha256 对比"
        fi

        ERRORS=$((ERRORS+1))
    fi
done

if [[ $ERRORS -gt 0 ]]; then
    echo ""
    echo "[check-skill-sync] $ERRORS 个 skill 同步异常"
    echo "跳过本次 (慎用): PHONECLAW_SKIP_SKILL_SYNC=1 git commit ..."
    exit 1
fi

if [[ "$STAGED_ONLY" == "0" ]]; then
    echo "[check-skill-sync] ✅ 所有 skill zh/en 同步"
fi
exit 0
