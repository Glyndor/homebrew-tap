#!/usr/bin/env bash
#
# Behaviour tests for scripts/monitoring/check-suite-on-main.sh against a JSON
# file: the newest completed run is the verdict, the usage when the argument is
# missing, and the message when the file is not there.
#
# The fake `gh`, the builders and the runners come from
# tests/fixtures/monitoring/check-suite-on-main-fixture.sh.
#
# Requires: jq (same as the script itself).
set -uo pipefail

# shellcheck source=tests/fixtures/monitoring/check-suite-on-main-fixture.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/fixtures/monitoring/check-suite-on-main-fixture.sh"

pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# --- JSON-file layer (existing cases) -------------------------------------

# a successful run passes
run "$(fixture "$(run_obj completed success 2026-09-06T19:00:00Z)")"
check "a completed successful run passes" "0" "$rc"
check "and the verdict names the run that was checked" "1" "$(said 'Newest completed tests.yml run')"
check "and reports the conclusion that was checked" "1" "$(said 'conclusion: success')"
check "and says main is green" "1" "$(said 'main is green')"

# a failing run is reported
run "$(fixture "$(run_obj completed failure 2026-09-06T19:32:00Z)")"
check "a completed failing run fails" "1" "$rc"
check "and the error names the conclusion" "1" "$(said "conclusion: failure")"
check "and says main is red" "1" "$(said 'main is red')"
check "and prints the ::error:: annotation for the runner log" "1" "$(said '::error::main is red')"

# a successful run is silent on the failure path
run "$(fixture \
	"$(run_obj completed failure 2026-09-06T19:00:00Z)" \
	"$(run_obj completed success 2026-09-06T19:32:00Z)" \
)"
check "a successful newer run over an older failure passes" "0" "$rc"
check "and it picks the newer one by created_at" "1" \
	"$(said 'created_at: 2026-09-06T19:32:00Z')"

# a failing run wins when it is the newest completed
run "$(fixture \
	"$(run_obj completed failure 2026-09-06T19:32:00Z)" \
	"$(run_obj completed success 2026-09-06T19:00:00Z)" \
)"
check "a newer failure over an older success fails" "1" "$rc"
check "and it is the newer one that is named" "1" \
	"$(said 'created_at: 2026-09-06T19:32:00Z')"

# an in-progress run is not a verdict
run "$(fixture \
	"$(run_obj in_progress '' 2026-09-06T19:30:00Z)" \
	"$(run_obj completed success 2026-09-06T19:00:00Z)" \
)"
check "an in_progress newest run does not hide the older completed success" "0" "$rc"
check "and the verdict names the completed one, not the in_progress one" "1" \
	"$(said 'created_at: 2026-09-06T19:00:00Z')"

# only in_progress runs on record say so
run "$(fixture "$(run_obj in_progress '' 2026-09-06T19:30:00Z)")"
check "only in_progress runs on record fails (not green by absence)" "1" "$rc"
check "and the empty-history message names the workflow" "1" \
	"$(said 'No completed run on record for tests.yml')"

# an empty history says so, rather than passing
run "$(fixture)"
check "an empty history fails the script" "1" "$rc"
check "and says no completed run is on record" "1" \
	"$(said 'No completed run on record')"
check "and is not the failure-on-red error" "0" \
	"$(printf '%s' "$out" | grep -c 'main is red')"

# stdin also works
run "$(fixture "$(run_obj completed success 2026-09-06T19:00:00Z)")"
out="$("$CHECK" - < "$WORK/runs.json" 2>&1)"; rc=$?
check "reading JSON from stdin via '-' also passes for a green main" "0" "$rc"
check "and produces the same verdict as the file form" "1" "$(said 'main is green')"

# a missing argument and a missing file say so
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
