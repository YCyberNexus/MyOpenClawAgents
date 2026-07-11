#!/usr/bin/env bash
# Build the token-free RUN_DRIVEN_ISSUE_BATCH trigger sent to req_executor.
set -euo pipefail

: "${BATCH_ID:?BATCH_ID required}"
: "${CORRELATION_ID:?CORRELATION_ID required}"
: "${PROJECT:?PROJECT required}"
: "${SELECTOR_JSON:?SELECTOR_JSON required}"

FORCE_RERUN_PR="${FORCE_RERUN_PR:-false}"
DISPATCHER_CALLBACK_TARGET="${DISPATCHER_CALLBACK_TARGET:-}"
TARGET_BRANCH="${TARGET_BRANCH:-}"

[ -n "${DISPATCHER_CALLBACK_TARGET}" ] \
  || { echo "DISPATCHER_CALLBACK_TARGET must not be empty" >&2; exit 2; }

has_control_characters() {
  local value="$1"

  case "${value}" in
    *$'\n'*|*$'\r'*|*$'\t'*) return 0 ;;
  esac

  LC_ALL=C printf '%s' "${value}" | grep -q '[[:cntrl:]]'
}

validate_scalar_value() {
  local name="$1"
  local value="$2"

  if has_control_characters "${value}"; then
    echo "${name} must not contain newlines or control characters" >&2
    exit 2
  fi
}

validate_branch_name() {
  local branch="$1"
  case "${branch}" in
    ""|-*|/*|*/|*//*|*..*|*@{*|*\\*|*~*|*^*|*:*|*\?*|*\**|*\[*|*\]*|*";"*|*"；"*|*\&*|*\|*|*\$*|*" "*|*$'\t'*|*$'\n'*|*.lock|*.)
      return 1
      ;;
  esac
  [ "${branch}" != "@" ] || return 1
  return 0
}

validate_scalar_value BATCH_ID "${BATCH_ID}"
validate_scalar_value CORRELATION_ID "${CORRELATION_ID}"
validate_scalar_value PROJECT "${PROJECT}"
validate_scalar_value SELECTOR_JSON "${SELECTOR_JSON}"
validate_scalar_value FORCE_RERUN_PR "${FORCE_RERUN_PR}"
validate_scalar_value DISPATCHER_CALLBACK_TARGET "${DISPATCHER_CALLBACK_TARGET}"
validate_scalar_value TARGET_BRANCH "${TARGET_BRANCH}"

if ! [[ "${PROJECT}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]]; then
  echo "PROJECT must be <group>/<project>, got: ${PROJECT}" >&2
  exit 2
fi

case "${FORCE_RERUN_PR}" in
  true|false) ;;
  *)
    echo "FORCE_RERUN_PR must be true or false" >&2
    exit 2
    ;;
esac

if [ -n "${TARGET_BRANCH}" ] && ! validate_branch_name "${TARGET_BRANCH}"; then
  echo "branch must be a safe Git ref name, got: ${TARGET_BRANCH}" >&2
  exit 2
fi

if ! SELECTOR_TYPE="$(
  jq -er '
    if type != "object" then
      error("selector must be an object")
    elif .type == "single"
      and keys == ["iid", "type"]
      and ((.iid | type) == "number")
      and (.iid == (.iid | floor))
      and (.iid > 0)
    then .type
    elif .type == "range"
      and keys == ["iid_max", "iid_min", "type"]
      and ((.iid_min | type) == "number")
      and ((.iid_max | type) == "number")
      and (.iid_min == (.iid_min | floor))
      and (.iid_max == (.iid_max | floor))
      and (.iid_min > 0)
      and (.iid_max > 0)
      and (.iid_min <= .iid_max)
    then .type
    elif .type == "open_unfinished"
      and keys == ["type"]
    then .type
    elif .type == "open_label"
      and keys == ["label", "type"]
      and ((.label | type) == "string")
      and ((.label | gsub("[[:space:]]"; "") | length) > 0)
      and (.label | explode | all(. >= 32 and . != 127))
    then .type
    else
      error("selector shape is invalid")
    end
  ' <<<"${SELECTOR_JSON}"
)"; then
  echo "SELECTOR_JSON must contain one valid selector shape" >&2
  exit 2
fi

cat <<EOF
RUN_DRIVEN_ISSUE_BATCH
batch_id=${BATCH_ID}
correlation_id=${CORRELATION_ID}
project=${PROJECT}
selector_type=${SELECTOR_TYPE}
EOF

case "${SELECTOR_TYPE}" in
  single)
    printf 'iid=%s\n' "$(jq -r '.iid' <<<"${SELECTOR_JSON}")"
    ;;
  range)
    printf 'iid_min=%s\n' "$(jq -r '.iid_min' <<<"${SELECTOR_JSON}")"
    printf 'iid_max=%s\n' "$(jq -r '.iid_max' <<<"${SELECTOR_JSON}")"
    ;;
  open_unfinished) ;;
  open_label)
    printf 'label=%s\n' "$(jq -r '.label' <<<"${SELECTOR_JSON}")"
    ;;
esac

printf 'force_rerun_pr=%s\n' "${FORCE_RERUN_PR}"
printf 'dispatcher_callback_target=%s\n' "${DISPATCHER_CALLBACK_TARGET}"

if [ -n "${TARGET_BRANCH}" ]; then
  printf 'branch=%s\n' "${TARGET_BRANCH}"
fi
