#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-branch-utils.XXXXXX")"
REMOTE="${TEST_ROOT}/remote.git"
SRC="${TEST_ROOT}/src"
CLONE="${TEST_ROOT}/clone"

git init --bare --initial-branch=trunk "${REMOTE}" >/dev/null 2>&1

git init --initial-branch=trunk "${SRC}" >/dev/null 2>&1
git -C "${SRC}" config user.email "req-executor-test@example.invalid"
git -C "${SRC}" config user.name "req-executor-test"
printf 'hello\n' >"${SRC}/README.md"
git -C "${SRC}" add README.md
git -C "${SRC}" commit -m "initial" >/dev/null
git -C "${SRC}" remote add origin "${REMOTE}"
git -C "${SRC}" push origin trunk >/dev/null 2>&1

git clone "${REMOTE}" "${CLONE}" >/dev/null 2>&1

source "${SKILL_DIR}/scripts/branch_utils.sh"
resolved="$(resolve_origin_default_branch "${CLONE}")"

if [ "${resolved}" != "trunk" ]; then
  echo "expected default branch trunk, got ${resolved}" >&2
  exit 1
fi

echo "ok branch_utils resolves origin HEAD"
