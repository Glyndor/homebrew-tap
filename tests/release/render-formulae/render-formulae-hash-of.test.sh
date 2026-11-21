#!/usr/bin/env bash
#
# hash_of picks the digest of one asset out of the signed SHA256SUMS. The asset
# name is a string, and awk compares two values that both look like numbers as
# numbers: an asset called 1e5 matched the line of one called 100000, and 010
# matched 10. The function then reported the asset as listed twice, or returned the
# digest of another entry, and a release with such an asset could not be rendered.
#
# The function is read out of the renderer by name and run over a SHA256SUMS written
# here, so the case exercises the text that ships. Each asset whose name looks like a
# number has the accepted case beside it: the one the lookup must return, and an
# asset the file does not list.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RENDERER="$HERE/scripts/release/render-formulae.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"
		pass=$((pass + 1))
	else
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# shellcheck disable=SC2034 # read by hash_of, which is sourced below
work="$WORK"
sed -n '/^hash_of()/,/^}/p' "$RENDERER" > "$WORK/hash_of.sh"
check "hash_of was read out of the renderer" "1" "$([ -s "$WORK/hash_of.sh" ] && echo 1 || echo 0)"
# shellcheck disable=SC1091 # written just above
. "$WORK/hash_of.sh"

A=$(printf 'a%.0s' {1..64})
B=$(printf 'b%.0s' {1..64})
C=$(printf 'c%.0s' {1..64})
printf '%s  1e5\n%s  100000\n%s  010\n%s  10\n%s  plain.exe\n' "$A" "$B" "$C" "$A" "$B" > "$WORK/SHA256SUMS"

ask() { hash_of "$1" 2>"$WORK/err"; }
rc=0; out="$(ask 1e5)" || rc=$?
check "an asset named like 1e5 is found" "0" "$rc"
check "and it is its own digest, not the one of 100000" "$A" "$out"
rc=0; out="$(ask 100000)" || rc=$?
check "an asset named 100000 is found" "0" "$rc"
check "and it is its own digest" "$B" "$out"
rc=0; out="$(ask 010)" || rc=$?
check "an asset named 010 is found" "0" "$rc"
check "and it is its own digest, not the one of 10" "$C" "$out"
rc=0; out="$(ask 10)" || rc=$?
check "an asset named 10 is found" "0" "$rc"
check "and it is its own digest" "$A" "$out"
check "none of them was reported as listed more than once" "0" "$(grep -c 'times' "$WORK/err")"
rc=0; out="$(ask plain.exe)" || rc=$?
check "an ordinary name is found" "0" "$rc"
check "and it is its digest" "$B" "$out"
rc=0; out="$(ask 1E5)" || rc=$?
check "a name that is only the same number is not found" "1" "$rc"
rc=0; out="$(ask 100)" || rc=$?
check "a name the file does not list is not found" "1" "$rc"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
