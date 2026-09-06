#!/usr/bin/env bash
#
# Every non-caller job in a workflow carries a `timeout-minutes`.
#
# GitHub's default is six hours. A job that hangs (brew auto-updating on a
# slow network, an apt step hung on a stalled download, a curl with no
# --max-time waiting on a peer that never replies) burns that six hours and
# blocks everything behind it. A measured `timeout-minutes` on every job
# bounds the worst case to an honest, integer multiple of the job's real
# duration, so a hang fails closed within the budget the job itself
# justifies, instead of wearing the runner's full day.
#
# Caller jobs are exempt. A job whose entry is `uses: .../reusable-...yml`
# delegates its work to that reusable, and the reusable's own job carries
# the bound. A caller cannot carry one in any case (GitHub rejects it on
# callers), so the rule is framed as "no `uses:` key, then it must declare
# timeout-minutes" rather than as a list of caller names. A caller
# identified by its name list would drift; "no `uses:` key" reads from the
# structure.
#
# The check is shown red against a planted violation before the live tree
# is read, the same shape as tests/lint-workflow-shell.test.sh: a script
# that compares the right thing against any tree passes just as happily as
# a script that compares nothing.
#
# Requires: python3 with PyYAML.

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

# Print one line per offending job: "<file> job <id>: missing timeout-minutes".
# Exit 1 when any line was printed, 0 otherwise.
#
# A caller job is identified by a `uses:` key, not by name. A job that
# carries `uses:` AND other keys (with:, secrets:, permissions:, etc.) is
# still a caller and is still exempt.
audit() { # $1=workflows dir
	python3 - "$1" <<'PY'
import glob, os, sys
import yaml

root = sys.argv[1]
bad = 0
for path in sorted(glob.glob(os.path.join(root, "*.yml"))):
	with open(path) as fh:
		doc = yaml.safe_load(fh) or {}
	for job_id, job in (doc.get("jobs") or {}).items():
		if not isinstance(job, dict):
			continue
		# A caller (anything carrying a `uses:` key) cannot declare
		# timeout-minutes; the reusable it points at carries the bound.
		# Anything else must declare one, since the default is six hours.
		if "uses" in job:
			continue
		if "timeout-minutes" not in job:
			bad += 1
			print(f"{os.path.basename(path)} job {job_id}: missing timeout-minutes")
sys.exit(1 if bad else 0)
PY
}

# --- the control: a planted violation is reported --------------------------
mkdir -p "$WORK/planted"
cat > "$WORK/planted/bad.yml" <<'EOF'
name: bad
on: [push]
jobs:
  unbounded:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
  bounded:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - run: echo hi
  pure-caller:
    uses: ./.github/workflows/reusable-shell-ci.yml
  caller-with-inputs:
    uses: ./.github/workflows/reusable-schedule-freshness.yml
    with:
      workflow: audit.yml
      max-age-days: 7
EOF

rc=0; out="$(audit "$WORK/planted")" || rc=$?
check "a job with neither uses nor timeout-minutes is reported" "1" "$rc"
check "and the report names the file and the job and the missing key" "1" \
	"$(printf '%s\n' "$out" | grep -c 'bad.yml job unbounded: missing timeout-minutes')"
check "a job that carries timeout-minutes is not reported" "0" \
	"$(printf '%s\n' "$out" | grep -c 'job bounded')"
check "a pure caller (uses only) is not held to the rule" "0" \
	"$(printf '%s\n' "$out" | grep -c 'pure-caller')"
check "a caller that carries uses plus with is not held to the rule" "0" \
	"$(printf '%s\n' "$out" | grep -c 'caller-with-inputs')"

# --- the live workflows -----------------------------------------------------
rc=0; out="$(audit "$HERE/.github/workflows")" || rc=$?
check "every non-caller job in this repository's workflows carries timeout-minutes" "0" "$rc"
[ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/        /'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
