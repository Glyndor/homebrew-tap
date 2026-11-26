#!/usr/bin/env bash
#
# scripts/monitoring/install-from-the-tap.sh installs a formula from the published tap with Homebrew and upgrades it
# from the version before. It runs where nobody watches, after the updater pushes, so each way it could say "it
# installs" wrongly has to be shown here to say no: a formula that installs another version than it declares, a
# program that prints another version or does not start, a failing `brew test`, an upgrade that changes nothing or
# leaves the old program in place, and a history with nothing to upgrade from, which is not a pass.
#
# The script is run as it ships, with `brew` replaced by a stub that keeps what is installed in a folder and reads
# the version of the formula the tap clone holds at that moment, over a git repository planted for each case. What
# only a real Homebrew can answer (that `brew install` really builds and links, that `brew upgrade` really replaces)
# is not covered here: it is what the first run of the workflow on GitHub shows.
# Requires: bash, git, jq, python3.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/monitoring/install-from-the-tap.sh"
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

for tool in git jq python3; do
	command -v "$tool" >/dev/null 2>&1 || { echo "NOTE  $tool is missing, so nothing below could run. Not a pass."; exit 1; }
done

R="$WORK/checkout"; T="$WORK/tapclone"; S="$WORK/state"
mkdir -p "$WORK/bin"

cat > "$WORK/bin/brew" <<'STUB'
#!/usr/bin/env bash
tapversion() { sed -n 's|.*releases/download/v\([^/"]*\)/.*|\1|p' "$TAPDIR/Formula/probe.rb" | head -n 1; }
program() { # <what it prints>
	mkdir -p "$STATE/bin"
	if [ -n "${STUB_NOSTART:-}" ]; then printf '#!/bin/sh\nexit 126\n' > "$STATE/bin/probe"
	else printf '#!/bin/sh\necho "probe %s"\n' "$1" > "$STATE/bin/probe"; fi
	chmod +x "$STATE/bin/probe"
}
calls() { local n; n=$(( $(cat "$STATE/n.$1" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE/n.$1"; echo "$n"; }
case "$1" in
	tap) [ -z "${STUB_TAP_FAIL:-}" ] ;;
	--repository)
		[ -z "${STUB_NO_CLONE:-}" ] || exit 1
		if [ -n "${STUB_CLONE_MISSING:-}" ]; then echo "$STATE/no-such-folder"
		elif [ -n "${STUB_CLONE_NOT_GIT:-}" ]; then mkdir -p "$STATE/plain"; echo "$STATE/plain"
		else echo "$TAPDIR"; fi ;;
	info) if [ -n "${STUB_NO_VERSION:-}" ]; then echo '{"formulae":[{"versions":{"stable":null}}]}'; else printf '{"formulae":[{"versions":{"stable":"%s"}}]}\n' "$(tapversion)"; fi ;;
	install)
		n="$(calls install)"
		[ -z "${STUB_INSTALL_FAIL:-}" ] || exit 1
		[ "${STUB_INSTALL_FAIL_NTH:-}" != "$n" ] || exit 1
		v="${STUB_INSTALL_AS:-$(tapversion)}"; [ "${STUB_INSTALL_AS_NTH:-}" != "$n" ] || v=9.9.9
		echo "$v" > "$STATE/installed"; program "${STUB_PRINTS:-$v}"
		[ "${STUB_LOCK_ON_INSTALL_NTH:-}" != "$n" ] || chmod 555 "$TAPDIR/Formula" ;;
	uninstall)
		[ -z "${STUB_UNINSTALL_FAIL:-}" ] || exit 1
		rm -f "$STATE/installed"; [ -z "${STUB_LOCK_ON_UNINSTALL:-}" ] || chmod 555 "$TAPDIR/Formula" ;;
	test) n="$(calls test)"; [ -z "${STUB_TEST_FAIL:-}" ] && [ "${STUB_TEST_FAIL_NTH:-}" != "$n" ] ;;
	list) [ -f "$STATE/installed" ] && echo "probe $(cat "$STATE/installed")" ;;
	upgrade)
		[ -z "${STUB_UPGRADE_FAIL:-}" ] || exit 1
		[ -z "${STUB_UPGRADE_NOOP:-}" ] || exit 0
		v="$(tapversion)"; echo "$v" > "$STATE/installed"
		[ -n "${STUB_UPGRADE_OLD_PROGRAM:-}" ] || program "$v" ;;
esac
STUB
chmod +x "$WORK/bin/brew"

formula() { # <tag>
	printf 'class Probe < Formula\n  url "https://github.com/Glyndor/probe/releases/download/%s/probe-linux-x86_64"\n  sha256 "%064d"\nend\n' "$1" "$RANDOM"
}
plant() { # <tag>... : a checkout with one commit of the formula for each tag, and a clone of it as the tap
	chmod -R u+w "$T" 2>/dev/null; rm -rf "$R" "$T" "$S"; mkdir -p "$R/Formula" "$S"
	git -C "$R" init -q -b main; git -C "$R" config user.name t; git -C "$R" config user.email t@example.invalid; git -C "$R" config commit.gpgsign false
	local tag
	for tag in "$@"; do formula "$tag" > "$R/Formula/probe.rb"; git -C "$R" add -A; git -C "$R" commit -q -m "formula $tag"; done
	git clone -q "$R" "$T"
}
run() {
	chmod -R u+w "$T" 2>/dev/null
	( cd "$R" && TAPDIR="$T" STATE="$S" TAP=probe/tap PATH="$WORK/bin:$S/bin:/usr/bin:/bin" bash "$SCRIPT" probe >"$WORK/out" 2>&1 ); echo $?
}
said() { grep -c -- "$1" "$WORK/out"; }

plant v5.0.0 v6.0.0
check "a formula that installs, starts, passes its test and upgrades from the version before passes" "0" "$(run)"
check "and says it installs, from which formula it went back, and the upgrade" "1" "$(said 'probe 5.0.0 installed from the formula of')"
check "and what it went from and to" "1" "$(said 'went from 5.0.0 to 6.0.0 with brew upgrade')"
check "and the program the user is left with is the new one" "probe 6.0.0" "$(PATH="$S/bin:$PATH" probe)"

plant v6.0.0
check "a tap with no earlier version of the formula is exit 3" "3" "$(run)"
check "and says it was not verified" "1" "$(said 'NOT VERIFIED')"
plant v6.0.0 v6.0.0
check "the same version rendered twice is no earlier version either" "3" "$(run)"

plant v5.0.0 v6.0.0; export STUB_TAP_FAIL=1; check "a tap that cannot be added fails" "1" "$(run)"; unset STUB_TAP_FAIL
check "and says so" "1" "$(said 'cannot be added')"
plant v5.0.0 v6.0.0; export STUB_NO_CLONE=1; check "a tap with no clone to find fails" "1" "$(run)"; unset STUB_NO_CLONE
plant v5.0.0 v6.0.0; export STUB_NO_VERSION=1; check "a formula brew reports no version for fails" "1" "$(run)"; unset STUB_NO_VERSION
check "and says so" "1" "$(said 'does not report a stable version')"

plant v5.0.0 v6.0.0; export STUB_INSTALL_FAIL=1; check "an install that fails fails" "1" "$(run)"; unset STUB_INSTALL_FAIL
check "and says which command" "1" "$(said 'brew install glyndor/tap/probe failed\|brew install probe/tap/probe failed')"
plant v5.0.0 v6.0.0; export STUB_INSTALL_AS=6.0.1; check "an install that lands on another version than the formula declares fails" "1" "$(run)"; unset STUB_INSTALL_AS
check "and says which" "1" "$(said 'installed probe 6.0.1, not the 6.0.0')"
plant v5.0.0 v6.0.0; export STUB_PRINTS=0.0.1; check "a program that prints another version fails" "1" "$(run)"; unset STUB_PRINTS
check "and shows what it printed" "1" "$(said 'prints "probe 0.0.1"')"
plant v5.0.0 v6.0.0; export STUB_NOSTART=1; check "a program that does not start fails" "1" "$(run)"; unset STUB_NOSTART
check "and says so" "1" "$(said 'does not start')"
plant v5.0.0 v6.0.0; export STUB_TEST_FAIL=1; check "a formula whose brew test fails fails" "1" "$(run)"; unset STUB_TEST_FAIL
check "and says so" "1" "$(said 'brew test probe/tap/probe failed')"

plant v5.0.0 v6.0.0; export STUB_CLONE_MISSING=1; check "a clone that is not a folder fails" "1" "$(run)"; unset STUB_CLONE_MISSING
check "and says so" "1" "$(said 'is not a folder')"
plant v5.0.0 v6.0.0; export STUB_CLONE_NOT_GIT=1; check "a clone that is not a repository fails" "1" "$(run)"; unset STUB_CLONE_NOT_GIT
check "and says it has no HEAD" "1" "$(said 'has no HEAD')"
plant v5.0.0 v6.0.0; export STUB_NO_CLONE=1; run >/dev/null; unset STUB_NO_CLONE
check "a clone that brew cannot find is said so" "1" "$(said 'cannot be found')"
plant v5.0.0 v6.0.0; export STUB_TEST_FAIL_NTH=1; check "a brew test that fails only the first time fails" "1" "$(run)"; unset STUB_TEST_FAIL_NTH
check "and is the one after the first install" "0" "$(said 'passes its test')"
plant v5.0.0 v6.0.0; export STUB_TEST_FAIL_NTH=2; check "a brew test that fails only after the upgrade fails" "1" "$(run)"; unset STUB_TEST_FAIL_NTH
check "and says it was after it" "1" "$(said 'failed after the upgrade')"
plant v5.0.0 v6.0.0; export STUB_UNINSTALL_FAIL=1; check "an uninstall that fails fails" "1" "$(run)"; unset STUB_UNINSTALL_FAIL
check "and says so" "1" "$(said 'brew uninstall probe failed')"
plant v5.0.0 v6.0.0; export STUB_LOCK_ON_UNINSTALL=1; check "a clone in which the old formula cannot be put fails" "1" "$(run)"; unset STUB_LOCK_ON_UNINSTALL
check "and says so" "1" "$(said 'cannot be put in the clone')"
plant v5.0.0 v6.0.0; export STUB_INSTALL_FAIL_NTH=2; check "an install of the old formula that fails fails" "1" "$(run)"; unset STUB_INSTALL_FAIL_NTH
check "and says it was the one of the commit" "1" "$(said 'install of the formula of')"
plant v5.0.0 v6.0.0; export STUB_INSTALL_AS_NTH=2; check "an old formula that installs another version than its own fails" "1" "$(run)"; unset STUB_INSTALL_AS_NTH
check "and says which commit and which version" "1" "$(said 'installed probe 9.9.9, not its 5.0.0')"
plant v5.0.0 v6.0.0; export STUB_LOCK_ON_INSTALL_NTH=2; check "a clone in which the current formula cannot be put back fails" "1" "$(run)"; unset STUB_LOCK_ON_INSTALL_NTH
check "and says so" "1" "$(said 'cannot be put back')"

plant v5.0.0 v6.0.0; export STUB_UPGRADE_FAIL=1; check "an upgrade that fails fails" "1" "$(run)"; unset STUB_UPGRADE_FAIL
check "and says so" "1" "$(said 'brew upgrade probe/tap/probe failed')"
plant v5.0.0 v6.0.0; export STUB_UPGRADE_NOOP=1; check "an upgrade that changes nothing fails" "1" "$(run)"; unset STUB_UPGRADE_NOOP
check "and says what it is after the upgrade" "1" "$(said 'after brew upgrade probe is 5.0.0, not 6.0.0')"
plant v5.0.0 v6.0.0; export STUB_UPGRADE_OLD_PROGRAM=1; check "an upgrade that leaves the old program in place fails" "1" "$(run)"; unset STUB_UPGRADE_OLD_PROGRAM
check "and shows what it prints" "1" "$(said 'prints "probe 5.0.0"')"

plant v5.0.0 v6.0.0; rm -rf "$T"; git clone -q --depth 1 "file://$R" "$T"
check "a clone of the tap that has not the commit of the version before fetches it" "0" "$(run)"
plant v5.0.0 v6.0.0; rm -rf "$T"; git clone -q --depth 1 "file://$R" "$T"; git -C "$T" remote set-url origin "$WORK/nowhere"
check "and one that cannot fetch it fails" "1" "$(run)"
check "and says the commit is not in the clone" "1" "$(said 'is not in the clone of probe/tap')"
plant v4.0.0 v5.0.0 v6.0.0
check "the version before is the newest one below, not the oldest" "0" "$(run)"
check "and the upgrade says it went from it" "1" "$(said 'went from 5.0.0 to 6.0.0')"

chmod -R u+w "$T" 2>/dev/null

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
