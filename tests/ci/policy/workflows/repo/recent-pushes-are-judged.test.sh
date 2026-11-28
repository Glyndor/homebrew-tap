#!/usr/bin/env bash
# The scheduled job that asks whether the guard of every push ran on the last commits of main is
# written in the workflow, and does what it says.
#
#   * the step is in freshness.yml and calls nothing of the tree (no script, no `./`), because the
#     updater app cannot change a workflow and can change a script, so a push cannot change its own
#     watcher;
#   * it is a job of its own, with no checkout and no step that uses an action, so nothing that runs the
#     code of the repository shares its runner or its environment, and the job that does (the ruleset
#     one) no longer holds it;
#   * it names the guard job exactly as pushes-to-main.yml does, the integration of GitHub Actions
#     (15368), every attempt (`filter=all`), and every commit from the head of main down to the commit
#     that introduced the workflow of the guard (taken from the history of that file, never written by
#     hand or read as a date) or to the commit recorded in VERIFIED_FROM, page by page, and it is itself
#     judged; a scan that does not reach that commit within MAX_PAGES fails, a full page is not a success;
#   * run with answers of a fake `gh`: a commit with a passing run is fine; one with no run, with a
#     failed attempt, with a run of another app, with a list cut short or with an API that fails is
#     refused, and a scheduled run opens one issue per commit, titled with its sha and only
#     counted against open issues of the workflow with that exact title.
# Requires: bash, jq, python3 with PyYAML.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
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
fresh = yaml.safe_load(open(f"{here}/.github/workflows/freshness.yml"))
job = fresh["jobs"].get("guard-ran", {"steps": []})
steps = [s for s in job["steps"] if s.get("name", "").startswith("Check that the guard of every push ran")]
other = [s for s in fresh["jobs"]["ruleset"]["steps"] if "guard of every push" in s.get("name", "")]
open(f"{work}/other.count", "w").write(str(len(other)))
open(f"{work}/uses.count", "w").write(str(sum(1 for s in job["steps"] if "uses" in s)))
open(f"{work}/steps.count", "w").write(str(len(job["steps"])))
open(f"{work}/needs", "w").write(str(job.get("needs", "")))
open(f"{work}/step.count", "w").write(str(len(steps)))
step = steps[0] if steps else {"run": "", "env": {}}
open(f"{work}/run.sh", "w").write(step["run"])
env = step.get("env", {})
open(f"{work}/job", "w").write(str(env.get("GUARD_JOB", "")))
open(f"{work}/env-keys", "w").write(" ".join(sorted(env)))
guard = yaml.safe_load(open(f"{here}/.github/workflows/pushes-to-main.yml"))
open(f"{work}/guard-name", "w").write(guard["jobs"]["guard"]["name"])
PY
check "the freshness workflow has the step, once" "1" "$(cat "$WORK/step.count")"
check "the step is the only one of its job" "1" "$(cat "$WORK/steps.count")"
check "its job checks nothing out and uses no action: nothing of the repository runs there" "0" "$(cat "$WORK/uses.count")"
check "its job waits for no other, so none of them can have written to its environment" "" "$(cat "$WORK/needs")"
check "the job of the ruleset, which runs the code of the repository, no longer holds a step about the guard" "0" "$(cat "$WORK/other.count")"
check "the step names the guard job exactly as pushes-to-main.yml does" "$(cat "$WORK/guard-name")" "$(cat "$WORK/job")"
check "the step takes the cut-off from the history of the workflow of the guard" "1" "$(grep -c 'path=.github/workflows/pushes-to-main.yml' "$WORK/run.sh")"
check "and carries no commit written by hand" "0" "$(grep -cE 'GUARD_CUTOFF|[0-9a-f]{40}' "$WORK/run.sh" "$WORK/env-keys" | grep -vc ':0$')"
check "the step calls no script of the tree" "0" "$(grep -cE '(^|[ "(])(\./|scripts/|bash |sh )' "$WORK/run.sh")"
check "the step reads the commits of main by pages of a hundred" "1" "$(grep -c 'commits?sha=main&per_page=100&page=' "$WORK/run.sh")"
check "and no longer asks for a window of fifty that a full page would pass" "0" "$(grep -c 'per_page=50' "$WORK/run.sh")"
check "the step asks for every attempt" "1" "$(grep -c 'filter=all' "$WORK/run.sh")"
check "the step counts only the integration of GitHub Actions" "1" "$(grep -c 'app.id == 15368' "$WORK/run.sh")"
check "the step reads no date of a commit" "0" "$(grep -cE 'since=|until=|committer.date|author.date|date -' "$WORK/run.sh")"

# The logic, with a fake gh.
A=1111111111111111111111111111111111111111
B=2222222222222222222222222222222222222222
C=3333333333333333333333333333333333333333
CUT=4444444444444444444444444444444444444444
mkdir "$WORK/bin" "$WORK/api"
cat >"$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1" in
	api)
		case "$2" in
			*"/contents/.github/workflows/pushes-to-main.yml"*)
				[ ! -e "$API/FAIL-contents" ] || { echo "connection reset" >&2; exit 1; }
				[ -e "$API/contents.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
				cat "$API/contents.json"; exit 0 ;;
			*"/commits?sha=main&path="*) f=guard ;;
			*"/commits?sha=main&per_page=100&page="*) page="${2##*page=}"; if [ "$page" = 1 ]; then f=list; else f="list-$page"; fi ;;
			*/commits/*/check-runs*) f="runs-$(printf '%s' "$2" | sed 's|.*/commits/\([^/]*\)/check-runs.*|\1|')"; case "$2" in *filter=all*) ;; *) exit 3 ;; esac ;;
			*) exit 2 ;;
		esac
		[ ! -e "$API/FAIL-$f" ] || exit 1
		[ -e "$API/$f.json" ] || exit 1
		cat "$API/$f.json" ;;
	issue)
		case "$2" in
			list)
				author=""; jqx=""
				while [ "$#" -gt 0 ]; do case "$1" in --author) author="$2" ;; --jq) jqx="$2" ;; esac; shift; done
				data="$(cat "$API/issues.json" 2>/dev/null || echo '[]')"
				[ -z "$author" ] || data="$(printf '%s' "$data" | jq --arg a "$author" '[.[] | select(.author.login == $a)]')"
				printf '%s' "$data" | jq -r "$jqx" ;;
			create) title=""; while [ "$#" -gt 0 ]; do case "$1" in --title) title="$2" ;; esac; shift; done; echo "$title" >>"$API/created" ;;
		esac ;;
esac
GH
chmod +x "$WORK/bin/gh"
entry() { printf '{"sha":"%s","parents":[{"sha":"x"}]}' "$1"; }
list() { # shas... : newest first
	local out="" sep="" s
	for s in "$@"; do out="$out$sep$(entry "$s")"; sep=","; done
	printf '[%s]' "$out" >"$WORK/api/list.json"
}
runs() { # <sha> <app id> <conclusion>...
	local sha="$1" app="$2" out="" sep="" n=0; shift 2
	for c in "$@"; do out="$out$sep{\"app\":{\"id\":$app},\"conclusion\":\"$c\"}"; sep=","; n=$((n + 1)); done
	printf '{"total_count":%s,"check_runs":[%s]}' "$n" "$out" >"$WORK/api/runs-$sha.json"
}
guard() { printf '[%s]' "$(printf '{"sha":"%s"},' "$@" | sed 's/,$//')" >"$WORK/api/guard.json"; }
good() { rm -f "$WORK"/api/*; list "$A" "$B" "$CUT" "$C"; guard "$CUT"; runs "$A" 15368 success; runs "$B" 15368 success; runs "$CUT" 15368 success; }
run() { # env overrides
	rm -f "$WORK/api/created"
	env PATH="$WORK/bin:$PATH" API="$WORK/api" REPO=Glyndor/homebrew-tap EVENT="${EVENT:-schedule}" GUARD_JOB="$(cat "$WORK/job")" \
		VERIFIED_FROM="${VERIFIED_FROM-}" MAX_PAGES="${MAX_PAGES-5}" \
		bash "$WORK/run.sh" >"$WORK/log" 2>&1
	echo "rc=$?|issues=$(wc -l <"$WORK/api/created" 2>/dev/null || echo 0)" | tr -d ' '
}
good; check "commits that were all judged, down to the cut-off, are accepted" "rc=0|issues=0" "$(run)"
good; check "a commit older than the cut-off is not asked about" "rc=0|issues=0" "$(run)"
good; printf '{"total_count":0,"check_runs":[]}' >"$WORK/api/runs-$CUT.json"
check "the commit that introduced the guard is itself judged, and fails without a run" "rc=1|issues=1" "$(run)"
good; guard "$B" "$CUT"
check "with several commits in the history of the workflow the oldest is the cut-off" "rc=0|issues=0" "$(run)"
good; guard "$CUT" "$B"; printf '{"total_count":0,"check_runs":[]}' >"$WORK/api/runs-$CUT.json"
check "and the newest of them is not: the list is read from its end" "rc=0|issues=0" "$(run)"
good; printf '{"total_count":0,"check_runs":[]}' >"$WORK/api/runs-$B.json"
check "a commit with no run of the guard fails and opens an issue" "rc=1|issues=1" "$(run)"
check "and the title carries its sha" "main commit 2222222 was not judged" "$(cat "$WORK/api/created")"
good; runs "$B" 15368 failure success
check "a commit whose guard failed once and passed after fails: every attempt counts" "rc=1|issues=1" "$(run)"
good; runs "$B" 99 success
check "a run of another app with the name of the guard does not count" "rc=1|issues=1" "$(run)"
good; printf '{"total_count":3,"check_runs":[{"app":{"id":15368},"conclusion":"success"}]}' >"$WORK/api/runs-$B.json"
check "a list of runs that is cut short fails" "rc=1|issues=1" "$(run)"
good; runs "$B" 15368 skipped
check "a run that was skipped does not count" "rc=1|issues=1" "$(run)"
good; printf '{"total_count":0,"check_runs":[]}' >"$WORK/api/runs-$A.json"; cp "$WORK/api/runs-$A.json" "$WORK/api/runs-$B.json"
check "two commits without a run open two issues, one each" "rc=1|issues=2" "$(run)"
good; printf '{"total_count":0,"check_runs":[]}' >"$WORK/api/runs-$B.json"; printf '[{"title":"main commit 2222222 was not judged","author":{"login":"app/github-actions"}}]' >"$WORK/api/issues.json"
check "an issue of the workflow with that title already open is not repeated, and the run still fails" "rc=1|issues=0" "$(run)"
printf '[{"title":"main commit 2222222 was not judged","author":{"login":"someone"}}]' >"$WORK/api/issues.json"
check "an issue with that title opened by somebody else does not silence it" "rc=1|issues=1" "$(run)"
good; printf '{"total_count":0,"check_runs":[]}' >"$WORK/api/runs-$B.json"
check "a run that is not scheduled fails the same and opens no issue" "rc=1|issues=0" "$(EVENT=pull_request run)"
good; touch "$WORK/api/FAIL-list"
check "a list of commits that cannot be read fails" "rc=1|issues=0" "$(run)"
good; printf 'not json' >"$WORK/api/list.json"
check "a list of commits that is not JSON fails" "rc=1|issues=0" "$(run)"
good; printf '[]' >"$WORK/api/list.json"
check "an empty list of commits fails" "rc=1|issues=0" "$(run)"
good; list "$A" "$B" "$C"
check "a short list that does not reach the stop fails: the stop is not known to be behind" "rc=1|issues=0" "$(run)"
hundred() { # <first prefix digit>: a full page of a hundred commits, none of them the stop; their runs all passed
	jq -nc --arg p "$1" '[range(0;100) | {sha: ($p + (. | tostring | ("0000000000000000000000000000000000000000" + .)[-39:])), parents: [{sha: "x"}]}]'
}
good; hundred 5 >"$WORK/api/list.json"; for s in $(jq -r '.[].sha' "$WORK/api/list.json"); do runs "$s" 15368 success; done
check "a full page that does not reach the stop is NOT a success, with one page allowed" "rc=1|issues=0" "$(MAX_PAGES=1 run)"
check "and says that the stop was not reached" "1" "$(grep -c 'was not among them' "$WORK/log")"
check "and what to do about it" "1" "$(grep -c 'VERIFIED_FROM' "$WORK/log")"
good; hundred 5 >"$WORK/api/list.json"; for s in $(jq -r '.[].sha' "$WORK/api/list.json"); do runs "$s" 15368 success; done
list "$A" "$CUT" "$C" >/dev/null; cp "$WORK/api/list.json" "$WORK/api/list-2.json"; hundred 5 >"$WORK/api/list.json"
check "a full page followed by one that holds the stop is read to the end and accepted" "rc=0|issues=0" "$(run)"
good; hundred 5 >"$WORK/api/list.json"; for s in $(jq -r '.[].sha' "$WORK/api/list.json"); do runs "$s" 15368 success; done
list "$A" "$B" "$C" >"$WORK/api/list-2.json"
check "a full page followed by a short one without the stop fails" "rc=1|issues=0" "$(run)"
good; hundred 5 >"$WORK/api/list.json"; for s in $(jq -r '.[].sha' "$WORK/api/list.json"); do runs "$s" 15368 success; done
printf '[{"sha":"%s","parents":[{"sha":"x"}]}]' "$CUT" >"$WORK/api/list-2.json"; first="$(jq -r '.[7].sha' "$WORK/api/list.json")"; printf '{"total_count":0,"check_runs":[]}' >"$WORK/api/runs-$first.json"
check "a commit of the second page that nobody judged is found and reported" "rc=1|issues=1" "$(run)"
good; hundred 5 >"$WORK/api/list.json"; touch "$WORK/api/FAIL-list-2"
check "a second page that cannot be read fails" "rc=1|issues=0" "$(run)"
good; list "$A" "$B" "$C" "$CUT" "$B"
check "a commit recorded in VERIFIED_FROM is the stop, in place of the history of the workflow" "rc=0|issues=0" "$(VERIFIED_FROM="$B" run)"
good; touch "$WORK/api/FAIL-guard"
check "and then the history of the workflow of the guard is not even asked for" "rc=0|issues=0" "$(VERIFIED_FROM="$B" run)"
good; check "a VERIFIED_FROM that is not a hash fails" "rc=1|issues=0" "$(VERIFIED_FROM=main run)"
check "and says that it is not a commit hash, before it reads anything" "1" "$(grep -c 'is .main., not a commit hash' "$WORK/log")"
good; check "a VERIFIED_FROM that is not on main fails: the stop is never reached" "rc=1|issues=0" "$(VERIFIED_FROM=9999999999999999999999999999999999999999 run)"
good; check "a MAX_PAGES that is not a number fails" "rc=1|issues=0" "$(MAX_PAGES=x run)"
good; list "$CUT" "$A"
check "a head that is the cut-off is judged and accepted when its guard passed" "rc=0|issues=0" "$(run)"
good; printf '[]' >"$WORK/api/guard.json"
check "a guard that has not reached main yet, with its file not on main, has nothing to check, and passes" "rc=0|issues=0" "$(run)"
good; printf '[]' >"$WORK/api/guard.json"; printf 'file' >"$WORK/api/contents.json"
check "an empty history while the file of the guard IS on main fails" "rc=1|issues=0" "$(run)"
good; printf '[]' >"$WORK/api/guard.json"; touch "$WORK/api/FAIL-contents"
check "an empty history when whether the file is on main cannot be read fails" "rc=1|issues=0" "$(run)"
good; touch "$WORK/api/FAIL-guard"
check "a history of the workflow of the guard that cannot be read fails" "rc=1|issues=0" "$(run)"
good; printf 'not json' >"$WORK/api/guard.json"
check "a history that is not JSON fails" "rc=1|issues=0" "$(run)"
good; printf '{"message":"Not Found"}' >"$WORK/api/guard.json"
check "an answer that is not a list fails" "rc=1|issues=0" "$(run)"
good; printf '[{"sha":"not-a-sha"}]' >"$WORK/api/guard.json"
check "a cut-off that is not a hash fails" "rc=1|issues=0" "$(run)"
good; jq -nc '[range(0;100) | {sha: "6666666666666666666666666666666666666666"}]' >"$WORK/api/guard.json"
check "a history that fills its page, so the oldest may be on the next, fails" "rc=1|issues=0" "$(run)"
good; printf '[{"sha":"not-a-sha","parents":[{"sha":"x"}]}]' >"$WORK/api/list.json"
check "a commit with an id that is not a hash fails" "rc=1|issues=0" "$(run)"
good; touch "$WORK/api/FAIL-runs-$B"
check "runs that cannot be read fail" "rc=1|issues=0" "$(run)"

echo
echo "passed: $pass  failed: $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
