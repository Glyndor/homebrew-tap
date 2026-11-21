#!/usr/bin/env bash
#
# The commit update.yml makes is the published artifact: once it lands on main
# `brew audit --strict` therefore has to run before that commit, after the
# workspace is linked in as the tap and the tap is trusted. An audit that only
# runs after the push (audit.yml) judges a formula that is already public.
#
# The audit runs in the `validate` job and the commit in the `commit` job,
# which is the only one that holds the updater app's key. "Before" then means
# that the commit job needs the validation job and carries no condition that
# would run it after a failed one.
#
# Requires: python3 with PyYAML (tests.yml installs python3-yaml).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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

# Prints "ok" when one step links, trusts and audits in that order, and the
# commit is made either by a later step of the same job or by a job that needs
# the audit's job. Otherwise prints what is wrong.
order() { # $1 = workflow file
	python3 "$HERE/tests/fixtures/publication/audit/audit-obligation.py" "$1" update
}

# A `validate` job with the audit step, and a `commit` job that needs it.
plant() { # $1 = file, $2 = audit-step lines (newline separated), $3 = commit step line, $4 = commit job extra line
	{
		printf 'jobs:\n  validate:\n    steps:\n'
		printf '      - run: |\n'
		printf '%s\n' "$2" | sed 's/^/          /'
		printf '  commit:\n'
		printf '    %s\n' "${4:-needs: [validate]}"
		printf '    steps:\n'
		printf '      - run: |\n          %s\n' "$3"
	} > "$1"
}

mkdir -p "$WORK/c"
# shellcheck disable=SC2016 # the text is written into a script, not expanded here
LINK='ln -s "$GITHUB_WORKSPACE" "$tap_dir"'
TRUST='brew trust glyndor/tap'
AUDIT='brew audit --strict glyndor/tap/podup'
COMMIT='gh api graphql -f query=createCommitOnBranch'

plant "$WORK/c/good.yml" "$(printf '%s\n%s\n%s' "$LINK" "$TRUST" "$AUDIT")" "$COMMIT"
check "link, trust, audit and then the commit passes" "ok" "$(order "$WORK/c/good.yml")"

plant "$WORK/c/noaudit.yml" "$(printf '%s\n%s' "$LINK" "$TRUST")" "$COMMIT"
check "a job with no audit is reported" "no step runs brew audit" "$(order "$WORK/c/noaudit.yml")"

plant "$WORK/c/after.yml" "echo nothing" "$COMMIT"
{
	cat "$WORK/c/after.yml"
	printf '      - run: |\n          %s\n          %s\n          %s\n' "$LINK" "$TRUST" "$AUDIT"
} > "$WORK/c/after2.yml"
check "an audit placed after the commit, in the commit job, is reported" \
	"the audit does not run before the commit" "$(order "$WORK/c/after2.yml")"

plant "$WORK/c/unneeded.yml" "$(printf '%s\n%s\n%s' "$LINK" "$TRUST" "$AUDIT")" "$COMMIT" "runs-on: ubuntu-latest"
check "a commit job that does not need the audit job is reported" \
	"the commit job does not need the audit job" "$(order "$WORK/c/unneeded.yml")"

for condition in 'always()' '!cancelled()' 'failure() || success()'; do
	# shellcheck disable=SC2016 # the ${{ }} is Actions syntax written into the plant
	{
		printf 'jobs:\n  validate:\n    steps:\n      - run: |\n'
		printf '%s\n%s\n%s\n' "$LINK" "$TRUST" "$AUDIT" | sed 's/^/          /'
		printf '  commit:\n    needs: [validate]\n    if: ${{ %s }}\n    steps:\n      - run: |\n          %s\n' "$condition" "$COMMIT"
	} > "$WORK/c/status.yml"
	check "a commit job with if: $condition is reported" \
		"the commit job runs whatever the audit concluded" "$(order "$WORK/c/status.yml")"
done

# The shape this workflow had before the split, one job with the audit step
# before the commit step, is still read correctly, so the failures above are
# about the jobs and not about the parser.
{
	printf 'jobs:\n  update:\n    steps:\n      - run: |\n'
	printf '%s\n%s\n%s\n' "$LINK" "$TRUST" "$AUDIT" | sed 's/^/          /'
	printf '      - run: |\n          %s\n' "$COMMIT"
} > "$WORK/c/onejob.yml"
check "one job that audits and then commits still reads as ordered" "ok" "$(order "$WORK/c/onejob.yml")"

plant "$WORK/c/lax.yml" "$(printf '%s\n%s\n%s' "$LINK" "$TRUST" 'brew audit glyndor/tap/podup')" "$COMMIT"
check "an audit that is not strict is reported" "the audit is not strict" "$(order "$WORK/c/lax.yml")"

plant "$WORK/c/late.yml" "$(printf '%s\n%s\n%s' "$LINK" "$AUDIT" "$TRUST")" "$COMMIT"
check "a trust after the audit is reported" "the order is not link, trust, audit" "$(order "$WORK/c/late.yml")"

plant "$WORK/c/commented.yml" "$(printf '%s\n%s\n%s' "$LINK" "$TRUST" '# brew audit --strict x')" "$COMMIT"
check "a commented-out audit does not count" "no step runs brew audit" "$(order "$WORK/c/commented.yml")"

# Mutate an otherwise valid workflow; each bypass must be rejected on its own.
python3 - "$WORK/c/good.yml" "$WORK/c" <<'PYCASE'
import copy, pathlib, sys, yaml
good = yaml.safe_load(open(sys.argv[1]))
for mutation in ("exit", "if", "if-true", "step-error", "job-error", "swallowed"):
    doc = copy.deepcopy(good)
    job = next(iter(doc["jobs"].values()))
    step = job["steps"][0]
    if mutation == "exit":
        step["run"] = "exit 0\n" + step["run"]
    elif mutation == "if":
        step["if"] = False
    elif mutation == "if-true":
        step["if"] = "${{ always() }}"
    elif mutation == "swallowed":
        step["run"] = step["run"].replace("brew audit --strict glyndor/tap/podup", "brew audit --strict glyndor/tap/podup || true")
    elif mutation == "step-error":
        step["continue-on-error"] = True
    else:
        job["continue-on-error"] = True
    pathlib.Path(sys.argv[2], mutation + ".yml").write_text(yaml.safe_dump(doc))
PYCASE
for mutation in exit if if-true step-error job-error swallowed; do
	case "$mutation" in
		exit) expected="the audit is not reached" ;;
		if|if-true) expected="the audit step is conditional" ;;
		step-error) expected="the audit step ignores failure" ;;
		job-error) expected="the audit job ignores failure" ;;
		swallowed) expected="the audit failure is swallowed" ;;
	esac
	check "$mutation cannot bypass the audit" "$expected" "$(order "$WORK/c/$mutation.yml")"
done

check "the live update workflow audits strictly before it commits" "ok" \
	"$(order "$HERE/.github/workflows/update.yml")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
