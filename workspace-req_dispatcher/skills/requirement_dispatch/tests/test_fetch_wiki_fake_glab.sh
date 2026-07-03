#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-dispatcher-fetch-wiki.XXXXXX")"
FAKE_GLAB="${TEST_ROOT}/glab"
CALL_LOG="${TEST_ROOT}/glab.calls"

cat >"${FAKE_GLAB}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${CALL_LOG:?CALL_LOG required}"
if [ "$1" != "api" ]; then
  echo "unexpected glab command: $*" >&2
  exit 9
fi
if [ "${GITLAB_API_PROTOCOL:-}" != "http" ]; then
  echo "missing or wrong GITLAB_API_PROTOCOL: ${GITLAB_API_PROTOCOL:-}" >&2
  exit 10
fi
case "$2" in
  projects/claw_gitlab%2Fpx_ifp_hulat_test/wikis/product%2Frequirements)
    jq -nc --arg content $'## Login flow\nImplement password reset.\n\n## Export flow\nAdd CSV export.' '{content: $content}'
    ;;
  projects/claw_gitlab%2Fpx_ifp_hulat_test/wikis/product%2FExport%20Flow)
    jq -nc --arg content $'## Export flow\nAdd CSV export.' '{content: $content}'
    ;;
  *)
    echo "unexpected api path: $2" >&2
    exit 8
    ;;
esac
FAKE
chmod +x "${FAKE_GLAB}"

WIKI_URL="http://localhost:8081/claw_gitlab/px_ifp_hulat_test/-/wikis/product/requirements"
prepared="$(
  MESSAGE="请处理 ${WIKI_URL}" \
  FETCH_WIKI=1 \
  GLAB_BIN="${FAKE_GLAB}" \
  CALL_LOG="${CALL_LOG}" \
  GITLAB_HOST="localhost:8081" \
  GITLAB_API_PROTOCOL="http" \
  GITLAB_TOKEN="local-token" \
  bash "${SKILL_DIR}/scripts/prepare_wiki_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${prepared}")" != "success" ]; then
  echo "expected fetch mode to succeed with fake glab" >&2
  printf '%s\n' "${prepared}" >&2
  exit 1
fi

if [ "$(jq '.requirements | length' <<<"${prepared}")" -ne 2 ]; then
  echo "expected fetched wiki content to be split into two requirements" >&2
  printf '%s\n' "${prepared}" >&2
  exit 1
fi

expected_call='api projects/claw_gitlab%2Fpx_ifp_hulat_test/wikis/product%2Frequirements'
if ! grep -qx "${expected_call}" "${CALL_LOG}"; then
  echo "expected glab api call not found" >&2
  printf 'expected: %s\nactual:\n' "${expected_call}" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi

encoded_url="http://localhost:8081/claw_gitlab/px_ifp_hulat_test/-/wikis/product/Export%20Flow"
encoded="$(
  MESSAGE="请处理 ${encoded_url}" \
  FETCH_WIKI=1 \
  GLAB_BIN="${FAKE_GLAB}" \
  CALL_LOG="${CALL_LOG}" \
  GITLAB_HOST="localhost:8081" \
  GITLAB_API_PROTOCOL="http" \
  GITLAB_TOKEN="local-token" \
  bash "${SKILL_DIR}/scripts/prepare_wiki_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${encoded}")" != "success" ]; then
  echo "expected percent-encoded wiki slug to fetch successfully" >&2
  printf '%s\n' "${encoded}" >&2
  exit 1
fi

if [ "$(jq -r '.wiki_slug' <<<"${encoded}")" != "product/Export Flow" ]; then
  echo "expected wiki_slug to be URL-decoded for metadata" >&2
  printf '%s\n' "${encoded}" >&2
  exit 1
fi

missing_token="$(
  MESSAGE="请处理 ${WIKI_URL}" \
  FETCH_WIKI=1 \
  GLAB_BIN="${FAKE_GLAB}" \
  CALL_LOG="${CALL_LOG}" \
  GITLAB_HOST="localhost:8081" \
  GITLAB_API_PROTOCOL="http" \
  GITLAB_TOKEN="" \
  bash "${SKILL_DIR}/scripts/prepare_wiki_downstream_payloads.sh"
)"

if [ "$(jq -r '.status' <<<"${missing_token}")" != "failed" ]; then
  echo "expected missing token to fail in fetch mode" >&2
  printf '%s\n' "${missing_token}" >&2
  exit 1
fi

if ! grep -q "GITLAB_TOKEN is required" <<<"$(jq -r '.reason' <<<"${missing_token}")"; then
  echo "expected clear missing token reason" >&2
  printf '%s\n' "${missing_token}" >&2
  exit 1
fi

echo "ok prepare_wiki_downstream_payloads fetches wiki content with glab"
