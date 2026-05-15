#!/usr/bin/env bash
# Stop hook: block end-of-turn if workspace-acpx_auto_tester_pts/ has unreviewed changes
# made during THIS conversation (not pre-existing dirty files).
# Baseline (auto-initialized once): .claude/.review-baseline — fingerprint at conversation start.
# Sentinel: .claude/.review-done-sha — fingerprint of the last reviewed state.
set -euo pipefail

# Drain stdin (hook input JSON) — not needed for logic, but keeps the pipe tidy.
cat >/dev/null || true

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$repo_root"

# Fingerprint = hash of (HEAD diff + contents of untracked files) under workspace-acpx_auto_tester_pts/.
fingerprint=$(
  {
    git diff HEAD -- workspace-acpx_auto_tester_pts/ 2>/dev/null || true
    while IFS= read -r f; do
      [ -n "$f" ] && [ -f "$f" ] && printf '\n--- %s ---\n' "$f" && cat -- "$f"
    done < <(git ls-files --others --exclude-standard -- workspace-acpx_auto_tester_pts/ 2>/dev/null)
  } | git hash-object --stdin
)

empty_hash=$(printf '' | git hash-object --stdin)
if [ "$fingerprint" = "$empty_hash" ]; then
  exit 0
fi

# Baseline: auto-initialize on first hook run so pre-existing dirty files don't count.
baseline=".claude/.review-baseline"
if [ ! -f "$baseline" ]; then
  printf %s "$fingerprint" > "$baseline"
  exit 0
fi
if [ "$fingerprint" = "$(cat "$baseline" 2>/dev/null)" ]; then
  exit 0
fi

sentinel=".claude/.review-done-sha"
if [ -f "$sentinel" ] && [ "$(cat "$sentinel" 2>/dev/null)" = "$fingerprint" ]; then
  exit 0
fi

reason="workspace-acpx_auto_tester_pts/ 有未 code-review 的改动。按 CLAUDE.md 的 review 循环：调用 Agent(subagent_type=\"code-reviewer\")，在 prompt 里点明 review 当前 workspace-acpx_auto_tester_pts/ 下未提交的 diff，吸收反馈，最多 3 轮直到零问题（或你判断改动是 trivial）。完成后执行下面这一行解除阻断：
printf %s '${fingerprint}' > ${sentinel}"

jq -n --arg reason "$reason" '{decision:"block", reason:$reason}'
