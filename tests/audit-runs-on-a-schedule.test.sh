#!/usr/bin/env bash
#
# `brew audit` runs on a schedule, not only on pull requests.
#
# It is the one check that reads the published formulae against an external
# standard, and the commits that change those formulae raise no event it can
# trigger on: update.yml lands them with the GraphQL createCommitOnBranch
# mutation under GITHUB_TOKEN, and GitHub starts no workflow run for an event
# that token caused. Measured 2026-09-06 in #146: three bot rewrites of
# Formula/podup.rb on `main` over three days, and no `push` event on the branch
# at all across them, while `brew audit` was failing on every one of them.
#
# So the trigger this asserts is not a preference about cadence. Without it the
# gate reads a tree nobody publishes from, and the next time Homebrew changes
# what it accepts, the first person to find out is whoever opens the next pull
# request, which in this repository can be days later.
#
# The check is on the trigger and not on the cron string. A schedule that moves
# is somebody tuning it; a schedule that disappears is the defect.
#
# Requires: python3 with PyYAML (tests.yml installs python3-yaml).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pass=0
fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
		echo "ok    $1"
	else
		fail=$((fail + 1))
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
	fi
}

# Prints one line when the named workflow declares no schedule. Exit 1 then, 0
# otherwise. A missing file is a failure of its own: a check that shrugs at an
# absent input reports success over a smaller set than it claims.
scheduled() { # $1=workflows dir  $2=workflow file name
	python3 - "$1" "$2" <<'PY'
import os, sys
import yaml

root, name = sys.argv[1], sys.argv[2]
path = os.path.join(root, name)
if not os.path.isfile(path):
	print(f"{name}: not found under {root}")
	sys.exit(1)
with open(path) as f:
	doc = yaml.safe_load(f) or {}
# PyYAML resolves the bare key `on` to the boolean True, which is why this
# reads both spellings rather than doc["on"].
triggers = doc.get("on", doc.get(True)) or {}
if not isinstance(triggers, dict) or not triggers.get("schedule"):
	print(f"{name}: declares no schedule; the commits it audits raise no push event")
	sys.exit(1)
sys.exit(0)
PY
}

# --- the control: a workflow with no schedule is reported --------------------
mkdir -p "$WORK/planted"
cat > "$WORK/planted/audit.yml" <<'EOF'
name: Audit
on:
  pull_request:
  push:
    branches: [main]
jobs:
  audit:
    runs-on: macos-latest
    steps:
      - run: brew audit --strict glyndor/tap/podup
EOF
rc=0; out="$(scheduled "$WORK/planted" audit.yml)" || rc=$?
check "a workflow with no schedule is reported" "1" "$rc"
check "and the report says what is missing" "1" \
	"$(printf '%s\n' "$out" | grep -c 'declares no schedule')"

# The same file with a schedule passes, so the control above is the trigger and
# not the shape of the rest of the workflow.
mkdir -p "$WORK/fixed"
sed 's/^on:$/on:\n  schedule:\n    - cron: "19 9 * * *"/' \
	"$WORK/planted/audit.yml" > "$WORK/fixed/audit.yml"
rc=0; scheduled "$WORK/fixed" audit.yml >/dev/null || rc=$?
check "the same workflow with a schedule passes" "0" "$rc"

# A named workflow that is not there fails rather than passing over nothing.
mkdir -p "$WORK/empty"
rc=0; out="$(scheduled "$WORK/empty" audit.yml)" || rc=$?
check "a missing workflow is a failure, not a skip" "1" "$rc"
check "and it is named as missing" "1" "$(printf '%s\n' "$out" | grep -c 'not found')"

# --- the live workflow -------------------------------------------------------
rc=0; out="$(scheduled "$HERE/.github/workflows" audit.yml)" || rc=$?
check "brew audit runs on a schedule in this repository" "0" "$rc"
[ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/        /'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
