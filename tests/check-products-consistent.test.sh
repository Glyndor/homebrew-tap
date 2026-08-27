#!/usr/bin/env bash
#
# Tests for scripts/check-products-consistent.sh -- the check that PRODUCTS,
# the README table and Formula/ still agree.
#
# This check lived inline in ci.yml, where nothing could reach it. It is the
# only thing standing between a product being declared and a formula for it
# actually existing, so it needs to fail for the right reason rather than pass
# for any reason.
#
# The collation case is the one worth having. `sort -u` compares under the
# environment's collation and UTF-8 collations ignore punctuation at the
# primary level, so `pod-up` and `podup` compare EQUAL and one is dropped from
# whichever list holds both. Two lists that genuinely differ then compare the
# same and the check exits 0 over real drift.
#
# Requires: nothing beyond coreutils.
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$HERE/scripts/check-products-consistent.sh"
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

# A throwaway tap: PRODUCTS in scripts/, a README table, and Formula/*.rb.
# Every argument is a formula name; the three lists are built from the same
# arguments unless a case overrides one of them.
mktap() { # $1=name $2...=formula names
	local tap="$WORK/$1"; shift
	mkdir -p "$tap/scripts" "$tap/Formula"
	{
		echo 'PRODUCTS=('
		local f
		for f in "$@"; do echo "	\"$f|$f|Glyndor/$f\""; done
		echo ')'
	} > "$tap/scripts/render-formulae.sh"
	{
		echo '| Formula | Product |'
		echo '|---|---|'
		for f in "$@"; do echo "| $f | $f |"; done
	} > "$tap/README.md"
	for f in "$@"; do : > "$tap/Formula/$f.rb"; done
	echo "$tap"
}

run() { "$CHECK" "$1" >"$WORK/out" 2>&1; }
said() { grep -qF "$1" "$WORK/out" && echo 1 || echo 0; }

# --- everything agrees ------------------------------------------------------
T="$(mktap agree alpha beta)"
rc=0; run "$T" || rc=$?
check "a tap where all three agree passes" "0" "$rc"

# --- Formula/ is missing a file ---------------------------------------------
T="$(mktap noformula alpha beta)"
rm -f "$T/Formula/beta.rb"
rc=0; run "$T" || rc=$?
check "a missing formula file fails" "1" "$rc"
check "and it names re-running the generator" "1" "$(said 'render-formulae.sh')"

# --- an unreadable PRODUCTS is a hard error, not an empty pass --------------
#
# An empty `declared` compared against an empty `documented` would agree, and
# the check would report a tap with no products as consistent.
T="$(mktap noproducts alpha)"
printf '# no PRODUCTS table here\n' > "$T/scripts/render-formulae.sh"
rc=0; run "$T" || rc=$?
check "an unreadable PRODUCTS table fails rather than agreeing with nothing" "1" "$rc"
check "and says it could not read PRODUCTS" "1" "$(said 'could not read PRODUCTS')"

# --- the README is prose, and editing it must not break anything -----------
#
# This check compared PRODUCTS against the README's table until 2026-08-26. It
# made rewording documentation a CI failure, and it broke on a heading rename
# while being ported between these two repositories -- the check was wrong and
# the README was fine. What gets installed is decided by Formula/, which is still
# compared; the README is documentation and can drift.
B="$(mkbucket readme-edited alpha)" 2>/dev/null || B="$(mktap readme-edited alpha)"
printf 'totally different prose, no table at all\n' > "$B/README.md"
rc=0; run "$B" || rc=$?
check "rewriting the README does not fail the check" "0" "$rc"

# --- the collation case -----------------------------------------------------
#
# Both names are legal formula names and they differ only by a hyphen. Under a
# UTF-8 collation `sort -u` treats them as equal and keeps one, so a Formula/
# that is genuinely missing one of them compares equal to a PRODUCTS that
# declares both. The script pins LC_ALL=C; this case is what proves it.
T="$(mktap collation pod-up podup)"
rm -f "$T/Formula/podup.rb"
for loc in en_US.UTF-8 en_GB.UTF-8 de_DE.UTF-8 fr_FR.UTF-8 C; do
	locale -a 2>/dev/null | grep -qix "${loc/UTF-8/utf8}" || continue
	rc=0; LC_ALL="$loc" run "$T" || rc=$?
	check "a missing formula is caught under $loc" "1" "$rc"
done

# The same tap with nothing missing must still pass, or the case above would be
# satisfied by a check that fails on any tap containing those two names.
T="$(mktap collation-ok pod-up podup)"
for loc in en_US.UTF-8 C; do
	locale -a 2>/dev/null | grep -qix "${loc/UTF-8/utf8}" || continue
	rc=0; LC_ALL="$loc" run "$T" || rc=$?
	check "and a complete tap with those names still passes under $loc" "0" "$rc"
done

# --- this repository ---------------------------------------------------------
rc=0; run "$HERE" || rc=$?
check "this tap is consistent" "0" "$rc"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
