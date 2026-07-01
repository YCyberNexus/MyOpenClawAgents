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
  local action="$1"
  local issue_iid="$2"
  local issue_url="$3"
  local entry_label="${4:-}"
  local superseded_by="${5:-}"

  STATUS="success" \
    ACTION="${action}" \
    ISSUE_IID="${issue_iid}" \
    ISSUE_URL="${issue_url}" \
    PROJECT_FULL="${PROJECT_FULL}" \
    ENTRY_LABEL="${entry_label}" \
    SUPERSEDED_BY="${superseded_by}" \
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
  file="$(mktemp "${TMPDIR:-/tmp}/git-issuer-update-description.XXXXXX")"
  printf '%s\n' "${ISSUE_DESCRIPTION}" >"${file}"
  printf '%s' "${file}"
}

write_note_file() {
  local note="$1"
  local file
  file="$(mktemp "${TMPDIR:-/tmp}/git-issuer-change-note.XXXXXX")"
  printf '%s\n' "${note}" >"${file}"
  printf '%s' "${file}"
}

post_change_note() {
  local issue_iid="$1"
  local note="${CHANGE_NOTE:-git_issuer ${CHANGE_ACTION} request}"
  local note_file
  note_file="$(write_note_file "${note}")"
  glab api --method POST "projects/${PROJECT_URI}/issues/${issue_iid}/notes" -F "body=@${note_file}" >/dev/null
}

fallback_issue_url() {
  local issue_iid="$1"
  local issue_url="$2"
  if [ -n "${issue_url}" ]; then
    printf '%s' "${issue_url}"
  else
    printf '%s://%s/%s/-/issues/%s' "${GITLAB_API_PROTOCOL}" "${GITLAB_HOST}" "${PROJECT_FULL}" "${issue_iid}"
  fi
}

load_gitlab_env
CHANGE_ACTION="${CHANGE_ACTION:-update}"
RERUN_LABEL="${RERUN_LABEL:-}"

if ! reason="$(require_value PROJECT_FULL)"; then
  emit_failure "${reason}"
  exit 2
fi
if ! reason="$(require_value ISSUE_IID)"; then
  emit_failure "${reason}"
  exit 2
fi
case "${RERUN_LABEL}" in
  ""|retry|continue) ;;
  *)
    emit_failure "RERUN_LABEL must be retry or continue"
    exit 2
    ;;
esac
if ! reason="$(ensure_glab_auth)"; then
  emit_failure "${reason}"
  exit 1
fi

PROJECT_URI="$(project_uri_for "${PROJECT_FULL}")"

if ! issue_json="$(glab api "projects/${PROJECT_URI}/issues/${ISSUE_IID}")"; then
  emit_failure "glab issue fetch failed"
  exit 1
fi

issue_state="$(printf '%s' "${issue_json}" | jq -r '.state // empty')"
issue_url="$(printf '%s' "${issue_json}" | jq -r '.web_url // empty')"
issue_url="$(fallback_issue_url "${ISSUE_IID}" "${issue_url}")"
if [ "${issue_state}" != "opened" ]; then
  emit_failure "issue must be opened"
  exit 1
fi

case "${CHANGE_ACTION}" in
  cancel|close)
    post_change_note "${ISSUE_IID}"
    if ! glab api --method PUT "projects/${PROJECT_URI}/issues/${ISSUE_IID}" -f "state_event=close" >/dev/null; then
      emit_failure "glab close issue failed"
      exit 1
    fi
    emit_success "closed" "${ISSUE_IID}" "${issue_url}"
    ;;

  supersede)
    if ! description_file="$(write_description_file)"; then
      emit_failure "${description_file}"
      exit 2
    fi
    new_title="${NEW_ISSUE_TITLE:-${ISSUE_TITLE:-Supersede #${ISSUE_IID}}}"
    if ! new_issue_json="$(
      glab api --method POST "projects/${PROJECT_URI}/issues" \
        -f "title=${new_title}" \
        -F "description=@${description_file}"
    )"; then
      emit_failure "glab supersede issue create failed"
      exit 1
    fi
    new_issue_iid="$(printf '%s' "${new_issue_json}" | jq -r '.iid // empty')"
    if [ -z "${new_issue_iid}" ]; then
      emit_failure "glab supersede response missing iid"
      exit 1
    fi
    if ! glab api --method PUT "projects/${PROJECT_URI}/issues/${new_issue_iid}" -f "add_labels=${DEFAULT_ENTRY_LABEL}" >/dev/null; then
      emit_failure "glab add supersede entry label failed"
      exit 1
    fi
    post_change_note "${ISSUE_IID}"
    if ! glab api --method PUT "projects/${PROJECT_URI}/issues/${ISSUE_IID}" -f "state_event=close" >/dev/null; then
      emit_failure "glab close superseded issue failed"
      exit 1
    fi
    emit_success "superseded" "${ISSUE_IID}" "${issue_url}" "${DEFAULT_ENTRY_LABEL}" "${new_issue_iid}"
    ;;

  update|change)
    if ! description_file="$(write_description_file)"; then
      emit_failure "${description_file}"
      exit 2
    fi
    if ! glab api --method PUT "projects/${PROJECT_URI}/issues/${ISSUE_IID}" -F "description=@${description_file}" >/dev/null; then
      emit_failure "glab update issue description failed"
      exit 1
    fi
    post_change_note "${ISSUE_IID}"
    if [ -n "${RERUN_LABEL}" ]; then
      if ! glab api --method PUT "projects/${PROJECT_URI}/issues/${ISSUE_IID}" -f "add_labels=${RERUN_LABEL}" >/dev/null; then
        emit_failure "glab add rerun label failed"
        exit 1
      fi
      emit_success "updated+relabeled" "${ISSUE_IID}" "${issue_url}" "${RERUN_LABEL}"
    else
      emit_success "updated" "${ISSUE_IID}" "${issue_url}"
    fi
    ;;

  *)
    emit_failure "CHANGE_ACTION must be update, cancel, close, or supersede"
    exit 2
    ;;
esac
