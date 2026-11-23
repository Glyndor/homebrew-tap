#!/usr/bin/env bash
# The first step of the guard in pushes-to-main.yml, run with the answers of a fake `gh`: the scripts of the commit main
# had are run only when the guard passed on it, or when it came before the guard existed. A commit with no run of the guard
# (pushed with [skip ci], or while the workflow was disabled), one whose guard failed, a run of another app, an answer
# that is cut short or cannot be read, and a guard that never finishes all stop the job, each with its own message; one
# that is still running is waited for.
# Requires: bash, jq, python3 with PyYAML.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
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
python3 -I - "$HERE" "$WORK" <<'PY'
import sys, yaml
here, work = sys.argv[1:3]
guard = yaml.safe_load(open(f"{here}/.github/workflows/pushes-to-main.yml"))["jobs"]["guard"]
step = guard["steps"][0]
open(f"{work}/run.sh", "w").write(step["run"])
open(f"{work}/job", "w").write(guard["name"])
open(f"{work}/attempts", "w").write(step["env"]["ATTEMPTS"])
PY
mkdir "$WORK/bin" "$WORK/api"
cat >"$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$2" in
	*"/contents/.github/workflows/pushes-to-main.yml?ref="*)
		[ ! -e "$API/FAIL-contents" ] || { echo "connection reset" >&2; exit 1; }
		[ -e "$API/contents.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
		cat "$API/contents.json" ;;
	*/commits/*/check-runs*)
		case "$2" in *filter=all*) ;; *) exit 3 ;; esac
		n=$(($(cat "$API/calls" 2>/dev/null || echo 0) + 1)); echo "$n" >"$API/calls"
		[ ! -e "$API/FAIL-runs" ] || exit 1
		# the answers of the successive calls: runs-1.json, runs-2.json, the last one repeats
		f="$API/runs-$n.json"; [ -e "$f" ] || f="$API/runs-last.json"
		cat "$f" ;;
	*) exit 2 ;;
esac
GH
chmod +x "$WORK/bin/gh"
B=2222222222222222222222222222222222222222
answer() { # <file> <app id> <status:conclusion>...
	local file="$1" app="$2" out="" sep="" n=0; shift 2
	for c in "$@"; do out="$out$sep{\"app\":{\"id\":$app},\"status\":\"${c%%:*}\",\"conclusion\":\"${c#*:}\"}"; sep=","; n=$((n + 1)); done
	printf '{"total_count":%s,"check_runs":[%s]}' "$n" "$out" >"$WORK/api/$file.json"
}
fresh() { rm -rf "$WORK/api"; mkdir "$WORK/api"; printf 'file' >"$WORK/api/contents.json"; }
run() { # env overrides: the exit status, and how many times the runs were asked for
	env PATH="$WORK/bin:$PATH" API="$WORK/api" REPO=Glyndor/homebrew-tap BEFORE="${BEFORE-$B}" GUARD_JOB="$(cat "$WORK/job")" \
		ATTEMPTS="${ATTEMPTS-3}" PAUSE=0 bash "$WORK/run.sh" >"$WORK/log" 2>&1
	echo "rc=$?|calls=$(cat "$WORK/api/calls" 2>/dev/null || echo 0)"
}
said() { grep -c -- "$1" "$WORK/log"; }

check "the step is given a limit of attempts, and a pause that the test can shorten" "60" "$(cat "$WORK/attempts")"
fresh; answer runs-last 15368 completed:success
check "a commit main had whose guard passed lets the scripts run" "rc=0|calls=1" "$(run)"
fresh; answer runs-last 15368 completed:success completed:failure
check "a guard that failed once and passed after does not: every attempt counts" "rc=1|calls=1" "$(run)"
check "and says that the guard did not pass" "1" "$(said 'the guard did not pass on the commit main had')"
fresh; answer runs-last 15368 completed:failure
check "a guard that failed stops the job" "rc=1|calls=1" "$(run)"
fresh; answer runs-last 15368 completed:skipped
check "a guard that was skipped does not count" "rc=1|calls=1" "$(run)"
fresh; printf '{"total_count":0,"check_runs":[]}' >"$WORK/api/runs-last.json"
check "a commit with no run of the guard stops the job" "rc=1|calls=1" "$(run)"
check "and says it was judged by nobody" "1" "$(said 'judged by nobody')"
fresh; answer runs-last 99 completed:success
check "a run of another app with the name of the guard does not count" "rc=1|calls=1" "$(run)"
fresh; answer runs-1 15368 in_progress:null; answer runs-last 15368 completed:success
check "a guard that is still running is waited for, and then passes" "rc=0|calls=2" "$(run)"
fresh; answer runs-last 15368 queued:null
check "a guard that never finishes stops the job after its attempts" "rc=1|calls=3" "$(run)"
check "and says it was still running" "1" "$(said 'still running on the commit main had after 3 attempts')"
fresh; printf '{"total_count":3,"check_runs":[{"app":{"id":15368},"status":"completed","conclusion":"success"}]}' >"$WORK/api/runs-last.json"
check "a list of runs that is cut short stops the job" "rc=1|calls=1" "$(run)"
fresh; printf 'not json' >"$WORK/api/runs-last.json"
check "an answer that is not JSON stops the job" "rc=1|calls=1" "$(run)"
fresh; touch "$WORK/api/FAIL-runs"
check "runs that cannot be read stop the job" "rc=1|calls=1" "$(run)"
fresh; rm "$WORK/api/contents.json"
check "a commit with no workflow of the guard in it is the root of the chain and lets the scripts run, with nothing asked" "rc=0|calls=0" "$(run)"
fresh; touch "$WORK/api/FAIL-contents"
check "whether the commit holds the guard, when that cannot be read, stops the job" "rc=1|calls=0" "$(run)"
fresh; answer runs-last 15368 completed:success
check "a commit that is not a hash stops the job" "rc=1|calls=0" "$(BEFORE=main run)"
check "the zero commit of a new branch stops the job" "rc=1|calls=0" "$(BEFORE=0000000000000000000000000000000000000000 run)"
check "ATTEMPTS that is not a number stops the job" "rc=1|calls=0" "$(ATTEMPTS=x run)"

echo
echo "passed: $pass  failed: $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
