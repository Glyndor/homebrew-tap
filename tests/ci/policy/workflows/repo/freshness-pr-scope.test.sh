#!/usr/bin/env bash
#
# freshness.yml answers questions about main and about crons, never about the
# change in a pull request, so it must not run on every pull request. It may
# run on one that changes what it is made of: the workflow itself, the two
# reusables it calls, the script its suite job runs and the one its tool-versions job runs. A filter that left its own file out would stop testing the
# workflow it guards, and a filter on a required check would never report it, so
# this also requires that no job of the file is one the repository requires.
# It also runs the step of the ruleset job, which on a pull request has to run the script of
# the base commit.
#
# Requires: git and python3 with PyYAML (tests.yml installs python3-yaml).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

# Prints "ok", or what is wrong with the pull_request trigger of a workflow.
scope() { # $1 = workflow file
	python3 - "$1" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
on = doc.get(True, doc.get("on", {}))
present = "pull_request" in on
pr = on.get("pull_request")
need = {".github/workflows/freshness.yml",
        ".github/workflows/reusable-dependabot-freshness.yml",
        ".github/workflows/reusable-schedule-freshness.yml",
        "scripts/monitoring/check-main-ruleset.sh",
        "scripts/monitoring/main-ruleset.expected.json",
        "scripts/monitoring/check-tool-versions.sh"}
if not present:
    print("ok")  # no pull_request trigger at all is also fine
elif not isinstance(pr, dict) or "paths" not in pr:
    print("the pull_request trigger has no paths filter")
else:
    missing = sorted(need - set(pr["paths"]))
    extra = sorted(set(pr["paths"]) - need)
    print("ok" if not missing and not extra else
          "paths missing: %s; paths not allowed: %s" % (missing, extra))
PY
}

mkdir -p "$WORK/c"
plant() { # $1 = file, rest = the pull_request block lines
	local f="$1"; shift
	{ printf 'on:\n'; printf '  %s\n' "$@"; printf 'jobs: {}\n'; } > "$f"
}
FULL=('pull_request:' '  paths:' '    - .github/workflows/freshness.yml' '    - .github/workflows/reusable-dependabot-freshness.yml' '    - .github/workflows/reusable-schedule-freshness.yml' '    - scripts/monitoring/check-main-ruleset.sh' '    - scripts/monitoring/main-ruleset.expected.json' '    - scripts/monitoring/check-tool-versions.sh')

plant "$WORK/c/good.yml" "${FULL[@]}"
check "the six files and nothing else pass" "ok" "$(scope "$WORK/c/good.yml")"
plant "$WORK/c/unfiltered.yml" 'pull_request:'
check "an unfiltered pull_request trigger is reported" "the pull_request trigger has no paths filter" "$(scope "$WORK/c/unfiltered.yml")"
plant "$WORK/c/noself.yml" 'pull_request:' '  paths:' '    - .github/workflows/reusable-dependabot-freshness.yml' '    - .github/workflows/reusable-schedule-freshness.yml' '    - scripts/monitoring/check-main-ruleset.sh' '    - scripts/monitoring/main-ruleset.expected.json' '    - scripts/monitoring/check-tool-versions.sh'
check "a filter that leaves out the workflow itself is reported" \
	"paths missing: ['.github/workflows/freshness.yml']; paths not allowed: []" "$(scope "$WORK/c/noself.yml")"
plant "$WORK/c/noscript.yml" 'pull_request:' '  paths:' '    - .github/workflows/freshness.yml' '    - .github/workflows/reusable-dependabot-freshness.yml' '    - .github/workflows/reusable-schedule-freshness.yml' '    - scripts/monitoring/check-tool-versions.sh'
check "a filter that leaves out the script the suite job runs is reported" \
	"paths missing: ['scripts/monitoring/check-main-ruleset.sh', 'scripts/monitoring/main-ruleset.expected.json']; paths not allowed: []" "$(scope "$WORK/c/noscript.yml")"
plant "$WORK/c/wide.yml" "${FULL[@]}" '    - README.md'
check "a filter wider than the six files is reported" \
	"paths missing: []; paths not allowed: ['README.md']" "$(scope "$WORK/c/wide.yml")"

plant "$WORK/c/notools.yml" "${FULL[@]:0:${#FULL[@]}-1}"
check "a filter that leaves out the script the tool-versions job runs is reported" \
	"paths missing: ['scripts/monitoring/check-tool-versions.sh']; paths not allowed: []" "$(scope "$WORK/c/notools.yml")"

check "the live freshness workflow passes" "ok" "$(scope "$HERE/.github/workflows/freshness.yml")"

# The ruleset check waits up to twenty minutes on a push, so a pull request that is
# pushed again must cancel the superseded poll, and main and the schedule never.
poll="$(python3 - "$HERE/.github/workflows/freshness.yml" <<'PY'
import sys, yaml
job = yaml.safe_load(open(sys.argv[1]))["jobs"]["ruleset"]
c = job.get("concurrency") or {}
print(c.get("cancel-in-progress", "missing"))
PY
)"
check "the ruleset check is cancelled by a newer push only on a pull request" \
	"\${{ github.event_name == 'pull_request' }}" "$poll"

# The ruleset job holds a token that writes, and the checkout of a pull request is written by the
# pull request, so there the script that runs is the base commit's. The step of the live workflow
# runs below in a repository whose base commit and tree hold stubs that say which one ran.
shape="$(python3 - "$HERE/.github/workflows/freshness.yml" "$WORK/step.sh" <<'PY'
import sys, yaml
job = yaml.safe_load(open(sys.argv[1]))["jobs"]["ruleset"]
steps = job["steps"]
runs = [s for s in steps if "run" in s]
open(sys.argv[2], "w").write("".join(s["run"] for s in runs))
env = runs[0].get("env", {}) if runs else {}
local = [s for s in steps if str(s.get("uses", "")).startswith("./")]
print("run steps=%d local actions=%d depth=%s" % (len(runs), len(local), steps[0].get("with", {}).get("fetch-depth")))
print("event=%s base=%s" % (env.get("EVENT"), env.get("BASE_SHA")))
PY
)"
check "the ruleset job has one script step, no action of the tree and the whole history" \
	"run steps=1 local actions=0 depth=0" "${shape%%$'\n'*}"
check "the step is told the event and the base commit of the pull request" \
	"event=\${{ github.event_name }} base=\${{ github.event.pull_request.base.sha }}" "${shape#*$'\n'}"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
repo="$WORK/repo"
script_path=scripts/monitoring/check-main-ruleset.sh
copy_path=scripts/monitoring/main-ruleset.expected.json
g() { git -C "$repo" -c user.name=suite -c user.email=suite@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
stub() { # $1 = base or tree
	# shellcheck disable=SC2016 # the stub expands its own argument
	printf 'echo "script=%s copy=$(cat "${1:-/dev/null}")"\n' "$1" >"$repo/$script_path"
	printf '%s\n' "$1" >"$repo/$copy_path"
}
git init -q "$repo"
mkdir -p "$repo/scripts/monitoring" "$WORK/runner"
g commit -q --allow-empty -m 'a base without the script'
bare="$(g rev-parse HEAD)"
stub base; g add -A; g commit -qm 'the base'
base="$(g rev-parse HEAD)"
stub tree; g add -A; g commit -qm 'the pull request'

step() { # <event> <base commit> ; prints what the step printed, then its exit status
	local rc=0 out
	out="$(cd "$repo" && EVENT="$1" BASE_SHA="$2" RUNNER_TEMP="$WORK/runner" bash -e "$WORK/step.sh" 2>&1)" || rc=$?
	printf '%s\nrc=%d' "$out" "$rc"
}
refusal() { # <event> <base commit> ; the exit status, the error of the step and whether a script ran
	local out
	out="$(step "$1" "$2")"
	printf '%s|%s|ran=%d' "${out##*$'\n'}" "$(grep '^::error::' <<<"$out")" "$(grep -c '^script=' <<<"$out")"
}

check "a pull request runs the script of the base commit on the copy of the tree" \
	$'script=base copy=tree\nrc=0' "$(step pull_request "$base")"
check "a base commit without the script fails the job and runs nothing" \
	"rc=1|::error::the script cannot be read from the base commit $bare, so the ruleset was not compared|ran=0" \
	"$(refusal pull_request "$bare")"
unknown=0123456789012345678901234567890123456789
check "a base commit that is not in the checkout fails the job and runs nothing" \
	"rc=1|::error::the script cannot be read from the base commit $unknown, so the ruleset was not compared|ran=0" \
	"$(refusal pull_request "$unknown")"
nobase="rc=1|::error::the event names no base commit, so the script that compares the ruleset cannot be read from it|ran=0"
check "a pull request that names no base commit is refused, not read from the index" "$nobase" "$(refusal pull_request '')"
check "a base that is a name and not a commit id is refused" "$nobase" "$(refusal pull_request HEAD)"
check "an event that is neither a schedule nor a push does not run the tree's script" "$nobase" "$(refusal merge_group '')"
check "a scheduled run still compares, with the script of its checkout" $'script=tree copy=\nrc=0' "$(step schedule '')"
check "a push still compares, with the script of its checkout" $'script=tree copy=\nrc=0' "$(step push '')"
g checkout -q "$base"
printf 'exit 3\n' >"$repo/$script_path"; g commit -qam 'a base whose comparison fails'
failing="$(g rev-parse HEAD)"
check "the verdict of the base's script is the verdict of the step" $'\nrc=3' "$(step pull_request "$failing")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
