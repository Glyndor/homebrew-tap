#!/usr/bin/env bash
#
# scripts/monitoring/scheduled-run-exists.sh: when a scheduled run has succeeded inside the window the sweep may be
# skipped, and in every other case, every doubt included, it must run. Both directions are read: a run that counts, and one
# for each reason it must not (too old, not a schedule, not a success, the run that is asking), then what the script does
# with a window, an id, a repository, a workflow and a response that are not usable, and the call to the API itself,
# through a gh that records what it was asked and answers from a file.
#
# Requires: jq.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$HERE/scripts/monitoring/scheduled-run-exists.sh"
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

TRY='23 2,5,8 25 11 *'
WEEKLY='23 5 * * 1'
ago() { date -u -d "$1 ago" +%Y-%m-%dT%H:%M:%SZ; }
# run <id> <event> <conclusion> <created_at>: one run of the response.
run_obj() { printf '{"id":%s,"event":"%s","conclusion":"%s","created_at":"%s"}' "$1" "$2" "$3" "$4"; }
# runs <obj>...: a response with those runs.
runs() { local IFS=,; printf '{"total_count":%s,"workflow_runs":[%s]}' "$#" "$*"; }
# ask <file> [VAR=value]...: what the script prints, from a response in a file.
ask() {
	local file="$1"; shift
	env DAYS=3 THIS_RUN_ID=900 EVENT_NAME=schedule EVENT_SCHEDULE="$TRY" WEEKLY_CRON="$WEEKLY" "$@" bash "$SCRIPT" "$file" 2>"$WORK/err"
}
planted() { printf '%s' "$1" > "$WORK/runs.json"; echo "$WORK/runs.json"; }

check "a scheduled run that succeeded a day ago lets the sweep be skipped" "skip=true" \
	"$(ask "$(planted "$(runs "$(run_obj 1 schedule success "$(ago '1 day')")")")")"
check "one that succeeded just inside the window does too" "skip=true" \
	"$(ask "$(planted "$(runs "$(run_obj 1 schedule success "$(ago '71 hours')")")")")"
check "one among others that did not count is enough" "skip=true" \
	"$(ask "$(planted "$(runs "$(run_obj 2 schedule failure "$(ago '1 hour')")" "$(run_obj 1 schedule success "$(ago '1 day')")")")")"
check "a response with no run at all runs the sweep" "skip=false" "$(ask "$(planted "$(runs)")")"
check "a scheduled run that succeeded four days ago is outside a window of three" "skip=false" \
	"$(ask "$(planted "$(runs "$(run_obj 1 schedule success "$(ago '4 days')")")")")"
check "a run that was started by hand does not count" "skip=false" \
	"$(ask "$(planted "$(runs "$(run_obj 1 workflow_dispatch success "$(ago '1 hour')")")")")"
check "a scheduled run that failed does not count" "skip=false" \
	"$(ask "$(planted "$(runs "$(run_obj 1 schedule failure "$(ago '1 hour')")")")")"
check "a scheduled run that was cancelled does not count" "skip=false" \
	"$(ask "$(planted "$(runs "$(run_obj 1 schedule cancelled "$(ago '1 hour')")")")")"
check "the run that is asking does not count for itself" "skip=false" \
	"$(ask "$(planted "$(runs "$(run_obj 900 schedule success "$(ago '1 minute')")")")")"
check "a window of one day leaves out a run of two" "skip=false" \
	"$(ask "$(planted "$(runs "$(run_obj 1 schedule success "$(ago '2 days')")")")" DAYS=1)"

# Only the extra tries may be skipped.
f="$(planted "$(runs "$(run_obj 1 schedule success "$(ago '1 hour')")")")"
for ev in push pull_request workflow_dispatch ""; do
	check "a run of the event '$ev' is never skipped" "skip=false" "$(ask "$f" EVENT_NAME="$ev")"
done
check "the weekly run is never skipped" "skip=false" "$(ask "$f" EVENT_SCHEDULE="$WEEKLY")"
check "a weekly cron that is not named runs the sweep and says why" "skip=false/1" \
	"$(ask "$f" WEEKLY_CRON="")/$(grep -c 'the cron of the weekly run is not named' "$WORK/err")"

# Every doubt runs the sweep.
f="$(planted "$(runs "$(run_obj 1 schedule success "$(ago '1 hour')")")")"
for days in "" 0 03 abc 1.5 -1; do
	check "a window of '$days' days runs the sweep and says why" "skip=false/1" \
		"$(ask "$f" DAYS="$days")/$(grep -c 'not a whole number above zero' "$WORK/err")"
done
for id in "" x 9x; do
	check "an id of this run that is '$id' runs the sweep and says why" "skip=false/1" \
		"$(ask "$f" THIS_RUN_ID="$id")/$(grep -c 'the id of this run' "$WORK/err")"
done
check "a response that is not JSON runs the sweep and says why" "skip=false/1" \
	"$(ask "$(planted 'not json')")/$(grep -c 'is not readable' "$WORK/err")"
check "a response that is an object without runs runs the sweep" "skip=false" "$(ask "$(planted '{"message":"Not Found"}')")"
check "a response whose runs are not a list runs the sweep" "skip=false" "$(ask "$(planted '{"workflow_runs":"x"}')")"
check "a file that is not there runs the sweep" "skip=false" "$(ask "$WORK/absent.json" 2>/dev/null)"
check "a response read from stdin counts as well" "skip=true" \
	"$(runs "$(run_obj 1 schedule success "$(ago '1 hour')")" | env DAYS=3 THIS_RUN_ID=900 EVENT_NAME=schedule EVENT_SCHEDULE="$TRY" WEEKLY_CRON="$WEEKLY" bash "$SCRIPT" - 2>/dev/null)"

# The call to the API: a gh that records its arguments and answers from a file.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/gh-calls"
[ -e "$WORK/gh-fails" ] && exit 1
cat "$WORK/gh-answer"
STUB
chmod +x "$WORK/bin/gh"
api() { env PATH="$WORK/bin:$PATH" DAYS=3 THIS_RUN_ID=900 EVENT_NAME=schedule EVENT_SCHEDULE="$TRY" WEEKLY_CRON="$WEEKLY" REPO=Glyndor/homebrew-tap WORKFLOW=mutation.yml "$@" bash "$SCRIPT" 2>"$WORK/err"; }
runs "$(run_obj 1 schedule success "$(ago '1 day')")" > "$WORK/gh-answer"
check "through the API a scheduled success lets the sweep be skipped" "skip=true" "$(api)"
check "and it asked for the scheduled successes of that workflow of that repository" "1" \
	"$(grep -c '^api repos/Glyndor/homebrew-tap/actions/workflows/mutation.yml/runs?event=schedule&status=success&per_page=30&created=%3E%3D20' "$WORK/gh-calls")"
runs > "$WORK/gh-answer"
check "through the API an empty answer runs the sweep" "skip=false" "$(api)"
: > "$WORK/gh-fails"
check "an API that fails runs the sweep and says why" "skip=false/1" "$(api)/$(grep -c 'could not be read' "$WORK/err")"
rm -f "$WORK/gh-fails"
check "a repository that is not owner/name runs the sweep and says why" "skip=false/1" \
	"$(api REPO=tap)/$(grep -c 'REPO is' "$WORK/err")"
for w in "" "../x.yml" "a/b.yml" "a b.yml" 'a;b.yml'; do
	check "a workflow named '$w' runs the sweep and says why" "skip=false/1" "$(api WORKFLOW="$w")/$(grep -c 'WORKFLOW is' "$WORK/err")"
done

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
