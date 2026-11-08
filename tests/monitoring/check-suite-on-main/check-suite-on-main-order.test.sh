#!/usr/bin/env bash
#
# Behaviour tests for the schedule path of scripts/monitoring/check-suite-on-main.sh:
# the page is not trusted to be sorted, cancelled runs are passed over, the
# query asks for per_page=30 and status=completed, and ties break by id.
#
# The fake `gh`, the builders and the runners come from
# tests/fixtures/monitoring/check-suite-on-main-fixture.sh.
#
# Requires: jq (same as the script itself).
set -uo pipefail

# shellcheck source=tests/fixtures/monitoring/check-suite-on-main-fixture.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/fixtures/monitoring/check-suite-on-main-fixture.sh"

pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# --- S0: any conclusion other than success is red ---------------------------
# timed_out, skipped, neutral, action_required, startup_failure: none is a pass.
# Only the literal "success" is, and a check written as `= "failure"` would let
# every other value through as green.
for concl in timed_out skipped neutral action_required startup_failure; do
	write_responses "$(push_page \
		"$(run_obj completed "$concl" 2026-09-19T15:30:00Z 300)" \
	)"
	run_env schedule ""
	check "S0: schedule with newest conclusion '$concl' is red" "1" "$rc"
	write_responses "$(push_page \
		"$(push_run_obj b completed "$concl" 2026-09-19T15:22:53Z 200)" \
	)"
	run_env push b
	check "S0: push with conclusion '$concl' is red" "1" "$rc"
done

# --- S1: schedule with an unsorted page (older success first) --------------
#
# On 2026-09-08 a one-item page returned a run from thirteen days
# earlier while that morning's success existed. The newest completed
# run is the second item; a script that trusted page order would pick
# the first.
write_responses "$(push_page \
	"$(run_obj completed success 2026-09-19T15:00:00Z 100)" \
	"$(run_obj completed failure 2026-09-19T15:30:00Z 200)" \
)"
run_env schedule ""
check "S1: schedule with unsorted page fails on the newer run" "1" "$rc"
check "S1: gh was called exactly once" "1" "$(count_log "$WORK/gh.log")"
check "S1: the output names the newer (failure) run" "1" \
	"$(said 'conclusion: failure')"
check "S1: sleep was never called" "1" \
	"$( [ "$(count_log "$WORK/sleep.log")" = "0" ] && echo 1 || echo 0)"

# --- S2: schedule with the newest completed run cancelled ------------------
#
# The newest completed conclusion is cancelled, the next is success.
# The script must skip the cancelled one and report the count.
write_responses "$(push_page \
	"$(run_obj completed cancelled 2026-09-19T15:30:00Z 200)" \
	"$(run_obj completed success 2026-09-19T15:00:00Z 100)" \
)"
run_env schedule ""
check "S2: schedule with newest cancelled and next success passes" "0" "$rc"
check "S2: the output says 1 cancelled run was passed over" "1" \
	"$(said '1 cancelled')"
check "S2: the output says main is green" "1" "$(said 'main is green')"

# --- S3: schedule with every completed run cancelled -----------------------
#
# The contract says "a page where every completed run was cancelled
# fails saying there is no verdict".
write_responses "$(push_page \
	"$(run_obj completed cancelled 2026-09-19T15:30:00Z 200)" \
	"$(run_obj completed cancelled 2026-09-19T15:00:00Z 100)" \
)"
run_env schedule ""
check "S3: schedule with every completed run cancelled fails" "1" "$rc"
check "S3: the error says there is no verdict" "1" \
	"$(printf '%s' "$out" | grep -qiF 'no verdict' && echo 1 || echo 0)"
check "S3: the error names the count" "1" "$(said '2')"

# --- S4: schedule queries with per_page=30 ---------------------------------
#
# Read the logged call, not the script source: the gh log captures the
# URL the script built, and per_page=30 has to be there.
write_responses "$(push_page \
	"$(run_obj completed success 2026-09-19T15:00:00Z 100)" \
)"
run_env schedule ""
check "S4: schedule asks for per_page=30" "1" \
	"$(log_arg_n 1 "$WORK/gh.log" | grep -q 'per_page=30' && echo 1 || echo 0)"
# Only main's runs may answer for main. tests.yml also runs on pull requests, so a
# URL without branch=main would let a red PR run stand in for the branch.
check "S4: schedule asks for the main branch" "1" \
	"$(log_arg_n 1 "$WORK/gh.log" | grep -q 'branch=main' && echo 1 || echo 0)"

# --- S5: schedule queries with status=completed ----------------------------
#
# In-flight runs (queued, in_progress) cannot be allowed to fill the
# 30-item page ahead of the newest completed one. The schedule URL must
# ask the API for completed runs up front; the local jq filter is the
# second guard, not the first.
write_responses "$(push_page \
	"$(run_obj completed success 2026-09-19T15:00:00Z 100)" \
)"
run_env schedule ""
check "S5: schedule asks for status=completed in the URL" "1" \
	"$(log_arg_n 1 "$WORK/gh.log" | grep -q 'status=completed' && echo 1 || echo 0)"

# --- S6/S7: schedule tie-break by id when created_at is identical ---------
#
# Same shape as R8/R9 but on the schedule path: two completed runs share
# created_at, lower id is success, higher id is failure, exercised in
# both orders. The verdict must be the higher id's in both.
#
# Reuses push_run_obj because the schedule jq only filters by status and
# conclusion, so the extra head_sha field is harmless, and run_obj hard-
# codes id to "1", which would defeat the test of the id tie-break.
write_responses "$(push_page \
	"$(push_run_obj _ completed success 2026-09-19T15:30:00Z 100)" \
	"$(push_run_obj _ completed failure 2026-09-19T15:30:00Z 200)" \
)"
run_env schedule ""
check "S6: schedule with tied created_at picks the higher id (lower first)" "1" \
	"$(said 'id:         200')"
check "S6: schedule with tied created_at reports the higher id's conclusion" "1" \
	"$(said 'conclusion: failure')"

write_responses "$(push_page \
	"$(push_run_obj _ completed failure 2026-09-19T15:30:00Z 200)" \
	"$(push_run_obj _ completed success 2026-09-19T15:30:00Z 100)" \
)"
run_env schedule ""
check "S7: schedule with tied created_at still picks the higher id (reversed)" "1" \
	"$(said 'id:         200')"
check "S7: schedule with tied created_at still reports the higher id's conclusion" "1" \
	"$(said 'conclusion: failure')"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
