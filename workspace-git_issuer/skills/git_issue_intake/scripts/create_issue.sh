#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"

emit_failure() {
  local reason="$1"
  STATUS="failed" \
    ACTION="none" \
    REASON="${reason}" \
    bash "${SCRIPT_DIR}/emit_callback.sh"
}

emit_success() {
  local issue_iid="$1"
  local issue_url="$2"
  STATUS="success" \
    ACTION="created" \
    ISSUE_IID="${issue_iid}" \
    ISSUE_URL="${issue_url}" \
    PROJECT_FULL="${PROJECT_FULL}" \
    ENTRY_LABEL="${DEFAULT_ENTRY_LABEL}" \
    bash "${SCRIPT_DIR}/emit_callback.sh"
}

write_description_file() {
  if [ -n "${ISSUE_DESCRIPTION_FILE:-}" ]; then
    if [ ! -f "${ISSUE_DESCRIPTION_FILE}" ]; then
      printf 'ISSUE_DESCRIPTION_FILE not found: %s\n' "${ISSUE_DESCRIPTION_FILE}"
      return 1
    fi
    printf '%s' "${ISSUE_DESCRIPTION_FILE}"
    return 0
  fi

  if [ -z "${ISSUE_DESCRIPTION:-}" ]; then
    printf 'ISSUE_DESCRIPTION or ISSUE_DESCRIPTION_FILE is required\n'
    return 1
  fi

  local file
  file="$(mktemp "${TMPDIR:-/tmp}/git-issuer-description.XXXXXX")"
  printf '%s\n' "${ISSUE_DESCRIPTION}" >"${file}"
  printf '%s' "${file}"
}

write_origin_note_file() {
  local file
  file="$(mktemp "${TMPDIR:-/tmp}/git-issuer-origin.XXXXXX")"
  printf '<!-- req_origin v1 %s -->\n' "${ORIGIN_JSON}" >"${file}"
  printf '%s' "${file}"
}

load_gitlab_env

if ! reason="$(require_value PROJECT_FULL)"; then
  emit_failure "${reason}"
  exit 2
fi
if ! reason="$(require_value ISSUE_TITLE)"; then
  emit_failure "${reason}"
  exit 2
fi
if ! description_file="$(write_description_file)"; then
  emit_failure "${description_file}"
  exit 2
fi
if ! reason="$(ensure_glab_auth)"; then
  emit_failure "${reason}"
  exit 1
fi

PROJECT_URI="$(project_uri_for "${PROJECT_FULL}")"

if ! issue_json="$(
  glab api --method POST "projects/${PROJECT_URI}/issues" \
    -f "title=${ISSUE_TITLE}" \
    -F "description=@${description_file}"
)"; then
  emit_failure "glab issue create failed"
  exit 1
fi

issue_iid="$(printf '%s' "${issue_json}" | jq -r '.iid // empty')"
issue_url="$(printf '%s' "${issue_json}" | jq -r '.web_url // empty')"
if [ -z "${issue_iid}" ]; then
  emit_failure "glab issue create response missing iid"
  exit 1
fi
if [ -z "${issue_url}" ]; then
  issue_url="${GITLAB_API_PROTOCOL}://${GITLAB_HOST}/${PROJECT_FULL}/-/issues/${issue_iid}"
fi

if ! glab api --method PUT "projects/${PROJECT_URI}/issues/${issue_iid}" -f "add_labels=${DEFAULT_ENTRY_LABEL}" >/dev/null; then
  emit_failure "glab add entry label failed"
  exit 1
fi

if [ -n "${ORIGIN_JSON:-}" ]; then
  origin_note_file="$(write_origin_note_file)"
  if ! glab api --method POST "projects/${PROJECT_URI}/issues/${issue_iid}/notes" -F "body=@${origin_note_file}" >/dev/null; then
    emit_failure "glab write origin note failed"
    exit 1
  fi
fi

emit_success "${issue_iid}" "${issue_url}"
