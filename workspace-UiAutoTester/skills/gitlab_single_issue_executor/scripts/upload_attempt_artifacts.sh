#!/usr/bin/env bash
# upload_attempt_artifacts.sh -- publish attempt-scoped execution evidence
# to GitLab Wiki pages and link them from the issue before MR creation /
# done labeling.
#
# Required env vars:
#   GITLAB_HOST              from glab_auth.sh
#   GITLAB_API_PROTOCOL      from glab_auth.sh
#   PROJECT_FULL             "${GROUP}/${PROJECT}"
#   PROJECT_URI              URI-encoded "${GROUP}/${PROJECT}"
#   ISSUE_IID                from env_paths.sh
#   ATTEMPT_NUMBER_PADDED    e.g. "001"
#   LOG_DIR                  current-attempt log dir
#   WORKTREE_DIR             current-attempt worktree
#
# Behavior:
#   - Publishes ${LOG_DIR}/prompt.txt to:
#       issue<IID>/attempt-NNN/prompt.txt
#   - Publishes ${LOG_DIR}/claude_result.txt to:
#       issue<IID>/attempt-NNN/claude_result.txt
#   - Publishes the first report.html found under ${WORKTREE_DIR}, if any, to:
#       issue<IID>/attempt-NNN/report.html
#   - Posts a GitLab issue note with links to the Wiki pages.
#
# The posted note uses a hidden marker so continue-mode prompt generation can
# recognize it as an agent note, not reviewer guidance.

set -euo pipefail

# __source_env_paths_marker__ -- bootstrap env from minimum trigger inputs.
# Each Bash exec is a fresh shell, so paths/glab/PROJECT_URI must be re-derived.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"

: "${GITLAB_HOST:?run scripts/glab_auth.sh first}"
: "${GITLAB_API_PROTOCOL:?run scripts/glab_auth.sh first}"
: "${PROJECT_FULL:?run scripts/env_paths.sh first}"
: "${PROJECT_URI:?run scripts/env_paths.sh first}"
: "${ISSUE_IID:?}" "${ATTEMPT_NUMBER_PADDED:?}" "${LOG_DIR:?}" "${WORKTREE_DIR:?}"

PROMPT_SOURCE="${LOG_DIR}/prompt.txt"
CLAUDE_RESULT_SOURCE="${LOG_DIR}/claude_result.txt"

for required_file in "${PROMPT_SOURCE}" "${CLAUDE_RESULT_SOURCE}"; do
  if [ ! -f "${required_file}" ]; then
    echo "upload_attempt_artifacts: required file missing: ${required_file}" >&2
    exit 5
  fi
done

LINKS_FILE="${LOG_DIR}/wiki_artifact_links.md"
RESPONSES_JSONL="${LOG_DIR}/wiki_artifact_responses.jsonl"
NOTE_FILE="${LOG_DIR}/wiki_artifacts.md"
REPORT_CANDIDATES_FILE="${LOG_DIR}/report_candidates.txt"

: > "${LINKS_FILE}"
: > "${RESPONSES_JSONL}"

WIKI_PREFIX="issue${ISSUE_IID}/attempt-${ATTEMPT_NUMBER_PADDED}"
WIKI_BASE_URL="${GITLAB_API_PROTOCOL}://${GITLAB_HOST}/${PROJECT_FULL}/-/wikis"

wiki_web_url() {
  local title="$1"
  printf '%s/%s' "${WIKI_BASE_URL}" "${title}"
}

wiki_slug_uri() {
  local title="$1"
  printf '%s' "${title}" | jq -sRr @uri
}

publish_wiki_page() {
  local label="$1"
  local title="$2"
  local source_path="$3"
  local slug_uri
  local response
  local url

  slug_uri="$(wiki_slug_uri "${title}")"
  if glab api "projects/${PROJECT_URI}/wikis/${slug_uri}" >/dev/null 2>&1; then
    response="$(
      glab api --method PUT \
        "projects/${PROJECT_URI}/wikis/${slug_uri}" \
        -f "title=${title}" \
        -F "content=@${source_path}" \
        -f "format=markdown"
    )"
  else
    response="$(
      glab api --method POST \
        "projects/${PROJECT_URI}/wikis" \
        -f "title=${title}" \
        -F "content=@${source_path}" \
        -f "format=markdown"
    )"
  fi

  printf '%s\n' "${response}" >> "${RESPONSES_JSONL}"
  url="$(wiki_web_url "${title}")"

  {
    printf -- '- **%s**: %s\n' "${label}" "${url}"
    printf '  Wiki page: `%s`\n' "${title}"
    printf '  Source: `%s`\n' "${source_path}"
  } >> "${LINKS_FILE}"
}

publish_wiki_page \
  "prompt.txt" \
  "${WIKI_PREFIX}/prompt.txt" \
  "${PROMPT_SOURCE}"

publish_wiki_page \
  "claude_result.txt" \
  "${WIKI_PREFIX}/claude_result.txt" \
  "${CLAUDE_RESULT_SOURCE}"

find "${WORKTREE_DIR}" \
  \( -path "${WORKTREE_DIR}/.git" -o \
     -path "${WORKTREE_DIR}/.claude" -o \
     -path "${WORKTREE_DIR}/_hulat" \) -prune \
  -o -type f -name report.html -print \
  | sort > "${REPORT_CANDIDATES_FILE}"

REPORT_SOURCE="$(sed -n '1p' "${REPORT_CANDIDATES_FILE}")"
if [ -n "${REPORT_SOURCE}" ]; then
  publish_wiki_page \
    "report.html" \
    "${WIKI_PREFIX}/report.html" \
    "${REPORT_SOURCE}"
fi

{
  echo "<!-- uiautotester:attempt-wiki-artifacts v1 attempt=${ATTEMPT_NUMBER_PADDED} -->"
  echo "## UiAutoTester attempt ${ATTEMPT_NUMBER_PADDED} OpenClaw logs"
  echo
  echo "Attempt-scoped files published to this project's GitLab Wiki before merge request creation and before the issue is labeled \`done\`:"
  echo
  cat "${LINKS_FILE}"
  if [ -z "${REPORT_SOURCE}" ]; then
    echo "- **report.html**: not found under \`${WORKTREE_DIR}\`; no Wiki page published."
  fi
  echo
  echo "<!-- /uiautotester:attempt-wiki-artifacts -->"
} > "${NOTE_FILE}"

glab api --method POST \
  "projects/${PROJECT_URI}/issues/${ISSUE_IID}/notes" \
  -F "body=@${NOTE_FILE}" >/dev/null

echo "${NOTE_FILE}"
