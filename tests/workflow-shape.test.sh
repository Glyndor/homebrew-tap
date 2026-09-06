#!/usr/bin/env bash
# Guard two workflow properties that nothing else checks.
#
# This repository requires no status check, by design: update.yml commits
# straight to main and the organisation forbids Actions from opening pull
# requests, so a required check would refuse the bot's own push. The apt
# channel does have them, and its copy of this file guards their names too;
# here there is one rule to guard.
#
# .github/workflows/drift.yml runs on schedule and workflow_dispatch, and
# on nothing else. The header explains why: pull_request would deadlock
# three channels (the first repository's pull request goes red on the
# others still carrying the old copy), and push: main reads its siblings
# from a CDN that serves the previous file for several minutes after a
# merge. The schedule sidesteps both rather than handling either.
# Re-adding either trigger is a two-word edit no test reads, and that is
# the gap this file closes.
#
# The rule is an absence check. A checker that returns nothing on a planted
# violation is the failure mode here, so the cases below plant one and require
# it to be named. `diff -q` confirms each plant actually changed the file
# before the result is read; otherwise the violation could not exist in the
# fixture and the case would pass for the wrong reason.
#
# Requires: python3.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOWS="$HERE/.github/workflows"

pass=0
fail=0

check() { # $1=description  $2=expected  $3=actual
	if [ "$2" = "$3" ]; then
		echo "ok    $1"
		pass=$((pass + 1))
	else
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# Verify drift.yml has the trigger set the header promises: schedule and
# workflow_dispatch only. Anything else is the design the file describes, but
# the actual file does not enforce it. The message names both reasons (the
# three-channel deadlock and the CDN staleness) so the next person who trips
# it does not have to read the header to find out why.
#
# YAML 1.1 parses bare `on` as the boolean True, so the triggers may be
# under either key. Accept both.
trigger_violations() { # $1=workflows dir
	python3 - "$1" <<'PY'
import os
import sys

import yaml

d = sys.argv[1]
path = os.path.join(d, "drift.yml")
if not os.path.exists(path):
    print("drift.yml: missing")
    sys.exit(0)
try:
    with open(path) as fh:
        spec = yaml.safe_load(fh)
except yaml.YAMLError as e:
    print(f"drift.yml: YAML parse error: {e}")
    sys.exit(0)
if not isinstance(spec, dict):
    print("drift.yml: not a mapping")
    sys.exit(0)
on = spec.get(True)
if not isinstance(on, dict):
    on = spec.get("on")
if not isinstance(on, dict):
    print("drift.yml: no on: triggers")
    sys.exit(0)
triggers = {k for k in on.keys() if isinstance(k, str)}
allowed = {"schedule", "workflow_dispatch"}
extras = sorted(triggers - allowed)
if extras:
    listed = ", ".join(extras)
    msg = (
        f"drift.yml: trigger(s) outside {{schedule, workflow_dispatch}}: "
        f"{listed}. Two reasons the file describes, neither visible from "
        f"the code: pull_request would deadlock three channels (the first "
        f"repository's pull request goes red on the others still carrying "
        f"the old copy); push: main reads its siblings from a CDN that "
        f"serves the previous file for several minutes after a merge. "
        f"Re-adding either brings that back."
    )
    print(msg)
PY
}

# --- the real tree ---------------------------------------------------------

check "drift.yml triggers only on schedule and workflow_dispatch in the real tree" \
	"" "$(trigger_violations "$WORKFLOWS")"

# --- planted violations ----------------------------------------------------

plant="$(mktemp -d)"
trap 'rm -rf "$plant"' EXIT
mkdir -p "$plant/.github/workflows"

# Snapshot the real tree so each plant starts from a true copy. The plants
# mutate from these; the originals stay untouched.
for f in "$WORKFLOWS"/*.yml; do
	cp "$f" "$plant/.github/workflows/$(basename "$f")"
done

# Confirm the plant actually changed the file before its result is read.
# `diff -q` returns 1 when files differ; that is the success case for a
# plant. The bare command would trip `set -e`, so the check is wrapped:
# "files differ" -> 1 (plant worked), "files match" -> 0 (plant did not).
plant_changed() { # $1=file  $2=bak
	if diff -q "$2" "$1" >/dev/null 2>&1; then
		echo 0
	else
		echo 1
	fi
}

# --- 1: drift.yml with a pull_request trigger ----------------------------
#
# Add `pull_request:` to drift.yml. The header says the file has to forbid
# this trigger; the checker must name it as the offender and state both
# reasons in the same message so the next person who trips it does not have
# to read the header to find out why.

cp "$plant/.github/workflows/drift.yml" "$plant/.github/workflows/drift.yml.bak"
python3 - "$plant/.github/workflows/drift.yml" <<'PY'
import sys
p = sys.argv[1]
src = open(p).read()
needle = "on:\n  schedule:\n    - cron: \"41 9 * * *\"\n  workflow_dispatch:\n"
repl = (
    "on:\n"
    "  schedule:\n"
    "    - cron: \"41 9 * * *\"\n"
    "  workflow_dispatch:\n"
    "  pull_request:\n"
)
assert needle in src, "expected on: block not found in drift.yml"
open(p, "w").write(src.replace(needle, repl))
PY
check "1: the plant added pull_request to drift.yml" \
	"1" "$(plant_changed "$plant/.github/workflows/drift.yml" "$plant/.github/workflows/drift.yml.bak")"
msg="$(trigger_violations "$plant/.github/workflows")"
check "1: drift.yml with a pull_request trigger is reported" \
	"1" "$(printf '%s' "$msg" | grep -q 'pull_request' && echo 1 || echo 0)"
check "1: and the message names the deadlock" \
	"1" "$(printf '%s' "$msg" | grep -q 'deadlock' && echo 1 || echo 0)"
check "1: and the CDN staleness" \
	"1" "$(printf '%s' "$msg" | grep -q 'CDN' && echo 1 || echo 0)"

# Restore drift.yml for the next plant.
cp "$plant/.github/workflows/drift.yml.bak" "$plant/.github/workflows/drift.yml"
rm -f "$plant/.github/workflows/drift.yml.bak"

# --- 2: drift.yml with a push: main trigger ------------------------------
#
# Add `push: branches: [main]` to drift.yml. The second defect the header
# names: the CDN serves the previous file for minutes after a merge, so
# every merge fired a red run describing a state that was already over.
# Same message; the design is the same.

cp "$plant/.github/workflows/drift.yml" "$plant/.github/workflows/drift.yml.bak"
python3 - "$plant/.github/workflows/drift.yml" <<'PY'
import sys
p = sys.argv[1]
src = open(p).read()
needle = "on:\n  schedule:\n    - cron: \"41 9 * * *\"\n  workflow_dispatch:\n"
repl = (
    "on:\n"
    "  schedule:\n"
    "    - cron: \"41 9 * * *\"\n"
    "  workflow_dispatch:\n"
    "  push:\n"
    "    branches: [main]\n"
)
assert needle in src, "expected on: block not found in drift.yml"
open(p, "w").write(src.replace(needle, repl))
PY
check "2: the plant added push: main to drift.yml" \
	"1" "$(plant_changed "$plant/.github/workflows/drift.yml" "$plant/.github/workflows/drift.yml.bak")"
msg="$(trigger_violations "$plant/.github/workflows")"
check "2: drift.yml with a push: main trigger is reported" \
	"1" "$(printf '%s' "$msg" | grep -qE 'push(:|\b)' && echo 1 || echo 0)"
check "2: and again names both reasons in the same message" \
	"1" "$(printf '%s' "$msg" | grep -q 'deadlock' && printf '%s' "$msg" | grep -q 'CDN' && echo 1 || echo 0)"
rm -f "$plant/.github/workflows/drift.yml.bak"

# --- an empty workflows tree is reported as missing, not as a pass ---------
#
# Same shape as the real-tree check above, against a directory with no
# workflows at all. A scanner that misreads an empty directory as "no
# violations" would pass the real-tree case (the real tree IS empty of
# violations for both rules); distinguishing the two is the difference
# between a watcher and a notifier that always agrees.

empty="$(mktemp -d)"
check "an empty workflows directory reports drift.yml missing, not a pass" \
	"drift.yml: missing" "$(trigger_violations "$empty")"
rm -rf "$empty"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
