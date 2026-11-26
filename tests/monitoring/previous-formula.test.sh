#!/usr/bin/env bash
#
# scripts/monitoring/previous-formula.sh finds the commit of the formula the tap had before the current one, the
# starting point of the upgrade that install-from-the-tap.sh tries. An upgrade is worth what its starting point is
# worth, so each way the script could hand over the wrong commit is shown here to be refused: the same version
# rendered again, a version above the current one (a rollback), a pre-release taken for a release, identifiers
# compared as text when they are numbers, a formula that names two releases, a version that is not SemVer, and a
# history with nothing below the current version, which is a different exit from a failure.
#
# The script is run as it ships, in a git repository planted for each case. No network.
# Requires: bash, git, python3.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/monitoring/previous-formula.sh"
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

for tool in git python3; do
	command -v "$tool" >/dev/null 2>&1 || { echo "NOTE  $tool is missing, so nothing below could run. Not a pass."; exit 1; }
done

R="$WORK/repo"
formula() { # <tag> [intel tag]: a formula as the updater writes it
	printf 'class Probe < Formula\n  on_macos do\n    on_arm do\n      url "https://github.com/Glyndor/probe/releases/download/%s/probe-darwin-arm64"\n      sha256 "%064d"\n    end\n    on_intel do\n      url "https://github.com/Glyndor/probe/releases/download/%s/probe-darwin-x86_64"\n      sha256 "%064d"\n    end\n  end\nend\n' \
		"$1" "$RANDOM" "${2:-$1}" "$RANDOM"
}
start() { rm -rf "$R"; mkdir -p "$R/Formula"; git -C "$R" init -q -b main; git -C "$R" config user.name t; git -C "$R" config user.email t@example.invalid; git -C "$R" config commit.gpgsign false; }
commit() { # <formula text> : the commit id on stdout
	printf '%s' "$1" > "$R/Formula/probe.rb"; git -C "$R" add -A; git -C "$R" commit -q --allow-empty -m "formula" ; git -C "$R" rev-parse HEAD
}
run() { ( cd "$R" && bash "$SCRIPT" Formula/probe.rb 2> "$WORK/err" ); }

start; c1="$(commit "$(formula v5.0.0)")"; c2="$(commit "$(formula v5.1.0)")"; commit "$(formula v6.0.0)" >/dev/null
out="$(run)"; rc=$?
check "the commit before the current version is found" "0" "$rc"
check "and it prints its sha and its version" "$c2 5.1.0" "$out"

start; commit "$(formula v5.1.0)" >/dev/null; c2="$(commit "$(formula v5.2.0)")"; commit "$(formula v6.0.0)" >/dev/null; commit "$(formula v6.0.0)" >/dev/null
out="$(run)"; rc=$?
check "the same version rendered again is not a previous one" "$c2 5.2.0 0" "$out $rc"

start; commit "$(formula v6.0.0)" >/dev/null; commit "$(formula v6.0.0)" >/dev/null
out="$(run)"; rc=$?
check "a history with nothing below the current version is exit 3" "3" "$rc"
check "and prints no commit" "" "$out"
check "and says so" "1" "$(grep -c 'holds a version below 6.0.0' "$WORK/err")"

start; commit "$(formula v7.0.0)" >/dev/null; commit "$(formula v6.0.0)" >/dev/null
run >/dev/null; rc=$?
check "a rollback does not take the version above it for a previous one" "3" "$rc"

start; c1="$(commit "$(formula v6.0.0-rc.1)")"; commit "$(formula v6.0.0)" >/dev/null
out="$(run)"; rc=$?
check "a pre-release is below its release" "$c1 6.0.0-rc.1 0" "$out $rc"
start; commit "$(formula v6.0.0)" >/dev/null; commit "$(formula v6.0.0-rc.1)" >/dev/null
run >/dev/null; rc=$?
check "and a release is not below its pre-release" "3" "$rc"

start; c1="$(commit "$(formula v1.0.0-alpha.2)")"; commit "$(formula v1.0.0-alpha.10)" >/dev/null
out="$(run)"; rc=$?
check "numeric identifiers of a pre-release are compared as numbers" "$c1 1.0.0-alpha.2 0" "$out $rc"
start; commit "$(formula v1.0.0-alpha.10)" >/dev/null; commit "$(formula v1.0.0-alpha.2)" >/dev/null
run >/dev/null; rc=$?
check "and alpha.10 is not below alpha.2 as text would have it" "3" "$rc"
start; c1="$(commit "$(formula v1.0.0-1)")"; commit "$(formula v1.0.0-alpha)" >/dev/null
out="$(run)"; rc=$?
check "a numeric identifier is below a text one" "$c1 1.0.0-1 0" "$out $rc"

start; commit "$(formula v6.0.0+build1)" >/dev/null; commit "$(formula v6.0.0+build2)" >/dev/null
run >/dev/null; rc=$?
check "build metadata is not part of the order" "3" "$rc"

start; c1="$(commit "$(formula v5.0.0)")"; commit 'class Probe < Formula
end
' >/dev/null; commit "$(formula v6.0.0)" >/dev/null
out="$(run)"; rc=$?
check "a commit where the file names no release is skipped" "$c1 5.0.0 0" "$out $rc"

start; commit "$(formula v5.0.0)" >/dev/null; commit "$(formula v6.0.0 v5.9.0)" >/dev/null
run >/dev/null; rc=$?
check "a formula that names two releases at HEAD fails" "1" "$rc"
check "and says its version is not known" "1" "$(grep -c 'names no single release' "$WORK/err")"
start; commit "$(formula v6.0)" >/dev/null
run >/dev/null; rc=$?
check "a version that is not SemVer fails" "1" "$rc"
check "and says so" "1" "$(grep -c 'is not a SemVer version' "$WORK/err")"
start; commit "$(formula v5.0)" >/dev/null; commit "$(formula v6.0.0)" >/dev/null
run >/dev/null; rc=$?
check "an earlier commit with a version that is not SemVer fails" "1" "$rc"

start; commit "$(formula v5.0.0)" >/dev/null; git -C "$R" rm -q Formula/probe.rb; git -C "$R" commit -q -m gone
run >/dev/null; rc=$?
check "a formula that is not at HEAD fails" "1" "$rc"
check "and says it cannot be read" "1" "$(grep -c 'cannot be read at HEAD' "$WORK/err")"
( cd "$WORK" && bash "$SCRIPT" Formula/probe.rb 2> "$WORK/err" >/dev/null ); rc=$?
check "outside a repository it fails" "1" "$rc"
( cd "$R" && bash "$SCRIPT" 2> "$WORK/err" >/dev/null ); rc=$?
check "with no formula named it fails" "1" "$rc"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
