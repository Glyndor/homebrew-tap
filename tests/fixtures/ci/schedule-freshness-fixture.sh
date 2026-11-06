#!/usr/bin/env bash
# Shared harness for schedule-freshness behaviour tests; sourced by the suite.
#
# A cron that stops firing emits nothing at all, and "no alert" is
# indistinguishable from "all clear." This gate turns that silence into a
# red check on ordinary work, by treating the newest successful scheduled
# run as evidence the cron is alive, and failing when that signal is too
# old or absent.
#
# The step depends on GH_TOKEN, REPO, WORKFLOW, and MAX_AGE_DAYS from the
# environment; the only network call is a single `gh api ... --jq ...`. A
# fake `gh` on PATH records the URL it was called with and serves a canned
# response, so the cases below exercise the real shell with a deterministic
# API rather than mocking the workflow itself.
#
# Requires: python3, GNU date (for `date -u -d`).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

check() { # <description> <expected> <actual>
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

# Pull one step's `run:` body out of a workflow, dedented, so it can be run.
# Same helper as tests/ci/reusable/reusable-dco.test.sh: the point is to exercise the
# shell as it ships rather than a copy of it that can drift.
step_script() { # $1=workflow path  $2=step name substring
	python3 - "$1" "$2" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(lines) if "name: " + sys.argv[2] in l)
run = next(i for i, l in enumerate(lines) if i > start and l.strip() == "run: |")
body = []
for line in lines[run + 1:]:
    if not line.strip():
        body.append("")
        continue
    if not line.startswith(" " * 10):
        break
    body.append(line[10:])
print("\n".join(body))
PY
}

# Fake `gh`. Appends its argv (NUL-separated) to STUB_LOG and prints line 1
# of STUB_RESPONSES. There is only ever one call per step run, but a
# responses file makes the contract the same as the dependabot stub so the
# two tests stay symmetrical. An empty line is exactly what
# `gh --jq '... // empty'` produces when nothing matched.
#
# With STUB_JSON set, the stub instead runs the step's own `--jq` filter over
# that file with real jq, the way `gh api --jq` would over the response body.
# That is the only way to test what the filter does with a page whose first
# item is not the newest run, which is the case Glyndor/apt#249 measured.
write_stub() {
	mkdir -p "$WORK/bin"
	cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
LOG="${STUB_LOG:?stub log path required}"
RESP="${STUB_RESPONSES:?stub responses file required}"
idx=$(grep -cz . "$LOG" 2>/dev/null || true)
idx="${idx:-0}"
idx=$((idx + 1))
printf '%s\0' "$*" >> "$LOG"
[ "${1:-}" = api ] || exit 90
printf '%s\0' "${2:?URL required}" >> "${STUB_URL_LOG:?URL log required}"
if [ -n "${STUB_JSON:-}" ]; then
	filter=""; prev=""
	for arg in "$@"; do
		[ "$prev" = "--jq" ] && filter="$arg"
		prev="$arg"
	done
	jq -r "$filter" "$STUB_JSON"
	exit "${STUB_EXIT_CODE:-0}"
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
}

WORKFLOW="$HERE/.github/workflows/reusable-schedule-freshness.yml"
step_script "$WORKFLOW" "Check the newest successful scheduled run" > "$WORK/step.sh"
write_stub

REPO="owner/repo"
WF="audit.yml"
# Used by the sourcing suite.
# shellcheck disable=SC2034
MAX_AGE_DAYS=10

# Build an ISO timestamp N days before now. `date -u -d "N days ago"` is
# exactly N * 86400 seconds earlier -- UTC has no daylight saving, so crossing
# midnight or a month boundary changes nothing -- and setup and run are seconds
# apart, so `age_days` is N and not N+1. Measured, not assumed.
ago() { date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ; }

# Run the step with the stub on PATH. Combined stdout+stderr in `out`, exit
# code in `rc`. The stub log is reset per call so each case starts at index 1.
run_step() { # $1=MAX_AGE_DAYS  $2=responses file  $3=JSON page (optional)
	local max="$1" resp="$2" json="${3:-}"
	rm -f "$WORK/gh.log" "$WORK/sleep.log" "$WORK/urls.log"
	: >"$WORK/urls.log"
	: >"$WORK/gh.log"
	: >"$WORK/sleep.log"
	STUB_URL_LOG="$WORK/urls.log" STUB_LOG="$WORK/gh.log" STUB_RESPONSES="$resp" STUB_JSON="$json" \
	SLEEP_LOG="$WORK/sleep.log" \
	ANY_CONCLUSION="${ANY_CONCLUSION:-}" \
	PATH="$WORK/bin:$PATH" \
	GH_TOKEN=dummy REPO="$REPO" WORKFLOW="$WF" MAX_AGE_DAYS="$max" \
	bash "$WORK/step.sh" 2>&1
}

# Compare the actual URL argument from every invocation, including retries
# and the unwindowed fallback. Matching substrings in the jq filter cannot pass.
right_repository() {
	python3 - "$WORK/urls.log" "$REPO" "$WF" <<'PYURL'
from pathlib import Path
import sys
urls = Path(sys.argv[1]).read_bytes().split(b"\0")[:-1]
expected = f"repos/{sys.argv[2]}/actions/workflows/{sys.argv[3]}/runs"
sys.exit(0 if urls and all(url.decode().split("?", 1)[0] == expected for url in urls) else 1)
PYURL
}
