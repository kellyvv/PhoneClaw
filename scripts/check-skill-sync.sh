#!/bin/bash
# PhoneClaw Skill translation sync check.
#
# 拦住的失败模式:
#   1. SKILL.md 存在但 SKILL.<locale>.md 缺失
#   2. SKILL.<locale>.md 缺 translation-source-sha256 / translation-source-commit 字段
#   3. 当前 SKILL.md 的 SHA256 跟本地化文件记录的不一致 (zh 改了, 翻译没重翻)
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
#
# --staged-only 时**同时**看 staged SKILL.md 和 staged 本地化 SKILL.<locale>.md:
# 只改本地化文件 (删 anchor / 换文件) 也要触发检查, 不能放行。
# 两路变更归一到各自 skill 目录, 去重。
translation_locales=(en ja)
zh_files=()
if [[ "$STAGED_ONLY" == "1" ]]; then
    skill_ids_seen=""
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        # 解析出 skill id (Skills/Library/<id>/SKILL.md 或 SKILL.<locale>.md)
        skill_id=$(echo "$f" | sed -E 's|^Skills/Library/([^/]+)/SKILL(\.(en|ja))?\.md$|\1|')
        [[ "$skill_id" == "$f" ]] && continue  # 没匹配上, 跳过
        # 去重 (zh 和 en 都改时只检查一次)
        case " $skill_ids_seen " in
            *" $skill_id "*) continue ;;
        esac
        skill_ids_seen="$skill_ids_seen $skill_id"
        zh_files+=( "Skills/Library/$skill_id/SKILL.md" )
    done < <(git diff --cached --name-only --diff-filter=ACMRD \
             | grep -E '^Skills/Library/[^/]+/SKILL(\.(en|ja))?\.md$')
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

    # 当前 zh 的 SHA256 匹配吗?
    # --staged-only 时读 git index (即将 commit 的内容), 不读工作区 —
    # 防止 "staged 是改后 zh, 工作区被 revert 回旧内容" 这类漏网.
    # 非 staged-only 时读工作区 (开发中手工检查).
    if [[ "$STAGED_ONLY" == "1" ]]; then
        # 可能 en.md 改了但 zh.md 没改 (只拦 en 变更). 此时 index 没 zh 的 staged
        # 版本, 退回到 HEAD 里的 zh 版本 (= 即将 commit 的 zh 仍是 HEAD 里的)。
        if git diff --cached --quiet -- "$zh_file" 2>/dev/null; then
            current_sha256=$(git show "HEAD:$zh_file" 2>/dev/null | shasum -a 256 | awk '{print $1}')
        else
            current_sha256=$(git show ":$zh_file" 2>/dev/null | shasum -a 256 | awk '{print $1}')
        fi
    else
        current_sha256=$(shasum -a 256 "$zh_file" | awk '{print $1}')
    fi

    for locale in "${translation_locales[@]}"; do
        localized_file="$skill_dir/SKILL.$locale.md"

        # 1. SKILL.<locale>.md 存在吗?
        if [[ ! -f "$localized_file" ]]; then
            echo "❌ $skill_id: $localized_file 缺失 (新 skill 加 zh 后, 需要补齐本地化文件)"
            ERRORS=$((ERRORS+1))
            continue
        fi

        # 2. 读 frontmatter 里的 anchor
        src_commit=$(awk -F': ' '/^translation-source-commit:/ {print $2; exit}' "$localized_file" | tr -d ' ')
        src_sha256=$(awk -F': ' '/^translation-source-sha256:/ {print $2; exit}' "$localized_file" | tr -d ' ')

        if [[ -z "$src_commit" || -z "$src_sha256" ]]; then
            echo "❌ $skill_id: $localized_file 缺 translation-source-commit / translation-source-sha256"
            echo "   每个本地化 frontmatter 需要两个字段 (sha256 是稳定锚点, commit 只作参考)"
            ERRORS=$((ERRORS+1))
            continue
        fi

        # 3. 当前 zh 的 SHA256 匹配吗?
        if [[ "$current_sha256" != "$src_sha256" ]]; then
            echo "⚠️  $skill_id: $zh_file 内容已变化, $localized_file 可能过期"
            echo "   anchored sha256:  $src_sha256"
            echo "   current  sha256:  $current_sha256"
            echo "   重翻后更新 $localized_file 的 translation-source-sha256 字段"

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
done

if [[ $ERRORS -gt 0 ]]; then
    echo ""
    echo "[check-skill-sync] $ERRORS 个 skill 同步异常"
    echo "跳过本次 (慎用): PHONECLAW_SKIP_SKILL_SYNC=1 git commit ..."
    exit 1
fi

if [[ "$STAGED_ONLY" == "0" ]]; then
    echo "[check-skill-sync] ✅ 所有 skill zh/en/ja 同步"
fi
exit 0
