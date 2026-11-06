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
	python3 "$HERE/tests/fixtures/ci/audit-obligation.py" "$1" audit
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

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
