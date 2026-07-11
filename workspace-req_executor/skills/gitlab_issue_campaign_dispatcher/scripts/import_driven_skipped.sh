#!/usr/bin/env bash
# Convert one Task6 live-preflight skipped entry into a claim-0 physical handoff
# and import it through the same receipt/outbox/terminal path as a child result.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${CONFIG_DIR:-$(cd "${SKILL_DIR}/../.." && pwd)/config}"
IMPORT_HANDOFF_CMD="${IMPORT_HANDOFF_CMD:-${SCRIPT_DIR}/import_driven_handoff.sh}"

die() {
  echo "import_driven_skipped.sh: $*" >&2
  exit 2
}

case "${IMPORT_HANDOFF_CMD}" in
  /*) ;;
  *) die "IMPORT_HANDOFF_CMD must be absolute" ;;
esac
[ -f "${IMPORT_HANDOFF_CMD}" ] && [ -x "${IMPORT_HANDOFF_CMD}" ] \
  || die "IMPORT_HANDOFF_CMD must be executable"

if ! ENTRY_JSON="$(jq -ce '
  def clean_string:
    type == "string" and length > 0
    and (explode | all(. >= 32 and . != 127));
  if type == "object"
    and (keys | sort) == [
      "batch_id","iid","job_id","project","reason","snapshot_index","status"
    ]
    and (.job_id | clean_string)
    and (.batch_id | clean_string)
    and (.project | type == "string"
      and test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$"))
    and (.iid | type == "number" and . == floor and . > 0)
    and (.snapshot_index | type == "number" and . == floor and . >= 0)
    and .status == "skipped"
    and (.reason | clean_string)
  then . else error("invalid skipped entry") end
' 2>/dev/null)"; then
  die "stdin must be one strict Task6 skipped entry"
fi

# scheduler_env initializes paths and releases its short lock before import.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/scheduler_env.sh" >/dev/null

JOB_ID="$(jq -r '.job_id' <<<"${ENTRY_JSON}")"
EVENT_ID="${JOB_ID}:claim-0:terminal-1"
SYNTHETIC_ROOT="${EXECUTOR_SCHEDULER_ROOT}/synthetic_handoffs"
HANDOFF_FILE="${SYNTHETIC_ROOT}/${EVENT_ID}.json"
mkdir -p "${SYNTHETIC_ROOT}"

HANDOFF_JSON="$(jq -cnS --argjson entry "${ENTRY_JSON}" --arg event_id "${EVENT_ID}" '{
  version:1,
  event_id:$event_id,
  job_id:$entry.job_id,
  memberships:[],
  memberships_source:"scheduler_active_job",
  claim_generation:0,
  claim_token:null,
  project:$entry.project,
  iid:$entry.iid,
  status:"skipped",
  mr_url:null,
  reason:$entry.reason
}')"

if [ -f "${HANDOFF_FILE}" ]; then
  EXISTING="$(jq -ceS . "${HANDOFF_FILE}" 2>/dev/null)" \
    || die "existing synthetic handoff is invalid"
  [ "${EXISTING}" = "${HANDOFF_JSON}" ] \
    || die "stable synthetic handoff conflicts with existing bytes"
else
  CANDIDATE="$(mktemp "${SYNTHETIC_ROOT}/.${EVENT_ID}.XXXXXX")"
  printf '%s\n' "${HANDOFF_JSON}" >"${CANDIDATE}"
  mv "${CANDIDATE}" "${HANDOFF_FILE}"
fi

IMPORT_OUTPUT="$(CONFIG_DIR="${CONFIG_DIR}" HANDOFF_FILE="${HANDOFF_FILE}" \
  bash "${IMPORT_HANDOFF_CMD}")"
IMPORT_STATUS="$(jq -er '
  if type == "object"
    and (.status == "imported" or .status == "replayed")
    and (.job_id | type == "string")
    and .terminal_recorded == true
  then .status else error("invalid import acknowledgement") end
' <<<"${IMPORT_OUTPUT}")" || die "handoff importer returned an invalid acknowledgement"

jq -cn \
  --arg status "${IMPORT_STATUS}" \
  --arg job_id "${JOB_ID}" \
  --arg event_id "${EVENT_ID}" '{
    status:$status,
    job_id:$job_id,
    event_id:$event_id
  }'
