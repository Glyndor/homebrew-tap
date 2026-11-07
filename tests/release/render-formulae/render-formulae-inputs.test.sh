#!/usr/bin/env bash
#
# Inputs the renderer must refuse FIRST, naming the cause. Before, a tag
# without the leading v, a repository outside the organization, a SHA256SUMS
# with CRLF line endings and an upper-case digest each travelled further and
# failed late: either the formula was written and the gate refused
# it in the hourly job, or the message blamed the download. A refusal that does
# not name its cause costs a person an hour.
#
# The fixture both this file and its siblings need lives in
# tests/fixtures/release/render-fixture.sh.

set -euo pipefail

HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../fixtures/release" && pwd)"
# shellcheck disable=SC1091
. "$HERE_FIXTURE/render-fixture.sh"
pass=0
fail=0

unset ATTEST_STUB_OUTCOME

# render <root> <generator-rows...>: a fresh root with the given PRODUCTS rows,
# the exit status in $rc and the output in $out.
render() {
	local root="$1"; shift
	new_root "$root"
	generator_with "$root/scripts/release/render-formulae.sh" "$@"
	rc=0
	out="$( cd "$root" && "$root/scripts/release/render-formulae.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
}

# --- the control ------------------------------------------------------------

publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
render "$WORK/ok" "$PODUP"
check "control: an ordinary release renders" "0" "$rc"
check "control: and the formula is written" "1" "$(find "$WORK/ok/Formula" -name podup.rb | wc -l)"

# --- a tag without the leading v ----------------------------------------------

publish Glyndor/podup 9.9.9 podup-darwin-arm64 podup-darwin-x86_64
render "$WORK/notag" "$PODUP"
check "a tag without v is refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and the message names the missing v" "1" "$(grep -c 'does not start with "v"' <<<"$out")"
check "and no formula is written" "0" "$(find "$WORK/notag/Formula" -name podup.rb | wc -l)"

# --- a repository outside the organization ------------------------------------

publish Other/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
render "$WORK/foreign" "Other/podup|podup|Podup|MIT|Docker-compose translator|podup-darwin-arm64|podup-darwin-x86_64|-|-|--version"
check "a repository outside Glyndor is refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and the message names the organization" "1" "$(grep -c 'outside the Glyndor organization' <<<"$out")"
check "and no formula is written from it" "0" "$(find "$WORK/foreign/Formula" -name podup.rb | wc -l)"

# --- a SHA256SUMS with CRLF line endings, validly signed ------------------------

publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
sed 's/$/\r/' "$RELEASES/Glyndor__podup/SHA256SUMS" > "$WORK/crlf.sums"
resign "$WORK/crlf.sums" Glyndor/podup
render "$WORK/crlf" "$PODUP"
check "a CRLF SHA256SUMS is refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and it is diagnosed as CRLF" "1" "$(grep -c 'CRLF' <<<"$out")"
check "and no formula is written from it " "0" "$(find "$WORK/crlf/Formula" -name podup.rb | wc -l)"

# --- an upper-case digest, validly signed ---------------------------------------

publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
awk '{ print toupper($1) "  " $2 }' "$RELEASES/Glyndor__podup/SHA256SUMS" > "$WORK/upper.sums"
resign "$WORK/upper.sums" Glyndor/podup
render "$WORK/upper" "$PODUP"
check "an upper-case digest is refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and the message says upper case, not a bad download" "1" "$(grep -c 'in uppercase' <<<"$out")"
check "and no formula is written from it  " "0" "$(find "$WORK/upper/Formula" -name podup.rb | wc -l)"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
