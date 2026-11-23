#!/usr/bin/env bash
#
# The `suites` mode of scripts/quality/scope/ci-job-scope.sh decides which suites a
# pull request can affect. A wrong skip lets a change merge untested, so most of
# the cases here plant a way to slip through and require every suite to run, and
# the few that require a skip only mean something because those prove the
# resolver can tell. Every repository below is real git: a base commit, a
# branch, and the merge commit GitHub would build (HEAD with two parents).
#
# The last cases use the map this repository really ships, so the map itself is
# under test and not only the resolver: a README-only pull request has to run
# the suites that read the README and none of the others.
#
# One section gives the runner its own protections to prove, with real merge
# commits and a count of the suites it ran.
#
# Requires: bash, git, python3.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RESOLVER="$HERE/scripts/quality/scope/ci-job-scope.sh"
SCOPE_MAP="$HERE/scripts/quality/scope/suite-scope.txt"
WORKFLOW="$HERE/.github/workflows/tests.yml"
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

SUITES="tests/a/one.test.sh tests/b/two.test.sh tests/c/three.test.sh"
MAP=$'tests/a/one.test.sh\n\tscripts/a/**\n\ttests/a/**\n\ntests/b/two.test.sh\n\tscripts/b/**\n\tREADME.md\n\ttests/b/two.test.sh\n'
# Note: tests/c/three.test.sh has no entry, so it must always run.

# repo <name>: a base commit with the map and the resolver, and the checkout on
# a branch ready to take the pull request's changes.
repo() {
	R="$WORK/$1"; rm -rf "$R"; mkdir -p "$R/scripts/quality/scope" "$R/scripts/a" "$R/scripts/b" "$R/tests/a" "$R/tests/b" "$R/tests/c" "$R/tests/ci/suites"
	git -C "$R" init -q -b main
	git -C "$R" config user.name t; git -C "$R" config user.email t@example.invalid; git -C "$R" config commit.gpgsign false
	cp "$RESOLVER" "$R/scripts/quality/scope/ci-job-scope.sh"
	printf '%s' "$MAP" > "$R/scripts/quality/scope/suite-scope.txt"
	printf 'runner\n' > "$R/tests/ci/suites/check-suite-completeness.test.sh"
	printf 'x\n' > "$R/scripts/a/x.sh"; printf 'x\n' > "$R/scripts/b/y.sh"; printf 'readme\n' > "$R/README.md"
	printf 'docs\n' > "$R/DOCS.md"; printf 'x\n' > "$R/tests/a/one.test.sh"; printf 'x\n' > "$R/tests/b/two.test.sh"; printf 'x\n' > "$R/tests/c/three.test.sh"
	git -C "$R" add -A; git -C "$R" commit -qm base
	git -C "$R" checkout -q -b pr
}
# base_map <content>: change the map in the BASE (main), not in the pull
# request, and branch the pull request from there. "-" removes the map.
base_map() {
	git -C "$R" checkout -q main
	if [ "$1" = "-" ]; then git -C "$R" rm -q scripts/quality/scope/suite-scope.txt
	else printf '%s' "$1" > "$R/scripts/quality/scope/suite-scope.txt"; fi
	git -C "$R" add -A; git -C "$R" commit -qm "base map"
	git -C "$R" branch -D pr -q; git -C "$R" checkout -q -b pr
}
# merge: commit the pending changes on the branch and build the merge commit.
merge() {
	git -C "$R" add -A; git -C "$R" commit -qm change
	git -C "$R" checkout -q main
	git -C "$R" merge -q --no-ff pr -m merge
}
# decide [<path-prefix>]: the suites kept out of $SUITES, space-separated, in
# the order given. $SUITES is a list of plain words, so it is expanded unquoted
# on purpose. The optional prefix goes in front of PATH, so a case can run the
# resolver with a git of its own.
decide() {
	# shellcheck disable=SC2086
	( cd "$R" && PATH="${1:+$1:}$PATH" bash scripts/quality/scope/ci-job-scope.sh suites $SUITES 2>/dev/null | tr '\n' ' ' | sed 's/ $//' )
}
# sabotage <file> <old> <new>: replace one piece of a file and stop loudly if
# it is not there exactly once, so a case cannot pass because the sabotage did
# not land. It is the control of the cases below: the case says what the
# resolver does, and the sabotage says what it does without the protection.
sabotage() {
	python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("the sabotage target is not there exactly once: %r" % (old,))
open(path, "w", encoding="utf-8").write(text.replace(old, new))
PY
}

ALL="$SUITES"

# A suite whose entry does not list its own file still runs when only that file
# changes (issue #370). The control is the resolver without the condition.
SELF_MAP=$'tests/d/four.test.sh\n\tscripts/d/**\n'
repo self
git -C "$R" checkout -q main; mkdir -p "$R/tests/d"; printf 'x\n' > "$R/tests/d/four.test.sh"
git -C "$R" add -A; git -C "$R" commit -qm "the suite"
base_map "$SELF_MAP"
echo more >> "$R/tests/d/four.test.sh"; merge
SUITES="tests/d/four.test.sh"
check "a suite whose entry omits its own file still runs when only it changes" \
	"tests/d/four.test.sh" "$(decide)"
sed 's/if candidate in paths or affects/if affects/' "$RESOLVER" > "$WORK/resolver-cut.sh"
check "the sabotage changed the resolver" "1" "$(cmp -s "$RESOLVER" "$WORK/resolver-cut.sh" && echo 0 || echo 1)"
cp "$WORK/resolver-cut.sh" "$R/scripts/quality/scope/ci-job-scope.sh"
check "without the condition that suite is skipped (the run is the condition's)" \
	"" "$(decide)"
SUITES="tests/a/one.test.sh tests/b/two.test.sh tests/c/three.test.sh"

# --- a pull request that changes nothing any suite reads ---------------------

repo docs; echo more >> "$R/DOCS.md"; merge
check "a change no entry covers skips every mapped suite, and the unmapped one still runs" \
	"tests/c/three.test.sh" "$(decide)"

repo area; echo more >> "$R/scripts/a/x.sh"; merge
check "a change under one area runs that area's suite and the unmapped one" \
	"tests/a/one.test.sh tests/c/three.test.sh" "$(decide)"

repo exact; echo more >> "$R/README.md"; merge
check "an exact file entry matches that file" \
	"tests/b/two.test.sh tests/c/three.test.sh" "$(decide)"

repo dots; echo more >> "$R/scripts/ax.sh"; mkdir -p "$R/scripts/ab"; echo y > "$R/scripts/ab/z.sh"; merge
check "a sibling directory whose name only starts like the area does not match it" \
	"tests/c/three.test.sh" "$(decide)"

repo space; mkdir -p "$R/scripts/a/sub dir"; echo y > "$R/scripts/a/sub dir/a b.sh"; merge
check "a path with spaces under ** is matched" \
	"tests/a/one.test.sh tests/c/three.test.sh" "$(decide)"

repo spelling; echo more >> "$R/scripts/a/x.sh"; merge
check "the workflow's ./ spelling is normalised" \
	"tests/a/one.test.sh tests/c/three.test.sh" "$( ( cd "$R" && bash scripts/quality/scope/ci-job-scope.sh suites ./tests/a/one.test.sh ./tests/b/two.test.sh ./tests/c/three.test.sh | tr '\n' ' ' | sed 's/ $//' ) )"

# --- the things a pull request must not be able to do to its own scope ---------

repo map; printf 'tests/a/one.test.sh\n\tnothing/**\n' > "$R/scripts/quality/scope/suite-scope.txt"; merge
check "a pull request that rewrites the map runs every suite" "$ALL" "$(decide)"

repo resolver; echo '# edited' >> "$R/scripts/quality/scope/ci-job-scope.sh"; merge
check "a pull request that edits the resolver runs every suite" "$ALL" "$(decide)"

repo runner; echo more >> "$R/tests/ci/suites/check-suite-completeness.test.sh"; merge
check "a pull request that edits the runner runs every suite" "$ALL" "$(decide)"

repo workflow; mkdir -p "$R/.github/workflows"; echo 'name: x' > "$R/.github/workflows/called.yml"; merge
check "a pull request that adds a workflow runs every suite" "$ALL" "$(decide)"
repo action; mkdir -p "$R/.github/actions/setup"; echo 'name: x' > "$R/.github/actions/setup/action.yml"; merge
check "a pull request that adds an action runs every suite" "$ALL" "$(decide)"

# --- the decision fails open -----------------------------------------------------

repo rename; git -C "$R" mv scripts/b/y.sh scripts/b/renamed.sh; merge
check "a rename runs every suite" "$ALL" "$(decide)"

repo delete; git -C "$R" rm -q scripts/b/y.sh; merge
check "a deleted file counts as a change to its area" \
	"tests/b/two.test.sh tests/c/three.test.sh" "$(decide)"
# (scripts/b/** is in the entry of tests/b/two.test.sh)

repo ff; echo more >> "$R/scripts/a/x.sh"; git -C "$R" add -A; git -C "$R" commit -qm change
check "a checkout that is not the merge commit runs every suite" "$ALL" "$(decide)"

repo empty; git -C "$R" commit -q --allow-empty -m empty; git -C "$R" checkout -q main; git -C "$R" merge -q --no-ff pr -m merge
check "an empty diff runs every suite" "$ALL" "$(decide)"

repo nomap; base_map -; echo more >> "$R/DOCS.md"; merge
check "a base commit without the map runs every suite" "$ALL" "$(decide)"

# The pull request that moves the map into its folder: the base carries it at
# the path it had before, so the map is not where the resolver looks in the
# base. Reading the pull request's own copy there would let it choose its scope,
# and the one it brings says every suite can be skipped. Its text shares nothing
# with the old one, so git sees a deletion and an addition and not a rename,
# which would run everything for a different reason.
repo moved
git -C "$R" checkout -q main
git -C "$R" mv scripts/quality/scope/suite-scope.txt scripts/quality/suite-scope.txt
git -C "$R" commit -qm "the map before it moved"
git -C "$R" branch -D pr -q; git -C "$R" checkout -q -b pr
git -C "$R" rm -q scripts/quality/suite-scope.txt
printf 'tests/a/one.test.sh\n\tnothing/**\ntests/b/two.test.sh\n\tnothing/**\ntests/c/three.test.sh\n\tnothing/**\n' > "$R/scripts/quality/scope/suite-scope.txt"
echo more >> "$R/DOCS.md"; merge
check "a base that holds the map at the path it had before the move runs every suite" "$ALL" "$(decide)"

repo badmap; base_map $'tests/a/one.test.sh\n'; echo more >> "$R/DOCS.md"; merge
check "a map entry with no pattern runs every suite" "$ALL" "$(decide)"

repo dup; base_map $'tests/a/one.test.sh\n\tscripts/a/**\ntests/a/one.test.sh\n\tscripts/a/**\n'; echo more >> "$R/DOCS.md"; merge
check "a suite listed twice in the map runs every suite" "$ALL" "$(decide)"

repo orphan; base_map $'\tscripts/a/**\ntests/a/one.test.sh\n\tscripts/a/**\n'; echo more >> "$R/DOCS.md"; merge
check "a pattern before any suite runs every suite" "$ALL" "$(decide)"

# A rename record is three fields, so two renames in the same pull request
# make the field count even and the parity check cannot notice them. The
# status of the record is what says "this is a rename": without it the second
# rename is read as a change of the first one, the path it came from is lost,
# and the suite that reads that path is skipped.
repo tworenames
git -C "$R" mv scripts/a/x.sh scripts/a/renamed.sh
git -C "$R" mv scripts/b/y.sh scripts/copy.sh
merge
check "a pull request with two renames runs every suite" "$ALL" "$(decide)"
sabotage "$R/scripts/quality/scope/ci-job-scope.sh" \
	$'if status not in {b"A", b"M", b"D"} or not path_bytes:\n            return None' \
	$'if False:\n            return None'
check "without the rename status the suite of the second rename is skipped" \
	"tests/a/one.test.sh tests/c/three.test.sh" "$(decide)"

# A git that cannot read the diff cannot establish the scope, and the
# resolver says so by running every suite. That fallback is the last line of
# defence, so it has to name every suite the caller asked for and not only
# the first one.
repo brokendiff; echo more >> "$R/DOCS.md"; merge
mkdir -p "$R/fakebin"
# shellcheck disable=SC2016 # the fake git reads these variables when it runs
printf '#!/usr/bin/env bash\n[ "$1" = diff ] && exit 42\nexec %s "$@"\n' "$(command -v git)" > "$R/fakebin/git"
chmod +x "$R/fakebin/git"
check "a git that fails the diff runs every suite" "$ALL" "$(decide "$R/fakebin")"
sabotage "$R/scripts/quality/scope/ci-job-scope.sh" 'for name in sys.argv[2:]:' 'for name in sys.argv[2:3]:'
check "without the whole list in the fallback only the first suite would run" \
	"tests/a/one.test.sh" "$(decide "$R/fakebin")"

# --- the runner's own protections ------------------------------------------------
#
# The runner is the one piece of this mechanism a pull request can rewrite, so
# it carries three protections of its own: it scopes only on a pull request,
# it refuses to scope when the file it is running is not the copy in the base
# commit, and it takes the resolver from the base commit. The cases below give
# it a real merge commit and count the suites it ran and the ones it skipped.

RUNNER="$HERE/tests/ci/suites/check-suite-completeness.test.sh"
RUN_ARGS=""
for s in $SUITES; do RUN_ARGS="$RUN_ARGS ./$s"; done

# runner_repo <name> [<base-resolver>|none]: a repository with the runner this
# repository ships, a resolver, the map and three suites that report a
# sentinel, so what the runner decided is visible in what it printed.
runner_repo() {
	R="$WORK/$1"; rm -rf "$R"
	mkdir -p "$R/scripts/quality/scope" "$R/scripts/a" "$R/scripts/b" "$R/tests/ci/suites" "$R/tests/a" "$R/tests/b" "$R/tests/c"
	git -C "$R" init -q -b main
	git -C "$R" config user.name t; git -C "$R" config user.email t@e.invalid; git -C "$R" config commit.gpgsign false
	base_resolver="${2:-$RESOLVER}"
	case "$base_resolver" in
		none) ;;
		*) cp "$base_resolver" "$R/scripts/quality/scope/ci-job-scope.sh" ;;
	esac
	cp "$RUNNER" "$R/tests/ci/suites/check-suite-completeness.test.sh"
	printf '%s' "$MAP" > "$R/scripts/quality/scope/suite-scope.txt"
	for s in $SUITES; do
		# shellcheck disable=SC2016 # the stand-in suite reads this variable when it runs
		printf '#!/usr/bin/env bash\nprintf "DONE %%s 0 0\\n" "${BASH_SOURCE[0]##*/}"\n' > "$R/$s"
		chmod +x "$R/$s"
	done
	printf 'x\n' > "$R/scripts/a/x.sh"; printf 'y\n' > "$R/scripts/b/y.sh"
	printf 'readme\n' > "$R/README.md"; printf 'docs\n' > "$R/DOCS.md"
	git -C "$R" add -A; git -C "$R" commit -qm base
	git -C "$R" checkout -q -b pr
}
# runner_run <event>: how many suites the runner ran and how many it skipped.
runner_run() {
	# shellcheck disable=SC2086
	out="$( cd "$R" && GITHUB_EVENT_NAME="$1" bash tests/ci/suites/check-suite-completeness.test.sh $RUN_ARGS 2>&1 )"
	printf '%s %s' "$(grep -c 'reached its end' <<< "$out")" "$(grep -c '^skip  ' <<< "$out")"
}

# A push is not a pull request, so the runner does not scope at all. The merge
# commit in the checkout is what the resolver would read, and the runner must
# not let it narrow the run.
runner_repo push; echo more >> "$R/DOCS.md"; merge
check "a push runs every suite even when the checkout is a merge commit" \
	"3 0" "$(runner_run push)"

# The runner compares itself with the copy in the base commit and refuses to
# scope when the two differ. The resolver of the base here does not treat the
# runner as one of its global inputs, so the runner's own comparison is the
# only thing that can stop the narrowing.
grep -v -F '    "tests/ci/suites/check-suite-completeness.test.sh",' "$RESOLVER" > "$WORK/resolver-without-runner"
runner_repo selfguard "$WORK/resolver-without-runner"
echo '# edit' >> "$R/tests/ci/suites/check-suite-completeness.test.sh"; merge
check "a pull request that edits the runner runs every suite" "3 0" "$(runner_run pull_request)"

# The resolver is taken from the base commit. When the base has none, the
# scope cannot be established and every suite runs.
runner_repo baseresolver none
printf '#!/usr/bin/env bash\necho tests/c/three.test.sh\n' > "$R/scripts/quality/scope/ci-job-scope.sh"
echo more >> "$R/DOCS.md"; merge
check "a pull request that adds the resolver runs every suite" "3 0" "$(runner_run pull_request)"

# --- the map this repository ships ------------------------------------------------
#
# The resolver is only as good as the map, so the map is under test too. The
# suite list comes from the workflow, the map from the tree, and the verdict
# has to name exactly the suites that read the changed file.

REAL_SUITES="$(python3 - "$WORKFLOW" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for job in wf["jobs"].values():
    command = str(job.get("with", {}).get("test-command", ""))
    for token in command.split():
        if token.endswith(".test.sh"):
            print(token[2:] if token.startswith("./") else token)
PY
)"
check "the workflow names a suite list" "1" "$([ -n "$REAL_SUITES" ] && echo 1 || echo 0)"

# Every suite the workflow names has an entry, so a new suite does not sit in
# the map's blind spot: an entry with no pattern is refused, and an absent
# entry would leave the suite always running.
missing=""
while IFS= read -r suite; do
	[ -n "$suite" ] || continue
	grep -qxF -- "$suite" "$SCOPE_MAP" || missing="$missing $suite"
done <<< "$REAL_SUITES"
check "every suite the workflow names has an entry in the map" "" "$missing"

# A suite that only a job of its own runs, such as the ML-DSA-65 verifier, is in
# no test-command, so the check above cannot see it. That job decides whether to
# run from the map, and a suite with no entry always runs, which is safe but means
# the map no longer says what it was written to say. So every suite a step hands
# to the runner has an entry too, and the check is shown to fail on a planted
# workflow and map.
unmapped_job_suites() { # <workflow> <map>: the suites a step hands to the runner that the map lacks
	python3 -I - "$1" "$2" <<'PY'
import re
import sys
import yaml

wf = yaml.safe_load(open(sys.argv[1]))
mapped = {line.strip() for line in open(sys.argv[2]) if line.strip() and not line[0].isspace() and line[0] != "#"}
handed = []
for job in wf["jobs"].values():
    for step in job.get("steps") or []:
        for hit in re.finditer(r"check-suite-completeness\.test\.sh((?:[ \t]+\./tests/[A-Za-z0-9_./-]+\.test\.sh)+)",
                               str(step.get("run", ""))):
            handed += [token[2:] for token in hit.group(1).split()]
print("handed %d" % len(handed))
for suite in handed:
    if suite not in mapped:
        print(suite)
PY
}
real="$(unmapped_job_suites "$WORKFLOW" "$SCOPE_MAP")"
check "a suite a job of its own runs is found in the workflow" "1" "$(printf '%s' "$real" | grep -c '^handed [1-9]')"
check "and every one of them has an entry in the map" "" "$(printf '%s\n' "$real" | grep -v '^handed ')"
printf 'jobs:\n  j:\n    steps:\n      - run: ./tests/ci/suites/check-suite-completeness.test.sh ./tests/x/alone.test.sh\n' > "$WORK/job-workflow.yml"
printf 'tests/x/other.test.sh\n\tscripts/**\n' > "$WORK/job-map.txt"
check "planted: a suite a job runs that the map lacks is reported" "tests/x/alone.test.sh" \
	"$(unmapped_job_suites "$WORK/job-workflow.yml" "$WORK/job-map.txt" | grep -v '^handed ')"

# real_repo <name>: a repository carrying the resolver and the map this
# repository ships, so the decision is taken with the real map.
real_repo() {
	R="$WORK/$1"; rm -rf "$R"; mkdir -p "$R/scripts/quality/scope" "$R/scripts/release" "$R/docs" "$R/tests/fixtures/monitoring"
	git -C "$R" init -q -b main
	git -C "$R" config user.name t; git -C "$R" config user.email t@example.invalid; git -C "$R" config commit.gpgsign false
	cp "$RESOLVER" "$R/scripts/quality/scope/ci-job-scope.sh"
	cp "$SCOPE_MAP" "$R/scripts/quality/scope/suite-scope.txt"
	printf 'readme\n' > "$R/README.md"; printf 'contributing\n' > "$R/CONTRIBUTING.md"
	printf 'fixture\n' > "$R/tests/fixtures/monitoring/order.txt"
	printf 'docs\n' > "$R/docs/threat-model.md"; printf 'x\n' > "$R/scripts/release/render-formulae.sh"
	git -C "$R" add -A; git -C "$R" commit -qm base
	git -C "$R" checkout -q -b pr
}
# real_decide: the suites the resolver keeps, one per line.
real_decide() {
	# shellcheck disable=SC2086
	( cd "$R" && bash scripts/quality/scope/ci-job-scope.sh suites $REAL_SUITES 2>/dev/null )
}
# has: 1 when the suite is among the ones the decision kept.
#
# The decision is read with a here-string rather than a pipeline, and that is
# not a style choice. `grep -q` stops at the first match and closes the pipe,
# so the writer on the left dies of SIGPIPE; with `pipefail` on, the pipeline
# then reports 141 even though grep DID match, and this helper answers "the
# suite is not among them" about a suite that is. Measured on this machine: 48
# misses in 20000 calls, and it is worse on a loaded one. The here-string has
# no pipeline and no writer to kill, so the answer is grep's alone.
has() { # <suite> <decision>
	if grep -qxF -- "$1" <<< "$2"; then echo 1; else echo 0; fi
}
# lacks: 1 when the suite is not among them.
lacks() { # <suite> <decision>
	if grep -qxF -- "$1" <<< "$2"; then echo 0; else echo 1; fi
}
# suites_for <pattern>: the suites the map binds to that pattern. The map is
# the list of who reads what, so the cases below ask it and not the workflow.
suites_for() {
	python3 - "$SCOPE_MAP" "$1" <<'PY'
import sys
path, want = sys.argv[1:3]
suite = None
for line in open(path, encoding="utf-8"):
    line = line.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    if line[:1].isspace():
        if line.strip() == want:
            print(suite)
        continue
    suite = line.strip()
PY
}
# candidate: 1 when the suite is among the ones the workflow names.
candidate() { # <suite>
	if grep -qxF -- "$1" <<< "$REAL_SUITES"; then echo 1; else echo 0; fi
}

real_repo readme; echo more >> "$R/README.md"; merge
got="$(real_decide)"
check "a README-only change runs the suite that reads the README" "1" \
	"$(has tests/governance/check-issue-templates.test.sh "$got")"
check "a README-only change runs the doc-anchor suite" "1" \
	"$(has tests/quality/hygiene/check-doc-anchors.test.sh "$got")"
check "a README-only change does not run the suite that reads CONTRIBUTING" "1" \
	"$(lacks tests/ci/docs/documented-test-command.test.sh "$got")"
check "a README-only change does not run a suite that reads neither" "1" \
	"$(lacks tests/quality/lint/check-action-pins.test.sh "$got")"

real_repo contributing; echo more >> "$R/CONTRIBUTING.md"; merge
got="$(real_decide)"
check "a CONTRIBUTING-only change runs the documented-command suite" "1" \
	"$(has tests/ci/docs/documented-test-command.test.sh "$got")"
check "a CONTRIBUTING-only change runs the doc-anchor suite" "1" \
	"$(has tests/quality/hygiene/check-doc-anchors.test.sh "$got")"
check "a CONTRIBUTING-only change does not run the suite that reads the README" "1" \
	"$(lacks tests/governance/check-issue-templates.test.sh "$got")"

real_repo script; echo more >> "$R/scripts/release/render-formulae.sh"; merge
got="$(real_decide)"
check "a change to the renderer runs the renderer suites" "1" \
	"$(has tests/release/render-formulae.test.sh "$got")"
check "and the suites that read every script" "1" \
	"$(has tests/quality/hygiene/check-doc-anchors.test.sh "$got")"
check "and none of the suites that read neither" "1" \
	"$(lacks tests/ci/docs/documented-test-command.test.sh "$got")"

# A suite that reads a fixture cannot conclude anything new when the fixture
# changes, so the map has to bind the fixture to every suite that reads it.
# The list of those suites is written here and not read from the map: a map
# that stops binding the fixture to one of them is exactly what this case has
# to catch, and a list read from the map would shrink with it.
FIXTURE_SUITES="tests/monitoring/check-render-drift.test.sh
tests/monitoring/check-render-drift/check-render-drift-drift.test.sh
tests/monitoring/check-render-drift/check-render-drift-missing.test.sh
tests/monitoring/check-render-drift/check-render-drift-network.test.sh
tests/monitoring/check-render-drift/check-render-drift-digest-case.test.sh
tests/monitoring/check-render-drift/check-render-drift-version.test.sh"
# shellcheck disable=SC2086 # the list is words, and it has to be split into them
check "the map binds the monitoring fixture to the suites that read it" \
	"$(printf '%s\n' $FIXTURE_SUITES | sort | tr '\n' ' ')" \
	"$(suites_for 'tests/fixtures/monitoring/**' | sort | tr '\n' ' ')"
notnamed=""
for suite in $FIXTURE_SUITES; do
	[ "$(candidate "$suite")" = 1 ] || notnamed="$notnamed $suite"
done
check "every suite that reads the monitoring fixture is one the workflow names" \
	"" "$notnamed"
real_repo fixture; echo more >> "$R/tests/fixtures/monitoring/order.txt"; merge
got="$(real_decide)"
for suite in $FIXTURE_SUITES; do
	[ "$(candidate "$suite")" = 1 ] || continue
	check "a change in the monitoring fixture runs $suite" "1" "$(has "$suite" "$got")"
done

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
