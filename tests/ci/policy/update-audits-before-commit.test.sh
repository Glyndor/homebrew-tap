#!/usr/bin/env bash
#
# The commit update.yml makes is the published artifact: once it lands on main
# `brew install` can read it. `brew audit --strict` therefore has to run in the
# job before that commit, after the workspace is linked in as the tap and the
# tap is trusted. An audit that only runs after the push (audit.yml) judges a
# formula that is already public.
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

# Prints "ok" when, inside the "update" job, one step links, trusts and audits
# in that order and a LATER step creates the commit. Otherwise prints what is
# wrong.
order() { # $1 = workflow file
	python3 - "$1" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
steps = next(iter(doc["jobs"].values()))["steps"]
def lines(step):
    return [l.strip() for l in step.get("run", "").splitlines()
            if l.strip() and not l.strip().startswith("#")]
def first(ls, prefix):
    for i, l in enumerate(ls):
        if l.startswith(prefix):
            return i
    return None
audit_step = commit_step = None
for n, s in enumerate(steps):
    ls = lines(s)
    if audit_step is None and first(ls, "brew audit") is not None:
        audit_step = n
    if commit_step is None and any("createCommitOnBranch" in l for l in ls):
        commit_step = n
if audit_step is None:
    print("no step runs brew audit")
elif commit_step is None:
    print("no step creates the commit")
elif audit_step >= commit_step:
    print("the audit does not run before the commit")
else:
    ls = lines(steps[audit_step])
    link, trust, audit = first(ls, "ln -s"), first(ls, "brew trust glyndor/tap"), first(ls, "brew audit")
    if link is None or trust is None or not link < trust < audit:
        print("the order is not link, trust, audit")
    elif "--strict" not in ls[audit]:
        print("the audit is not strict")
    else:
        print("ok")
PY
}

plant() { # $1 = file, $2 = audit-step lines (newline separated), $3 = commit step line
	{
		printf 'jobs:\n  update:\n    steps:\n'
		printf '      - run: |\n'
		printf '%s\n' "$2" | sed 's/^/          /'
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
check "an audit placed after the commit is reported" \
	"the audit does not run before the commit" "$(order "$WORK/c/after2.yml")"

plant "$WORK/c/lax.yml" "$(printf '%s\n%s\n%s' "$LINK" "$TRUST" 'brew audit glyndor/tap/podup')" "$COMMIT"
check "an audit that is not strict is reported" "the audit is not strict" "$(order "$WORK/c/lax.yml")"

plant "$WORK/c/late.yml" "$(printf '%s\n%s\n%s' "$LINK" "$AUDIT" "$TRUST")" "$COMMIT"
check "a trust after the audit is reported" "the order is not link, trust, audit" "$(order "$WORK/c/late.yml")"

plant "$WORK/c/commented.yml" "$(printf '%s\n%s\n%s' "$LINK" "$TRUST" '# brew audit --strict x')" "$COMMIT"
check "a commented-out audit does not count" "no step runs brew audit" "$(order "$WORK/c/commented.yml")"

check "the live update workflow audits strictly before it commits" "ok" \
	"$(order "$HERE/.github/workflows/update.yml")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
