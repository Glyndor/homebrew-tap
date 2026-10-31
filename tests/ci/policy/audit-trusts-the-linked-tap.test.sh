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
	python3 - "$1" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
script = "\n".join(s.get("run", "") for s in doc["jobs"]["audit"]["steps"])
lines = [l.strip() for l in script.splitlines() if l.strip() and not l.strip().startswith("#")]
def first(prefix):
    for i, l in enumerate(lines):
        if l.startswith(prefix):
            return i
    return None
link, trust, audit = first("ln -s"), first("brew trust glyndor/tap"), first("brew audit")
if None in (link, audit):
    print("the audit step has no link or no audit command")
elif trust is None:
    print("the audit step never trusts the tap")
elif not link < trust < audit:
    print("the order is not link, trust, audit")
else:
    print("ok")
PY
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

check "the live audit workflow links, trusts, then audits" "ok" \
	"$(order "$HERE/.github/workflows/audit.yml")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
