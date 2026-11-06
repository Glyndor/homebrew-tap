#!/usr/bin/env bash
# Exercise the shipped schedule watcher with recorded gh URL arguments.
set -uo pipefail
HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../fixtures/ci" && pwd)"
# shellcheck disable=SC1091
. "$HERE_FIXTURE/schedule-freshness-fixture.sh"
pass=0
fail=0

# A recent response still passes when it came from the wrong repository;
# the URL assertion must reject that independent of the canned response.
printf '%s\n' "$(ago 1)" > "$WORK/mutated.resp"
for destination in other/repo owner/other; do
	python3 - "$WORKFLOW" "$WORK/wrong.yml" "$destination" <<'PYCASE'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text()
text, count = re.subn(r'base="repos/.*?/actions/', f'base="repos/{sys.argv[3]}/actions/', text)
assert count == 1
Path(sys.argv[2]).write_text(text)
PYCASE
	step_script "$WORK/wrong.yml" "Check the newest successful scheduled run" > "$WORK/step.sh"
	out="$(run_step "$MAX_AGE_DAYS" "$WORK/mutated.resp")"; rc=$?
	check "a recent response from $destination still reaches the success path" "0" "$rc"
	rc=0; right_repository || rc=$?
	check "the actual URL for $destination is rejected" "1" "$rc"
done
step_script "$WORKFLOW" "Check the newest successful scheduled run" > "$WORK/step.sh"

# --- a recent successful run passes -------------------------------------

printf '%s\n' "$(ago 1)" > "$WORK/recent.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/recent.resp")"; rc=$?
check "a 1-day-old successful run passes" "0" "$rc"
check "and the success line reports the computed age" "1" \
	"$(printf '%s' "$out" | grep -q '(1d ago)' && echo 1 || echo 0)"
check "and names the workflow it checked" "1" \
	"$(printf '%s' "$out" | grep -q "$WF" && echo 1 || echo 0)"

# --- an old run fails, naming the workflow and the age ------------------

printf '%s\n%s\n%s\n%s\n' "$(ago 11)" "" "" "$(ago 11)" > "$WORK/old.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/old.resp")"; rc=$?
check "an 11-day-old run fails the 10-day limit" "1" "$rc"
check "and the error names the workflow file (audit.yml)" "1" \
	"$(printf '%s' "$out" | grep -q "$WF last succeeded" && echo 1 || echo 0)"
check "and the error names the age it measured (11 days)" "1" \
	"$(printf '%s' "$out" | grep -q '11 days ago' && echo 1 || echo 0)"
check "and is not the empty-result error" "0" \
	"$(printf '%s' "$out" | grep -c 'No successful scheduled run')"

# --- an empty result fails with the empty-result error ------------------

printf '\n' > "$WORK/empty.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/empty.resp")"; rc=$?
check "no successful run on record fails" "1" "$rc"
check "and the error says 'No successful scheduled run'" "1" \
	"$(printf '%s' "$out" | grep -q 'No successful scheduled run' && echo 1 || echo 0)"
check "and names the workflow file (audit.yml)" "1" \
	"$(printf '%s' "$out" | grep -q "No successful scheduled run on record for ${WF}" && echo 1 || echo 0)"
check "and is not the too-old error" "0" \
	"$(printf '%s' "$out" | grep -c 'over the 10-day limit')"

# --- the URL filters by event=schedule AND status=success ---------------
#
# Without those two filters, the gate would happily report a *failed* run as
# evidence the cron is alive, which is the exact failure this gate exists to
# catch. So both substrings must appear in the URL the step actually built.

printf '%s\n' "$(ago 1)" > "$WORK/url.resp"
run_step "$MAX_AGE_DAYS" "$WORK/url.resp" >/dev/null
check "the URL the step built contains event=schedule" "1" \
	"$(grep -acz 'event=schedule' "$WORK/gh.log" | tr -d ' ')"
check "the URL the step built contains status=success" "1" \
	"$(grep -acz 'status=success' "$WORK/gh.log" | tr -d ' ')"
check "the URL targets the right workflow file" "1" \
	"$(grep -acz "workflows/${WF}/runs" "$WORK/gh.log" | tr -d ' ')"
check "and it made exactly one API call (no paging here)" "1" \
	"$(grep -acz . "$WORK/gh.log" | tr -d ' ')"

rc=0; right_repository || rc=$?
check "every live URL names the exact owner, repository and workflow" "0" "$rc"

# --- the newest run wins whatever order the page arrives in -------------
#
# Measured 2026-09-08 (Glyndor/apt#249): a one-item page returned a run from
# thirteen days earlier while that morning's success existed, and the gate
# reported 13 days on a cron that had fired. The step now reads a page and
# takes the greatest created_at, so this fixture puts the newest run in the
# middle of an unsorted page: the age reported must be the newest one's.
# Same-format ISO timestamps compare lexically as they do chronologically.

printf '{"workflow_runs":[{"created_at":"%s"},{"created_at":"%s"},{"created_at":"%s"}]}\n' \
	"$(ago 13)" "$(ago 1)" "$(ago 5)" > "$WORK/unordered.json"
out="$(run_step 3 "$WORK/unordered.resp.unused" "$WORK/unordered.json")"; rc=$?
check "an unsorted page still finds the newest run" "0" "$rc"
check "and reports the newest run's age, not the first item's" "1" \
	"$(printf '%s' "$out" | grep -c '(1d ago)')"
check "and the page it asked for holds more than one item" "1" \
	"$(grep -acz 'per_page=30' "$WORK/gh.log" | tr -d ' ')"

printf '{"workflow_runs":[]}\n' > "$WORK/empty-page.json"
out="$(run_step 3 "$WORK/unordered.resp.unused" "$WORK/empty-page.json")"; rc=$?
check "an empty page is still the missing-schedule error" "1" "$rc"
check "and says 'No successful scheduled run'" "1" \
	"$(printf '%s' "$out" | grep -c 'No successful scheduled run')"

# --- a workflow watching itself counts any conclusion ----------------------
#
# freshness.yml has a job that watches freshness.yml. With the success-only
# query that job can never recover once it fires: the run it fails is not a
# success, so the next query still finds only the old one, and so on with the
# cron alive the whole time. The caller passes count-any-conclusion and the
# query changes to status=completed, so a recent failed scheduled run is
# evidence the cron fires. The messages change with it, so a reader of the
# log is told which question was answered.

printf '%s\n' "$(ago 1)" > "$WORK/any.resp"
out="$(ANY_CONCLUSION=true run_step "$MAX_AGE_DAYS" "$WORK/any.resp")"; rc=$?
check "with count-any-conclusion a recent run of any conclusion passes" "0" "$rc"
check "and the URL asks for completed runs" "1" \
	"$(grep -acz 'status=completed' "$WORK/gh.log" | tr -d ' ')"
check "and not for successful ones" "0" \
	"$(grep -acz 'status=success' "$WORK/gh.log" | tr -d ' ')"
check "and the report says completed, not successful" "1" \
	"$(printf '%s' "$out" | grep -c 'Newest completed scheduled run')"

printf '%s\n%s\n%s\n%s\n' "$(ago 11)" "" "" "$(ago 11)" > "$WORK/any-old.resp"
out="$(ANY_CONCLUSION=true run_step "$MAX_AGE_DAYS" "$WORK/any-old.resp")"; rc=$?
check "with count-any-conclusion an old run still fails" "1" "$rc"
check "and the error says it last ran, not last succeeded" "1" \
	"$(printf '%s' "$out" | grep -c 'last ran on a schedule 11 days ago')"

printf '\n' > "$WORK/any-none.resp"
out="$(ANY_CONCLUSION=true run_step "$MAX_AGE_DAYS" "$WORK/any-none.resp")"; rc=$?
check "with count-any-conclusion no run on record still fails" "1" "$rc"
check "and says no completed run" "1" \
	"$(printf '%s' "$out" | grep -c 'No completed scheduled run')"

# --- boundary: exactly MAX_AGE_DAYS days old PASSES (the comparison is -gt)

printf '%s\n' "$(ago "$MAX_AGE_DAYS")" > "$WORK/boundary.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/boundary.resp")"; rc=$?
check "exactly MAX_AGE_DAYS days old passes (the comparison is -gt, not -ge)" "0" "$rc"

# --- a failing `gh` must fail the step ----------------------------------
#
# `set -euo pipefail` is supposed to carry a non-zero `gh` through, so an API
# error stops the job rather than being read as "no result", which would be
# reported as a dead schedule and send someone looking for the wrong thing.

printf '%s\n' "$(ago 1)" > "$WORK/apifail.resp"
out="$(STUB_EXIT_CODE=1 run_step "$MAX_AGE_DAYS" "$WORK/apifail.resp")"
rc=$?
check "a failing gh api call fails the step" "1" \
	"$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and does not report it as a missing schedule" "0" \
	"$(printf '%s' "$out" | grep -c 'No successful scheduled run')"

# --- the URL window filter is MAX_AGE_DAYS + 1 days ago ----------------
#
# The window asks the question the gate really has, which is whether any
# run exists inside the limit. Plus one day because the comparison is
# `age_days -gt MAX_AGE_DAYS` on whole days and the window must not be
# narrower than what that accepts.

printf '\n' > "$WORK/url-window.resp"
# The step reads the clock itself, so a run that crosses midnight UTC while
# the step runs builds its cutoff from either day. Read the cutoff on both
# sides of the step and accept either; reading it only afterwards failed a
# correct step whenever the date turned in between.
before=$(date -u -d "$((MAX_AGE_DAYS + 1)) days ago" +%Y-%m-%d)
run_step "$MAX_AGE_DAYS" "$WORK/url-window.resp" >/dev/null
after=$(date -u -d "$((MAX_AGE_DAYS + 1)) days ago" +%Y-%m-%d)
check "the first call's URL contains the window cutoff date" "1" \
	"$(awk -v RS='\0' 'NR==1 {print; exit}' "$WORK/gh.log" | grep -qE "created=%3E%3D(${before}|${after})T" && echo 1 || echo 0)"

# --- three windowed attempts with 20s sleep between ---------------------
#
# After three bad answers the unwindowed query runs once, so the worst
# case is four gh calls and two sleeps. The fake sleep on $WORK/bin
# appends its argument to $WORK/sleep.log and returns at once, reset per
# run_step, so no case really waits.

# B: empty, empty, then a recent run on the third attempt.
printf '%s\n%s\n%s\n' "" "" "$(ago 1)" > "$WORK/retry-pass.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/retry-pass.resp")"; rc=$?
check "B: empty, empty, recent passes (exit 0)" "0" "$rc"
check "B: gh was called exactly 3 times" "3" \
	"$(grep -acz . "$WORK/gh.log" | tr -d ' ')"
check "B: sleep was called exactly 2 times" "2" \
	"$(grep -acz . "$WORK/sleep.log" | tr -d ' ')"
check "B: each sleep argument was 20" "20 20" \
	"$(tr '\0' '\n' < "$WORK/sleep.log" | xargs)"

# C: empty, empty, empty, then an old unwindowed run.
printf '%s\n%s\n%s\n%s\n' "" "" "" "$(ago 11)" > "$WORK/retry-old.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/retry-old.resp")"; rc=$?
check "C: empty x3 then old unwindowed fails (exit 1)" "1" "$rc"
check "C: gh was called exactly 4 times" "4" \
	"$(grep -acz . "$WORK/gh.log" | tr -d ' ')"
check "C: the 4th call's URL does NOT contain the window filter" "1" \
	"$(awk -v RS='\0' 'NR==4 {print; exit}' "$WORK/gh.log" | grep -q 'created=' && echo 0 || echo 1)"
check "C: the output names the age it measured (11 days)" "1" \
	"$(printf '%s' "$out" | grep -q '11 days ago' && echo 1 || echo 0)"
check "C: sleep was called exactly 2 times" "2" \
	"$(grep -acz . "$WORK/sleep.log" | tr -d ' ')"

rc=0; right_repository || rc=$?
check "retries and the unwindowed fallback query the exact repository" "0" "$rc"

# D: four empty responses; the unwindowed one is empty too.
printf '%s\n%s\n%s\n%s\n' "" "" "" "" > "$WORK/all-empty.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/all-empty.resp")"; rc=$?
check "D: four empty responses fail (exit 1)" "1" "$rc"
check "D: gh was called exactly 4 times" "4" \
	"$(grep -acz . "$WORK/gh.log" | tr -d ' ')"
check "D: the output says no successful scheduled run on record" "1" \
	"$(printf '%s' "$out" | grep -q 'No successful scheduled run on record' && echo 1 || echo 0)"

# E: a good answer on the first call exits without sleeping.
printf '%s\n%s\n%s\n' "$(ago 1)" "" "" > "$WORK/first-good.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/first-good.resp")"; rc=$?
check "E: a first-call good answer passes (exit 0)" "0" "$rc"
check "E: gh was called exactly 1 time" "1" \
	"$(grep -acz . "$WORK/gh.log" | tr -d ' ')"
check "E: sleep was never called" "0" \
	"$(grep -acz . "$WORK/sleep.log" 2>/dev/null | tr -d ' ')"

# F: the API ignored the filter once; an old run on line 1, recent on
# line 2. The first answer is non-empty but too old, which the step
# treats like an empty one.
printf '%s\n%s\n' "$(ago 11)" "$(ago 1)" > "$WORK/filter-ignored.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/filter-ignored.resp")"; rc=$?
check "F: filter ignored once then recent passes (exit 0)" "0" "$rc"
check "F: gh was called exactly 2 times" "2" \
	"$(grep -acz . "$WORK/gh.log" | tr -d ' ')"

# G: contradiction; windowed empty 3 times, unwindowed sees a recent run.
g_seen=$(ago 1)
printf '%s\n%s\n%s\n%s\n' "" "" "" "$g_seen" > "$WORK/contradiction.resp"
out="$(run_step "$MAX_AGE_DAYS" "$WORK/contradiction.resp")"; rc=$?
check "G: windowed-empty then unwindowed-recent fails (exit 1)" "1" "$rc"
check "G: gh was called exactly 4 times" "4" \
	"$(grep -acz . "$WORK/gh.log" | tr -d ' ')"
check "G: output names both the windowed emptiness and the unwindowed timestamp" "1" \
	"$(printf '%s' "$out" | grep -q 'saw nothing 3 times' && printf '%s' "$out" | grep -q "$g_seen" && echo 1 || echo 0)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
