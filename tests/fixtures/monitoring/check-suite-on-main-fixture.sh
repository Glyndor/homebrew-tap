#!/usr/bin/env bash
#
# The shared fixture for the check-suite-on-main suites.
#
# It is sourced, not executed: it installs the fake `gh` and the fake `sleep` on
# PATH, the builders for the API answers, the runners of the script and the
# constants the cases read. It asserts nothing and prints no sentinel, because
# it is not a suite.
#
# Three suites source it:
#
#   tests/monitoring/check-suite-on-main.test.sh                             the JSON-file layer
#   tests/monitoring/check-suite-on-main/check-suite-on-main-push.test.sh      the push path
#   tests/monitoring/check-suite-on-main/check-suite-on-main-order.test.sh     the schedule path
#
# Requires: jq (same as the script itself).
# shellcheck disable=SC2034 # the variables are read by the suites that source this file

set -uo pipefail

# The runner exports these; cases that need one set it on their own line.
unset GITHUB_EVENT_NAME GITHUB_SHA GITHUB_REPOSITORY REPO

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHECK="$HERE/scripts/monitoring/check-suite-on-main.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- fake gh and fake sleep ------------------------------------------------
#
# Fake `gh`: logs NUL-separated argv to STUB_LOG and prints the Nth line of
# STUB_RESPONSES. Same shape as tests/ci/reusable/reusable-schedule-freshness.test.sh
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
# STUB_FAIL_FIRST=N: the first N calls fail like a 502, whatever else is set.
if [ "$idx" -le "${STUB_FAIL_FIRST:-0}" ]; then
	echo "gh: HTTP 502" >&2
	exit 1
fi
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
