#!/usr/bin/env bash
#
# Behaviour tests for the push path of scripts/monitoring/check-suite-on-main.sh:
# the verdict is the run whose head_sha is GITHUB_SHA, polled while it is not
# completed, with the tie-break by id and a cancelled run counted as red.
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

# --- R1: the measured race (push) ------------------------------------------
#
# The page holds an older, completed failure run for commit a and a newer,
# completed success run for commit b, with the a run placed FIRST in the
# page. SHA=b. Must pass, and the output names the run for b, not a.
#
# Before the fix, the script picked the newest item in the array (here
# the success for b), but the SAME shape with a red fix and a green
# previous commit was the race that produced the false red on 2026-09-19.
# The case pins the fix: even with the wrong run first, the script picks
# the one whose head_sha matches GITHUB_SHA.
write_responses "$(push_page \
	"$(push_run_obj a completed failure 2026-09-19T15:20:00Z 100)" \
	"$(push_run_obj b completed success 2026-09-19T15:22:53Z 200)" \
)"
run_env push b
check "R1: push with the older commit's run first still finds the pushed commit's run" "0" "$rc"
check "R1: the output names the run for b (id 200), not the one for a (id 100)" "1" \
	"$(said 'id:         200')"
check "R1: the output does not name the run for a" "0" \
	"$(printf '%s' "$out" | grep -c 'id:         100')"
check "R1: push asks for the main branch" "1" \
	"$(log_arg_n 1 "$WORK/gh.log" | grep -q 'branch=main' && echo 1 || echo 0)"
check "R1: push asks for the pushed commit's runs only" "1" \
	"$(log_arg_n 1 "$WORK/gh.log" | grep -q 'head_sha=b' && echo 1 || echo 0)"
check "R1: gh was called exactly once (the run was already completed)" "1" \
	"$( [ "$(count_log "$WORK/gh.log")" = "1" ] && echo 1 || echo 0)"
check "R1: sleep was never called (no need to wait)" "1" \
	"$( [ "$(count_log "$WORK/sleep.log")" = "0" ] && echo 1 || echo 0)"

# --- R1b: a transient gh failure on the push path is asked again ----------
# One 502 must not end a poll that has 31 attempts left; a failure that never
# clears must still end red, not green.
write_responses "$(push_page \
	"$(push_run_obj b completed success 2026-09-19T15:22:53Z 200)" \
)" "$(push_page \
	"$(push_run_obj b completed success 2026-09-19T15:22:53Z 200)" \
)"
STUB_FAIL_FIRST=1 run_env push b
check "R1b: a push poll survives one failing gh call" "0" "$rc"
check "R1b: and says it is asking again" "1" "$(said 'asking again')"
write_responses "$(push_page \
	"$(push_run_obj b completed success 2026-09-19T15:22:53Z 200)" \
)"
STUB_FAIL_FIRST=99 run_env push b
check "R1b: a gh failure that never clears ends red" "1" "$rc"

# --- R2: push with one sleep (run starts in_progress, finishes success) ---
#
# First call returns a page where the run for b is in_progress; second
# call returns the same run as completed success. Must pass, with
# exactly 1 sleep of 15.
write_responses \
	"$(push_page "$(push_run_obj b in_progress '' 2026-09-19T15:22:53Z 200)")" \
	"$(push_page "$(push_run_obj b completed success 2026-09-19T15:23:26Z 200)")"
run_env push b
check "R2: push with run still running then completed passes" "0" "$rc"
check "R2: gh was called exactly 2 times" "2" "$(count_log "$WORK/gh.log")"
check "R2: sleep was called exactly 1 time" "1" "$(count_log "$WORK/sleep.log")"
check "R2: the sleep argument was 15" "15" \
	"$(log_arg_n 1 "$WORK/sleep.log")"
check "R2: the verdict names the run for b" "1" "$(said 'id:         200')"

# --- R3: push with the run completing failure -------------------------------
#
# Same shape as R2 but the run finishes with conclusion failure. Must
# fail and name that run.
write_responses \
	"$(push_page "$(push_run_obj b in_progress '' 2026-09-19T15:22:53Z 200)")" \
	"$(push_page "$(push_run_obj b completed failure 2026-09-19T15:23:26Z 200)")"
run_env push b
check "R3: push with run completing failure fails" "1" "$rc"
check "R3: names that run (id 200)" "1" "$(said 'id:         200')"
check "R3: the error says main is red" "1" "$(said 'main is red')"
check "R3: the error annotation ::error::main is red is printed" "1" \
	"$(said '::error::main is red')"
check "R3: sleep was called exactly 1 time" "1" "$(count_log "$WORK/sleep.log")"

# --- R4: push with no run for the commit in 32 responses -------------------
#
# 32 empty responses. The script must exhaust 32 attempts, sleep 31
# times, then fail with a message that names the commit and says
# 8 minutes, and must not read another commit's run as a verdict.
write_responses
for _ in $(seq 1 32); do
	printf '{"workflow_runs":[]}\n' >>"$WORK/responses.txt"
done
run_env push b
check "R4: push with no run for the commit fails" "1" "$rc"
check "R4: gh was called exactly 32 times" "32" "$(count_log "$WORK/gh.log")"
check "R4: sleep was called exactly 31 times" "31" "$(count_log "$WORK/sleep.log")"
check "R4: the error names the commit (b)" "1" "$(said 'commit b')"
check "R4: the error says 8 minutes" "1" "$(said '8 minutes')"
check "R4: the error does not name another run's conclusion as the verdict" "0" \
	"$(printf '%s' "$out" | grep -c 'conclusion:')"
check "R4: the error says it refused to read another commit's run" "1" \
	"$(said 'refusing to read another commit')"

# --- R5: push with the run cancelled ---------------------------------------
#
# A `cancelled` run for the pushed commit is RED: nothing newer can
# answer for that commit. The script must fail without polling.
write_responses "$(push_page \
	"$(push_run_obj b completed cancelled 2026-09-19T15:22:53Z 200)" \
)"
run_env push b
check "R5: push with cancelled run fails" "1" "$rc"
check "R5: names that run (id 200)" "1" "$(said 'id:         200')"
check "R5: the conclusion is reported as cancelled" "1" "$(said 'conclusion: cancelled')"
check "R5: says main is red" "1" "$(said 'main is red')"
check "R5: the ::error:: annotation ::error::main is red is printed" "1" \
	"$(said '::error::main is red')"
check "R5: gh was called exactly once (no need to wait)" "1" \
	"$( [ "$(count_log "$WORK/gh.log")" = "1" ] && echo 1 || echo 0)"
check "R5: sleep was never called" "1" \
	"$( [ "$(count_log "$WORK/sleep.log")" = "0" ] && echo 1 || echo 0)"

# --- R6: push with previous commit failure plus pushed commit still running -
#
# then completing success ----------------------------------------------
#
# On 2026-09-19 this was the measured race: when this check ran, the
# pushed commit's tests.yml run was still in_progress, and the previous
# commit's run on the page was already completed with conclusion failure.
# A script that reads "the newest completed run" instead of "the run for
# this commit" passes every push case above and reports main is red over
# a run that has nothing to do with the pushed commit.
write_responses \
	"$(push_page \
		"$(push_run_obj a completed failure 2026-09-19T15:20:00Z 100)" \
		"$(push_run_obj b in_progress '' 2026-09-19T15:22:53Z 200)" \
	)" \
	"$(push_page \
		"$(push_run_obj a completed failure 2026-09-19T15:20:00Z 100)" \
		"$(push_run_obj b completed success 2026-09-19T15:23:26Z 200)" \
	)"
run_env push b
check "R6: push with previous commit failure plus pushed commit in_progress then success passes" "0" "$rc"
check "R6: gh was called exactly 2 times" "2" "$(count_log "$WORK/gh.log")"
check "R6: sleep was called exactly 1 time" "1" "$(count_log "$WORK/sleep.log")"
check "R6: the sleep argument was 15" "15" \
	"$(log_arg_n 1 "$WORK/sleep.log")"
check "R6: the output names the run for b (id 200), not the one for a (id 100)" "1" \
	"$(said 'id:         200')"
check "R6: the output does not name the run for a (id 100)" "0" \
	"$(printf '%s' "$out" | grep -c 'id:         100')"
check "R6: the output does not say main is red" "0" \
	"$(printf '%s' "$out" | grep -c 'main is red')"

# --- R7: push asks the API for head_sha=<pushed commit> ---------------------
#
# A re-run of an older commit produces a new run object with a different
# head_sha; if the script asks the API only for branch=main it gets a
# page where newer runs push the pushed commit's run past position 30,
# and every polling attempt reads the same wrong page. Adding head_sha
# to the query keeps the page bounded to runs for the pushed commit.
write_responses "$(push_page \
	"$(push_run_obj b completed success 2026-09-19T15:22:53Z 200)" \
)"
run_env push b
check "R7: push asks the API for head_sha=<pushed commit>" "1" \
	"$(log_arg_n 1 "$WORK/gh.log" | grep -q 'head_sha=b' && echo 1 || echo 0)"

# --- R8/R9: push tie-break by id when created_at is identical ---------------
#
# Two runs for the same commit with identical created_at, different ids
# and conclusions. The lower id is success, the higher id is failure.
# Without the tie-break the verdict would depend on which order the API
# returned, so the same shape is exercised in both orders and the
# verdict must be the higher id's in both.
#
# Two runs of the same commit with the same created_at can only happen
# on a re-run, but the API stamps both the queued run and the re-run
# with the same created_at to the second. Sorting newest first by
# created_at alone is not enough: page order would decide the verdict.
write_responses "$(push_page \
	"$(push_run_obj b completed success 2026-09-19T15:22:53Z 100)" \
	"$(push_run_obj b completed failure 2026-09-19T15:22:53Z 200)" \
)"
run_env push b
check "R8: push with tied created_at picks the higher id (lower first)" "1" \
	"$(said 'id:         200')"
check "R8: push with tied created_at reports the higher id's conclusion" "1" \
	"$(said 'conclusion: failure')"

write_responses "$(push_page \
	"$(push_run_obj b completed failure 2026-09-19T15:22:53Z 200)" \
	"$(push_run_obj b completed success 2026-09-19T15:22:53Z 100)" \
)"
run_env push b
check "R9: push with tied created_at still picks the higher id (reversed)" "1" \
	"$(said 'id:         200')"
check "R9: push with tied created_at still reports the higher id's conclusion" "1" \
	"$(said 'conclusion: failure')"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
