#!/usr/bin/env bash
# Convert one Task6 live-preflight skipped entry into an exact claim-fenced
# physical handoff and import it through the same terminal path as a child.
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
    and (.job_id | clean_string
      and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$"))
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
SYNTHETIC_ROOT="${EXECUTOR_SCHEDULER_ROOT}/synthetic_handoffs"
mkdir -p "${SYNTHETIC_ROOT}"
chmod 700 "${SYNTHETIC_ROOT}" 2>/dev/null || die "synthetic handoff directory must be private"

# A fresh reserved skip has no physical claim and therefore uses claim-0. A
# running continuation already owns a positive private claim, so snapshot that
# exact fence under scheduler.lock and let import_driven_handoff.sh validate it
# again under its own lock. This closes the blocked-retry window where project
# pending is gone but the physical scheduler job is still running.
exec {SKIP_SCHEDULER_LOCK_FD}>"${SCHEDULER_LOCK_FILE}"
flock -x "${SKIP_SCHEDULER_LOCK_FD}"
ACTIVE_CLAIM="$(jq -ce \
  --arg job_id "${JOB_ID}" \
  --arg project "$(jq -r '.project' <<<"${ENTRY_JSON}")" \
  --argjson iid "$(jq -r '.iid' <<<"${ENTRY_JSON}")" '
  (.active_jobs[$job_id] // null) as $job
  | if $job == null then null
    elif ($job | type == "object"
      and .job_id == $job_id
      and .project == $project
      and .iid == $iid
      and ((.finalization // null) == null
        or (.finalization | type == "object"))
      and (
        (.status == "reserved"
          and .claim_generation == 0
          and .claim_token == null)
        or
        (.status == "running"
          and (
            ((.legacy_running // false) == true
              and .claim_generation == 0
              and .claim_token == null)
            or
            ((.legacy_running // false) != true
              and (.claim_generation | type == "number"
                and . == floor and . > 0)
              and (.claim_token | type == "string" and length > 0))
          ))
      ))
    then {
      claim_generation:$job.claim_generation,
      claim_token:$job.claim_token
    }
    else error("active job cannot accept a live preflight skip")
    end
  ' "${SCHEDULER_STATE_FILE}")" || {
  flock -u "${SKIP_SCHEDULER_LOCK_FD}"
  exec {SKIP_SCHEDULER_LOCK_FD}>&-
  die "active scheduler job is invalid for skipped import: ${JOB_ID}"
}
flock -u "${SKIP_SCHEDULER_LOCK_FD}"
exec {SKIP_SCHEDULER_LOCK_FD}>&-

if [ "${ACTIVE_CLAIM}" = null ]; then
  # A direct retry can arrive after the real importer already removed the
  # active job. Recover the one durable synthetic handoff by its safe job-id
  # prefix; multiple generations are a conflict and fail closed.
  shopt -s nullglob
  EXISTING_HANDOFFS=("${SYNTHETIC_ROOT}/${JOB_ID}:claim-"*:terminal-1.json)
  shopt -u nullglob
  [ "${#EXISTING_HANDOFFS[@]}" -eq 1 ] \
    || die "active scheduler job is missing without one replayable skipped handoff: ${JOB_ID}"
  HANDOFF_FILE="${EXISTING_HANDOFFS[0]}"
  HANDOFF_JSON="$(jq -ceS \
    --argjson entry "${ENTRY_JSON}" '
    if type == "object"
      and .job_id == $entry.job_id
      and .project == $entry.project
      and .iid == $entry.iid
      and .status == "skipped"
      and .reason == $entry.reason
      and (.claim_generation | type == "number" and . == floor and . >= 0)
      and (if .claim_generation == 0
        then .claim_token == null
        else (.claim_token | type == "string" and length > 0)
        end)
    then . else error("replayable skipped handoff conflicts with entry") end
  ' "${HANDOFF_FILE}")" || die "existing synthetic handoff is invalid"
  EVENT_ID="$(jq -r '.event_id' <<<"${HANDOFF_JSON}")"
else
  CLAIM_GENERATION="$(jq -r '.claim_generation' <<<"${ACTIVE_CLAIM}")"
  CLAIM_TOKEN_JSON="$(jq -c '.claim_token' <<<"${ACTIVE_CLAIM}")"
  EVENT_ID="${JOB_ID}:claim-${CLAIM_GENERATION}:terminal-1"
  HANDOFF_FILE="${SYNTHETIC_ROOT}/${EVENT_ID}.json"

  HANDOFF_JSON="$(jq -cnS \
    --argjson entry "${ENTRY_JSON}" \
    --arg event_id "${EVENT_ID}" \
    --argjson claim_generation "${CLAIM_GENERATION}" \
    --argjson claim_token "${CLAIM_TOKEN_JSON}" '{
    version:1,
    event_id:$event_id,
    job_id:$entry.job_id,
    memberships:[],
    memberships_source:"scheduler_active_job",
    claim_generation:$claim_generation,
    claim_token:$claim_token,
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
    ( umask 077; printf '%s\n' "${HANDOFF_JSON}" >"${CANDIDATE}" )
    mv "${CANDIDATE}" "${HANDOFF_FILE}"
    chmod 600 "${HANDOFF_FILE}" 2>/dev/null \
      || die "synthetic handoff must be private"
  fi
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
