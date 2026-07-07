#!/usr/bin/env bash
set -euo pipefail

CALLBACK_JSON="${CALLBACK_JSON:-}"
REQUIREMENT_TEXT="${REQUIREMENT_TEXT:-}"

if [ -z "${CALLBACK_JSON}" ]; then
  CALLBACK_JSON="$(cat)"
fi

if ! callback="$(printf '%s' "${CALLBACK_JSON}" | jq -e -c 'select(type == "object")')"; then
  echo "format_callback_output: CALLBACK_JSON must be a JSON object" >&2
  exit 2
fi

extract_payload_value() {
  local key="$1"
  if [ -z "${REQUIREMENT_TEXT}" ]; then
    return 0
  fi
  awk -v prefix="${key}=" '
    index($0, prefix) == 1 {
      sub(/^[^=]+=/, "", $0)
      print
      exit
    }
  ' <<<"${REQUIREMENT_TEXT}"
}

status="$(jq -r '.status // ""' <<<"${callback}")"
action="$(jq -r '.action // ""' <<<"${callback}")"
issue_iid="$(jq -r 'if .issue_iid == null then "" else (.issue_iid | tostring) end' <<<"${callback}")"
issue_url="$(jq -r '.issue_url // ""' <<<"${callback}")"
project="$(jq -r '.project // ""' <<<"${callback}")"
entry_label="$(jq -r '.entry_label // ""' <<<"${callback}")"
reason="$(jq -r '.reason // ""' <<<"${callback}")"

repo="${REPO:-$(extract_payload_value repo)}"
if [ -z "${repo}" ]; then
  repo="${project}"
fi
source_name="${SOURCE:-$(extract_payload_value source)}"
if [ -z "${source_name}" ]; then
  source_name="req_dispatcher"
fi
wiki_url="${WIKI_URL:-$(extract_payload_value wiki_url)}"
wiki_section="${WIKI_SECTION:-$(extract_payload_value wiki_section)}"
wiki_item_ordinal="${WIKI_ITEM_ORDINAL:-$(extract_payload_value wiki_item_ordinal)}"
title="${ISSUE_TITLE:-${TITLE:-}}"
if [ -z "${title}" ] && [ -n "${issue_iid}" ]; then
  title="issue #${issue_iid}"
fi

case "${action}" in
  created) dispatcher_action="create_issue" ;;
  updated|relabeled|updated+relabeled) dispatcher_action="update_issue" ;;
  closed) dispatcher_action="close_issue" ;;
  superseded) dispatcher_action="supersede_issue" ;;
  *) dispatcher_action="${action:-none}" ;;
esac

result_status="${action}"
if [ "${status}" != "success" ]; then
  result_status="failed"
fi
if [ -z "${result_status}" ] || [ "${result_status}" = "none" ]; then
  result_status="${status:-failed}"
fi

blue_json="$(
  jq -n \
    --argjson callback "${callback}" \
    --arg action "${dispatcher_action}" \
    --arg repo "${repo}" \
    --arg source "${source_name}" \
    --arg wiki_url "${wiki_url}" \
    --arg wiki_section "${wiki_section}" \
    --arg wiki_item_ordinal "${wiki_item_ordinal}" \
    --arg issue_iid "${issue_iid}" \
    --arg issue_url "${issue_url}" \
    --arg title "${title}" \
    --arg result_status "${result_status}" \
    --arg reason "${reason}" '
    $callback + {
      req_dispatcher: {
        action: $action,
        repo: (if $repo == "" then null else $repo end),
        source: (if $source == "" then null else $source end),
        wiki_url: (if $wiki_url == "" then null else $wiki_url end),
        wiki_section: (if $wiki_section == "" then null else $wiki_section end),
        wiki_item_ordinal: (if $wiki_item_ordinal == "" then null else ($wiki_item_ordinal | tonumber) end),
        result: {
          issue_iid: (if $issue_iid == "" then null else ($issue_iid | tonumber) end),
          issue_url: (if $issue_url == "" then null else $issue_url end),
          title: (if $title == "" then null else $title end),
          status: $result_status,
          reason: (if $reason == "" then null else $reason end)
        }
      }
    }'
)"

if [ "${status}" = "success" ]; then
  case "${action}" in
    created)
      printf 'Issue 已创建成功:\n\n'
      label_display="$(printf '%s' "${entry_label}" | tr '[:lower:]' '[:upper:]')"
      [ -n "${label_display}" ] || label_display="TODO"
      printf -- '- #%s %s ✅ (%s)\n\n' "${issue_iid:-?}" "${title}" "${label_display}"
      ;;
    *)
      printf 'Issue 已处理成功:\n\n'
      printf -- '- #%s %s ✅ (%s)\n\n' "${issue_iid:-?}" "${title}" "${action:-done}"
      ;;
  esac
else
  printf 'Issue 处理失败:\n\n'
  printf -- '- %s\n\n' "${reason:-unknown error}"
fi

printf '```json\n'
printf '%s\n' "${blue_json}" | jq .
printf '```\n'

if [ "${status}" = "success" ] && [ "${action}" = "created" ] && [ -n "${issue_iid}" ]; then
  printf '汇总：本次共创建 1 个 issue (#%s)。\n' "${issue_iid}"
elif [ "${status}" = "success" ] && [ -n "${issue_iid}" ]; then
  printf '汇总：本次已处理 issue (#%s)。\n' "${issue_iid}"
elif [ -n "${reason}" ]; then
  printf '汇总：未创建 issue，原因：%s\n' "${reason}"
else
  printf '汇总：未创建 issue。\n'
fi
