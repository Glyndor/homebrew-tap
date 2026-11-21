#!/usr/bin/env bash
#
# `brew audit` loads the formulae through a tap Homebrew has to be told to
# trust. A recent Homebrew began refusing otherwise ("Refusing to load formula
# glyndor/tap/podup from untrusted tap") and the scheduled audit went red on
# main with no change to the tap. The audit step must therefore link the
# workspace in as the tap, trust it, and only then audit, in that order: the tap
# does not exist for brew before the link, and an audit before the trust is the
# failure.
#
# The step also refuses to audit nothing. It names every formula under
# Formula/ instead of selecting by tap, so a checkout without formulae would
# hand `brew audit` an empty list and the job would end green having looked at
# no formula. The step is run here against a stub brew, once with an empty
# Formula/ and once with a formula, so the refusal has its acceptance beside it.
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

# Prints "ok" when the audit job's script links, then trusts, then audits.
# Otherwise prints what is wrong.
order() { # $1 = workflow file
	python3 "$HERE/tests/fixtures/publication/audit/audit-obligation.py" "$1" audit
}

# A workflow whose single run block holds the given lines.
plant() { # $1 = file, rest = script lines
	local file="$1"
	shift
	{
		printf 'jobs:\n  audit:\n    steps:\n      - run: |\n'
		for line in "$@"; do
			printf '          %s\n' "$line"
		done
	} > "$file"
}

# A valid sequence in scope must not satisfy the audit job's own contract.
cat > "$WORK/scope-decoy.yml" <<'YAML'
jobs:
  scope:
    steps:
      - run: |
          ln -s "$GITHUB_WORKSPACE" "$tap_dir"
          brew trust glyndor/tap
          brew audit --strict glyndor/tap/podup
  audit:
    needs: scope
    steps:
      - run: brew audit --strict glyndor/tap/podup
YAML
check "scope cannot supply the audit job's missing link and trust" \
	"the audit step has no link or no audit command" "$(order "$WORK/scope-decoy.yml")"

# The controls: each wrong shape is reported, so the live check below can fail.
mkdir -p "$WORK/c"
# shellcheck disable=SC2016 # the text is written into a script, not expanded here
LINK='ln -s "$GITHUB_WORKSPACE" "$tap_dir"'
AUDIT='brew audit --strict glyndor/tap/podup'

plant "$WORK/c/none.yml" "$LINK" "$AUDIT"
check "an audit that never trusts the tap is reported" \
	"the audit step never trusts the tap" "$(order "$WORK/c/none.yml")"

plant "$WORK/c/late.yml" "$LINK" "$AUDIT" "brew trust glyndor/tap"
check "a trust after the audit is reported" \
	"the order is not link, trust, audit" "$(order "$WORK/c/late.yml")"

plant "$WORK/c/early.yml" "brew trust glyndor/tap" "$LINK" "$AUDIT"
check "a trust before the link is reported" \
	"the order is not link, trust, audit" "$(order "$WORK/c/early.yml")"

plant "$WORK/c/commented.yml" "$LINK" "# brew trust glyndor/tap" "$AUDIT"
check "a commented-out trust does not count" \
	"the audit step never trusts the tap" "$(order "$WORK/c/commented.yml")"

plant "$WORK/c/good.yml" "$LINK" "brew trust glyndor/tap" "$AUDIT"
check "the right order passes" "ok" "$(order "$WORK/c/good.yml")"

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

check "the live audit workflow links, trusts, then audits" "ok" \
	"$(order "$HERE/.github/workflows/audit.yml")"

# --- the step refuses to audit an empty set -----------------------------------
#
# The live step, taken out of the workflow and run against a stub brew that
# records what it was asked to do. The stub answers `--repository` with a
# directory of its own, so the step links the workspace in there and nothing
# outside $WORK is touched.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/brew" <<'STUB'
#!/bin/sh
if [ "$1" = "--repository" ]; then
	printf '%s\n' "$BREW_STUB_HOME"
	exit 0
fi
printf '%s\n' "$*" >> "$BREW_STUB_LOG"
STUB
chmod +x "$WORK/bin/brew"

python3 - "$HERE/.github/workflows/audit.yml" "$WORK/audit-step.sh" <<'PYCASE'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]["audit"]["steps"]
steps = [step["run"] for step in jobs if "brew audit --strict" in step.get("run", "")]
assert len(steps) == 1, "expected one step that runs brew audit"
open(sys.argv[2], "w").write(steps[0])
PYCASE

# audit_with <name> <formula>...: a workspace holding those formulae, the step run
# in it; $rc, $out and the recorded brew calls come back in $WORK/<name>.calls.
audit_with() {
	local name="$1"; shift
	local ws="$WORK/$name"
	mkdir -p "$ws/Formula" "$WORK/$name.home"
	local formula
	for formula in "$@"; do : > "$ws/Formula/$formula.rb"; done
	: > "$WORK/$name.calls"
	rc=0
	out="$( cd "$ws" && PATH="$WORK/bin:$PATH" GITHUB_WORKSPACE="$ws" \
		BREW_STUB_HOME="$WORK/$name.home" BREW_STUB_LOG="$WORK/$name.calls" \
		bash "$WORK/audit-step.sh" 2>&1 )" || rc=$?
}

audit_with empty
check "a checkout with no formulae fails the audit step" "1" "$rc"
check "and the error says the tap is empty or the checkout is wrong" "1" \
	"$(grep -c 'no formulae found under Formula/; the tap is empty or the checkout is wrong' <<<"$out")"
check "and brew is never asked to audit" "0" "$(grep -c '^audit ' "$WORK/empty.calls")"

audit_with one podup
check "a checkout with one formula passes the audit step" "0" "$rc"
check "and brew is asked to audit that formula by name, not the tap" "audit --strict glyndor/tap/podup" \
	"$(grep '^audit ' "$WORK/one.calls")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
