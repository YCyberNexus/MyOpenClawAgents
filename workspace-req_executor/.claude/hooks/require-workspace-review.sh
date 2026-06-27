#!/usr/bin/env bash
# Stop hook: block end-of-turn if workspace-req_executor/ has unreviewed changes
# made during THIS conversation (not pre-existing dirty files).
# Baseline (auto-initialized once): .review-baseline — fingerprint at conversation start.
# Sentinel: .review-done-sha — fingerprint of the last reviewed state.
# Both sentinels live next to this script (workspace-req_executor/.claude/) and are
# resolved as ABSOLUTE paths, so the hook works whether Claude Code is launched from the
# repo root or from inside workspace-req_executor/ (the diff scope stays git-root-relative).
set -euo pipefail

# Drain stdin (hook input JSON) — not needed for logic, but keeps the pipe tidy.
cat >/dev/null || true

# Resolve the sentinel directory from this script's own location BEFORE any cd
# (BASH_SOURCE is still relative to the launch cwd at this point).
claude_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$repo_root"

# Fingerprint = hash of (HEAD diff + contents of untracked files) under workspace-req_executor/.
fingerprint=$(
  {
    git diff HEAD -- workspace-req_executor/ 2>/dev/null || true
    while IFS= read -r f; do
      [ -n "$f" ] && [ -f "$f" ] && printf '\n--- %s ---\n' "$f" && cat -- "$f"
    done < <(git ls-files --others --exclude-standard -- workspace-req_executor/ 2>/dev/null)
  } | git hash-object --stdin
)

empty_hash=$(printf '' | git hash-object --stdin)
if [ "$fingerprint" = "$empty_hash" ]; then
  exit 0
fi

# Baseline: auto-initialize on first hook run so pre-existing dirty files don't count.
baseline="$claude_dir/.review-baseline"
if [ ! -f "$baseline" ]; then
  printf %s "$fingerprint" > "$baseline"
  exit 0
fi
if [ "$fingerprint" = "$(cat "$baseline" 2>/dev/null)" ]; then
  exit 0
fi

sentinel="$claude_dir/.review-done-sha"
if [ -f "$sentinel" ] && [ "$(cat "$sentinel" 2>/dev/null)" = "$fingerprint" ]; then
  exit 0
fi

reason="workspace-req_executor/ 有未 code-review 的改动。按 CLAUDE.md 的 review 循环：调用 Agent(subagent_type=\"code-reviewer\")，在 prompt 里点明 review 当前 workspace-req_executor/ 下未提交的 diff，吸收反馈，最多 3 轮直到零问题（或你判断改动是 trivial）。完成后执行下面这一行解除阻断：
printf %s '${fingerprint}' > ${sentinel}"

jq -n --arg reason "$reason" '{decision:"block", reason:$reason}'
