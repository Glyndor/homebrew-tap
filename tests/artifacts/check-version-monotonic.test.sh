#!/usr/bin/env bash
#
# Tests for scripts/artifacts/check-version-monotonic.sh: a pull request cannot
# lower the version of a formula already committed on the base branch.
#
# Each case builds a small repository whose base commit holds Formula/p.rb at
# one version, changes the working tree to another and runs the gate. The
# orderings are the SemVer ones the renderer uses (pre-release below stable,
# numeric identifiers below text, build metadata ignored). The last case runs
# the same rollback against a copy of the gate whose comparison is replaced by
# `false`, and it must pass there, so the refusal is shown to come from the
# comparison and not from some other rule.
#
# Two cases more than the bucket's: a formula naming two different tags is refused,
# and a formula in a subdirectory or named .RB is compared like any other.
#
# Requires: git, python3.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
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

frm() { # $1=tag version -> a formula body whose urls name that release
	printf 'class P < Formula\n  url "https://github.com/Glyndor/p/releases/download/v%s/p-linux"\n  url "https://github.com/Glyndor/p/releases/download/v%s/p-darwin"\nend\n' "$1" "$1"
}
repo() { # $1=name $2=base version -> prints the repo; the base commit is HEAD
	local r="$WORK/$1"
	mkdir -p "$r/Formula"
	frm "$2" > "$r/Formula/p.rb"
	git -C "$r" init -q
	git -C "$r" -c user.name=t -c user.email=t@example.invalid add -A
	git -C "$r" -c user.name=t -c user.email=t@example.invalid commit -q -m base
	echo "$r"
}
gate() { # $1=repo [$2=gate script] [$3=base]
	(cd "$1" && "${2:-$HERE/scripts/artifacts/check-version-monotonic.sh}" "${3:-HEAD}") >"$WORK/out" 2>&1
}

n=0
while IFS=" " read -r base head expect; do
	n=$((n + 1)); R="$(repo "c$n" "$base")"
	frm "$head" > "$R/Formula/p.rb"
	rc=0; gate "$R" || rc=$?
	check "$base -> $head ($expect)" "$([ "$expect" = ok ] && echo 0 || echo 1)" "$rc"
done <<'CASES'
1.2.0 1.2.0 ok
1.2.0 1.2.1 ok
1.2.0 1.3.0 ok
1.2.0 2.0.0 ok
1.2.0 1.1.9 refused
1.2.0 0.9.9 refused
1.10.0 1.9.0 refused
1.2.0 1.2.0-rc1 refused
1.2.0-rc1 1.2.0 ok
1.2.0-rc2 1.2.0-rc1 refused
1.2.0-rc1 1.2.0-rc2 ok
1.2.0-1 1.2.0-alpha ok
1.2.0-alpha 1.2.0-1 refused
1.2.0+a 1.2.0+b ok
1.2.0 1.2.0+build5 ok
1.2.0 not-a-version refused
1.2.0 01.2.0 refused
1.2.0-01 1.2.0 refused
CASES

R="$(repo new 1.0.0)"; frm 0.0.1 > "$R/Formula/q.rb"
rc=0; gate "$R" || rc=$?
check "a formula new in the tree is not compared" "0" "$rc"

R="$(repo gone 1.0.0)"; rm "$R/Formula/p.rb"
rc=0; gate "$R" || rc=$?
check "a formula removed from the tree is not compared" "0" "$rc"

R="$(repo nover 1.0.0)"; printf 'class P < Formula\nend\n' > "$R/Formula/p.rb"
rc=0; gate "$R" || rc=$?
check "a formula with no release url is refused" "1" "$rc"

R="$(repo notjson 1.0.0)"; printf 'oops' > "$R/Formula/p.rb"
rc=0; gate "$R" || rc=$?
check "a formula with no recognisable url is refused" "1" "$rc"

R="$(repo badbase 1.0.0)"; frm x > "$R/Formula/p.rb"
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -q -am bad
frm 1.0.0 > "$R/Formula/p.rb"
rc=0; gate "$R" "" HEAD || rc=$?
check "a base formula with no valid version is refused" "1" "$rc"

R="$(repo nobase 1.0.0)"
rc=0; gate "$R" "" deadbeef || rc=$?
check "an unknown base commit is refused" "1" "$rc"

R="$(repo noarg 1.0.0)"
rc=0; (cd "$R" && "$HERE/scripts/artifacts/check-version-monotonic.sh") >"$WORK/out" 2>&1 || rc=$?
check "no base argument is refused" "1" "$rc"

R="$(repo two 1.0.0)"; printf 'url "https://github.com/Glyndor/p/releases/download/v1.0.0/a"\nurl "https://github.com/Glyndor/p/releases/download/v2.0.0/b"\n' > "$R/Formula/p.rb"
rc=0; gate "$R" || rc=$?
check "a formula naming two tags is refused" "1" "$rc"

R="$(repo deep 1.0.0)"; mkdir "$R/Formula/sub"; frm 2.0.0 > "$R/Formula/sub/z.RB"
git -C "$R" -c user.name=t -c user.email=t@example.invalid add -A
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -q -m sub
frm 1.0.0 > "$R/Formula/sub/z.RB"
rc=0; gate "$R" || rc=$?
check "a .RB file in a subdirectory is compared too" "1" "$rc"

R="$(repo msg 1.2.0)"; frm 1.1.0 > "$R/Formula/p.rb"
rc=0; gate "$R" || rc=$?
check "the error names the file and both sides" "1" "$(grep -c 'Formula/p.rb: version 1.1.0 is below' "$WORK/out")"

# The gate reads the repository from its root, wherever it is started. Run from
# a subfolder, the pathspec used to match nothing and every rollback passed.
R="$(repo subdir 1.2.0)"; frm 1.1.0 > "$R/Formula/p.rb"; mkdir "$R/Formula/deep"
rc=0; (cd "$R/Formula/deep" && "$HERE/scripts/artifacts/check-version-monotonic.sh" HEAD) >"$WORK/out" 2>&1 || rc=$?
check "a rollback is refused when the gate starts in a subfolder" "1" "$rc"
check "  and says which formula went back" "1" "$(grep -c 'Formula/p.rb: version 1.1.0 is below' "$WORK/out")"

R="$(repo none 1.0.0)"; git -C "$R" rm -q -r Formula
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -q -m empty
rc=0; gate "$R" || rc=$?
check "a base with no formula is refused, not approved" "1" "$rc"
check "  and the error says nothing was compared" "1" "$(grep -c 'nothing was compared' "$WORK/out")"

# Control: the same rollback, with the comparison replaced by `false`.
CUT="$WORK/cut.sh"
sed 's/if precedence(new_version, name) < old:/if False:/' "$HERE/scripts/artifacts/check-version-monotonic.sh" > "$CUT"
chmod +x "$CUT"
check "the control differs from the gate" "1" "$(cmp -s "$CUT" "$HERE/scripts/artifacts/check-version-monotonic.sh" && echo 0 || echo 1)"
R="$(repo ctl 1.2.0)"; frm 1.1.0 > "$R/Formula/p.rb"
rc=0; gate "$R" "$CUT" || rc=$?
check "without the comparison the rollback passes" "0" "$rc"

# Controls for the two guards above, each removed on its own.
python3 -I - "$HERE/scripts/artifacts/check-version-monotonic.sh" "$WORK/noroot.sh" "$WORK/noguard.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
root = 'os.chdir(git("rev-parse", "--show-toplevel").strip())'
guard = "if not names:"
assert root in s and guard in s
# The guard alone would still refuse the subfolder run, so the first control
# loses both: it shows the pathspec finding nothing is what the root fixes.
open(sys.argv[2], "w").write(s.replace(root, "pass", 1).replace(guard, "if False:", 1))
open(sys.argv[3], "w").write(s.replace(guard, "if False:", 1))
PY
chmod +x "$WORK/noroot.sh" "$WORK/noguard.sh"
R="$(repo ctlsub 1.2.0)"; frm 1.1.0 > "$R/Formula/p.rb"; mkdir "$R/Formula/deep"
rc=0; (cd "$R/Formula/deep" && "$WORK/noroot.sh" HEAD) >"$WORK/out" 2>&1 || rc=$?
check "without the root, a rollback from a subfolder passes" "0" "$rc"
R="$(repo ctlnone 1.0.0)"; git -C "$R" rm -q -r Formula
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -q -m empty
rc=0; gate "$R" "$WORK/noguard.sh" || rc=$?
check "without the guard, a base with no formula passes" "0" "$rc"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
