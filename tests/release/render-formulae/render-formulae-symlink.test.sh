#!/usr/bin/env bash
#
# The renderer never writes through a symlink in Formula/. Redirecting straight
# into Formula/<name>.rb followed a link there: the render said "rendered",
# Formula/ kept only the link, update.yml saw no change to commit and the tap
# stayed frozen without a single red check. The renderer now refuses the link,
# names it, skips that product (exit 3) and leaves what the link points at
# untouched.
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

# render <root>: the ordinary product row rendered into an existing root, exit
# status in $rc and output in $out.
render() {
	local root="$1"
	generator_with "$root/scripts/release/render-formulae.sh" "$PODUP"
	rc=0
	out="$( cd "$root" && "$root/scripts/release/render-formulae.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
}

publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64

# --- the control: a regular formula is replaced in place ----------------------

new_root "$WORK/plain"
render "$WORK/plain"
check "control: an ordinary release renders" "0" "$rc"
check "control: and leaves no temporary file behind" "0" "$(find "$WORK/plain/Formula" -name '.render.*' | wc -l)"
render "$WORK/plain"
check "control: and renders over its own formula" "0" "$rc"

# --- a formula that is a symlink ----------------------------------------------

new_root "$WORK/link"
render "$WORK/link"
mv "$WORK/link/Formula/podup.rb" "$WORK/outside.rb"
echo '# kept as it was' >> "$WORK/outside.rb"
ln -s "$WORK/outside.rb" "$WORK/link/Formula/podup.rb"
before="$(cksum <"$WORK/outside.rb")"
render "$WORK/link"
check "a symlinked formula skips the product (exit 3)" "3" "$rc"
check "and the message names the symlink" "1" "$(grep -c 'Formula/podup.rb is a symlink' <<<"$out")"
check "and the file the link points at is untouched" "$before" "$(cksum <"$WORK/outside.rb")"
check "and Formula/ still holds the link, not a rendered file" "1" "$([ -L "$WORK/link/Formula/podup.rb" ] && echo 1 || echo 0)"
check "and no temporary file is left" "0" "$(find "$WORK/link/Formula" -name '.render.*' | wc -l)"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
