#!/usr/bin/env bash
#
# Tests for scripts/check-suite-on-main.sh -- the step in freshness.yml that
# fails when the tests.yml run that should answer for the current event is
# not `success`.
#
# Two layers of tests.
#
# 1. JSON-file cases (existing): plant a fixture and run the script with
#    the file path. The script reads it as the schedule / pull_request
#    response and applies newest-completed semantics, with cancelled
#    conclusions skipped and counted.
#
# 2. Env-driven cases (new): set GITHUB_EVENT_NAME and GITHUB_SHA, run the
#    script with no argument, and let a fake `gh` on $WORK/bin serve the
#    canned responses per call. The push cases exercise the poll loop and
#    the head_sha lookup; the schedule cases verify the per_page=30 query
#    and the cancelled-skipping. A fake `sleep` records its argument and
#    returns at once so the 32-attempt case finishes in milliseconds.
#
# The case that motivates this layer is the measured race on 2026-09-19:
# a push that fixed a red main was itself green, but this job ran on push
# at the same moment and read the previous commit's still-red run. Picking
# the run with the matching head_sha closes that race; the R1 case pins
# the closed behaviour.
#
# Requires: jq (same as the script itself).

set -uo pipefail

# The runner exports these; cases that need one set it on their own line.
unset GITHUB_EVENT_NAME GITHUB_SHA GITHUB_REPOSITORY REPO

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

# --- fake gh and fake sleep ------------------------------------------------
#
# Fake `gh`: logs NUL-separated argv to STUB_LOG and prints the Nth line of
# STUB_RESPONSES. Same shape as tests/reusable-schedule-freshness.test.sh
# so the two stubs stay symmetrical.
#
# Fake `sleep`: appends its argument to SLEEP_LOG and returns at once.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
LOG="${STUB_LOG:?stub log path required}"
RESP="${STUB_RESPONSES:?stub responses file required}"
idx=$(grep -cz . "$LOG" 2>/dev/null || true)
idx="${idx:-0}"
idx=$((idx + 1))
printf '%s\0' "$*" >> "$LOG"
val=$(awk -v n="$idx" 'NR==n {print; exit}' "$RESP")
printf '%s' "$val"
exit "${STUB_EXIT_CODE:-0}"
STUB
chmod +x "$WORK/bin/gh"

cat > "$WORK/bin/sleep" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$*" >> "${SLEEP_LOG:?sleep log path required}"
STUB
chmod +x "$WORK/bin/sleep"

# Put the stubs on PATH so every case below (existing and new) sees them.
# Existing cases do not call gh or sleep, so the stubs are inert for them.
export PATH="$WORK/bin:$PATH"

# --- shared helpers (used by both layers) ---------------------------------

# Run the script against a fixture, capture combined stdout+stderr in $out
# and the exit code in $rc. stdout has the verdict; stderr has the
# ::error:: annotation, which is what `::error::` resolves to in the
# runner log.
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

# --- env-driven layer (new cases) -----------------------------------------
#
# The fake `gh` returns one response per call. Build a push run object
# (carrying head_sha) and wrap a list into a page. Set GITHUB_EVENT_NAME
# and GITHUB_SHA on the run and read the gh log + sleep log back to
# verify the URL, the call count and the sleep count.

# Build one push run object: head_sha, status, conclusion, created_at, id.
# The local is named `rid` because jq reserves `id` as a keyword for the
# `reduce` and `foreach` family, and using `--arg id ...` shadows it.
push_run_obj() {
	local sha="$1" status="$2" concl="$3" t="$4" rid="$5"
	jq -nc --arg sha "$sha" --arg s "$status" --arg c "$concl" --arg t "$t" --arg rid "$rid" \
		'{ id: $rid,
		   name: "Tests",
		   status: $s,
		   conclusion: (if $c == "" then null else $c end),
		   created_at: $t,
		   updated_at: $t,
		   head_sha: $sha,
		   html_url: ("https://example.invalid/runs/" + $rid) }'
}

# Wrap push run objects into a page response.
push_page() {
	local r
	if [ $# -eq 0 ]; then
		r='[]'
	else
		r="$(printf '%s\n' "$@" | jq -cs '.')"
	fi
	jq -nc --argjson r "$r" '{ total_count: ($r | length), workflow_runs: $r }'
}

# Write the canned responses file: one JSON page per fake gh call.
write_responses() {
	: >"$WORK/responses.txt"
	for r in "$@"; do
		printf '%s\n' "$r"
	done >>"$WORK/responses.txt"
}

# Run the script in env-driven mode. $1=GITHUB_EVENT_NAME, $2=GITHUB_SHA.
# Reset gh and sleep logs first so each case starts at index 1.
#
# The env vars and the script call have to be on the same command line:
# `VAR=foo out="$(cmd)"` sets VAR=foo for the assignment to `out`, not for
# the subshell inside `$(...)`, and the script under test sees an empty
# GITHUB_EVENT_NAME. Putting everything in one command makes the prefix
# assignments bind to the inner subshell.
run_env() {
	local event="$1" sha="$2"
	rc=0
	: >"$WORK/gh.log"
	: >"$WORK/sleep.log"
	out="$(STUB_LOG="$WORK/gh.log" STUB_RESPONSES="$WORK/responses.txt" \
		SLEEP_LOG="$WORK/sleep.log" \
		GITHUB_EVENT_NAME="$event" GITHUB_SHA="$sha" GITHUB_REPOSITORY="owner/repo" \
		"$CHECK" 2>&1)" || rc=$?
}

# Count NUL-separated entries in a log file.
count_log() {
	grep -acz . "$1" 2>/dev/null | tr -d ' '
}

# Read the Nth argv from a NUL-separated log.
log_arg_n() {
	awk -v RS='\0' -v n="$1" 'NR==n {print; exit}' "$2"
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
check "R1: gh was called exactly once (the run was already completed)" "1" \
	"$( [ "$(count_log "$WORK/gh.log")" = "1" ] && echo 1 || echo 0)"
check "R1: sleep was never called (no need to wait)" "1" \
	"$( [ "$(count_log "$WORK/sleep.log")" = "0" ] && echo 1 || echo 0)"

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
