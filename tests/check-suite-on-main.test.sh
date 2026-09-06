#!/usr/bin/env bash
#
# Tests for scripts/check-suite-on-main.sh -- the step in freshness.yml that
# fails when the newest COMPLETED run of `tests.yml` on `main` is not
# `success`.
#
# Each case plants a fixture JSON, the shape
# `gh api repos/{owner}/{repo}/actions/workflows/tests.yml/runs` returns, and
# runs the script against it. A step body only a real runner can execute is
# not covered by anything: pulling the gh call out of the workflow and into
# scripts/ is what makes the logic testable here.
#
# The cases below plant both answers -- a failing conclusion and a passing
# one -- and require the script to distinguish them. A check that always
# exits 0 (or always exits 1) would satisfy the wrong half. The empty case
# is the third thing the script must NOT pass: with no completed run on
# record, the failure mode this exists to surface is "no record", not
# "successful silence".
#
# Requires: jq (same as the script itself).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$HERE/scripts/check-suite-on-main.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# Run the script against a fixture, capture combined stdout+stderr and the
# exit code. stdout has the verdict; stderr has the ::error:: annotation,
# which is what `::error::` resolves to in the runner log.
run() { # $1=fixture-path  -> stdout via $out, rc via $rc
	rc=0
	out="$("$CHECK" "$1" 2>&1)" || rc=$?
}

said() { printf '%s' "$out" | grep -qF "$1" && echo 1 || echo 0; }

# Build one run object. <status>, <conclusion>, <created_at>; <id> and
# <html_url> are placeholder strings -- the script does not match on them.
run_obj() {
	jq -nc --arg s "$1" --arg c "$2" --arg t "$3" \
		'{ id: "1",
		   name: "Tests",
		   status: $s,
		   conclusion: (if $c == "" then null else $c end),
		   created_at: $t,
		   updated_at: $t,
		   html_url: "https://example.invalid/runs/1" }'
}

# Wrap a list of run JSON objects into the API response shape. With no
# arguments the array is empty, which is the "no runs yet" fixture.
fixture() {
	local r
	if [ $# -eq 0 ]; then
		r='[]'
	else
		r="$(printf '%s\n' "$@" | jq -cs '.')"
	fi
	# `-n` because jq is building the response from --argjson, not reading
	# stdin; without -n jq waits for input and the output is empty.
	jq -nc --argjson r "$r" '{ total_count: ($r | length), workflow_runs: $r }' > "$WORK/runs.json"
	printf '%s' "$WORK/runs.json"
}

# --- a successful run passes -----------------------------------------------

run "$(fixture "$(run_obj completed success 2026-09-06T19:00:00Z)")"
check "a completed successful run passes" "0" "$rc"
check "and the verdict names the run that was checked" "1" "$(said 'Newest completed tests.yml run')"
check "and reports the conclusion that was checked" "1" "$(said 'conclusion: success')"
check "and says main is green" "1" "$(said 'main is green')"

# --- a failing run is reported ---------------------------------------------

run "$(fixture "$(run_obj completed failure 2026-09-06T19:32:00Z)")"
check "a completed failing run fails" "1" "$rc"
check "and the error names the conclusion" "1" "$(said "conclusion: failure")"
check "and says main is red" "1" "$(said 'main is red')"
check "and prints the ::error:: annotation for the runner log" "1" "$(said '::error::main is red')"

# --- a successful run is silent on the failure path ------------------------
#
# Plant both answers in one fixture and require the script to say green,
# not red. A check that always reported either would pass either case above.
run "$(fixture \
	"$(run_obj completed failure 2026-09-06T19:00:00Z)" \
	"$(run_obj completed success 2026-09-06T19:32:00Z)" \
)"
check "a successful newer run over an older failure passes" "0" "$rc"
check "and it picks the newer one by created_at" "1" \
	"$(said 'created_at: 2026-09-06T19:32:00Z')"

# --- a failing run wins when it is the newest completed --------------------
#
# The other direction: a newer failure over an older success must NOT be
# hidden by the older one being green. Without this case the test above
# could be satisfied by a script that always picks the first object in the
# array.
run "$(fixture \
	"$(run_obj completed failure 2026-09-06T19:32:00Z)" \
	"$(run_obj completed success 2026-09-06T19:00:00Z)" \
)"
check "a newer failure over an older success fails" "1" "$rc"
check "and it is the newer one that is named" "1" \
	"$(said 'created_at: 2026-09-06T19:32:00Z')"

# --- an in-progress run is not a verdict -----------------------------------
#
# The newest item in the list is in_progress and its conclusion is null;
# the only completed run is the older success, and the script must walk
# past the in-progress one to find it. A check that returned "newest" by
# array position would say the in_progress run is the verdict and exit 0,
# because null != "failure" and the script never sees the green one.
run "$(fixture \
	"$(run_obj in_progress '' 2026-09-06T19:30:00Z)" \
	"$(run_obj completed success 2026-09-06T19:00:00Z)" \
)"
check "an in_progress newest run does not hide the older completed success" "0" "$rc"
check "and the verdict names the completed one, not the in_progress one" "1" \
	"$(said 'created_at: 2026-09-06T19:00:00Z')"

# --- only in_progress runs on record say so --------------------------------
#
# A brand-new branch with a queued run and nothing else: the only honest
# answer is "no completed run yet", not success. The script's empty-result
# error is the failure case, and the assertion below pins its message so
# a future "I'll just exit 0 over an empty list" change is named, not
# guessed at from a runner log.
run "$(fixture "$(run_obj in_progress '' 2026-09-06T19:30:00Z)")"
check "only in_progress runs on record fails (not green by absence)" "1" "$rc"
check "and the empty-history message names the workflow" "1" \
	"$(said 'No completed run on record for tests.yml')"

# --- an empty history says so, rather than passing -------------------------
#
# This is the case the empty-history line was written for. A check that
# quietly passed here would mean a workflow file that never reached the
# runner (or a branch with no runs) reads as green, which is the exact
# failure mode this script exists to surface.
run "$(fixture)"
check "an empty history fails the script" "1" "$rc"
check "and says no completed run is on record" "1" \
	"$(said 'No completed run on record')"
check "and is not the failure-on-red error" "0" \
	"$(printf '%s' "$out" | grep -c 'main is red')"

# --- stdin also works ------------------------------------------------------
#
# The workflow saves the response to a file, but a future caller may pipe
# it instead. The script documents `-` for stdin; this case is what keeps
# that contract honest.
run "$(fixture "$(run_obj completed success 2026-09-06T19:00:00Z)")"
# Re-run via stdin, on the same JSON content the previous call wrote.
out="$("$CHECK" - < "$WORK/runs.json" 2>&1)"; rc=$?
check "reading JSON from stdin via '-' also passes for a green main" "0" "$rc"
check "and produces the same verdict as the file form" "1" "$(said 'main is green')"

# --- a missing argument and a missing file say so --------------------------
#
# These are usage errors, distinct from the empty-history failure. The
# script exits 2 in both cases so a future caller can tell a typo from a
# genuine "main is red".
out="$("$CHECK" 2>&1)"; rc=$?
check "no argument exits 2 and prints usage" "2" "$rc"
check "and the usage mentions both forms (file and stdin)" "1" \
	"$(printf '%s' "$out" | grep -c 'path-to-runs-json')"

out="$("$CHECK" /no/such/file 2>&1)"; rc=$?
check "a missing file exits 2 and names the path" "2" "$rc"
check "and the message says the file is not there" "1" "$(said 'no such file: /no/such/file')"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
