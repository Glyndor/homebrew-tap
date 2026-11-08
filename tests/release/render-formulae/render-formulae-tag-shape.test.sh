#!/usr/bin/env bash
#
# A tag that is no SemVer version but passes the character guard (v1.2, v1,
# v1.0.0+) is refused and writes nothing. Nothing pinned this: the character
# guard lets these through, and only the ordering check, which runs after the
# provenance checks on purpose (a downgrade is decided on authenticated
# metadata only), refuses them. The refusal keeps exit 1, not the skip code 3:
# update.yml must stop before it commits anything from that run.
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
ATTEST_STUB_LOG="$WORK/attest.log"
export ATTEST_STUB_LOG

# render <root>: the ordinary product row in a fresh root, exit status in $rc
# and output in $out.
render() {
	local root="$1"
	new_root "$root"
	generator_with "$root/scripts/release/render-formulae.sh" "$PODUP"
	: > "$ATTEST_STUB_LOG"
	rc=0
	out="$( cd "$root" && "$root/scripts/release/render-formulae.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
}

publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
render "$WORK/ok"
check "control: an ordinary release renders" "0" "$rc"
check "control: and its assets were attested" "1" "$([ -s "$ATTEST_STUB_LOG" ] && echo 1 || echo 0)"

for tag in v1.2 v1 v1.0.0+; do
	publish Glyndor/podup "$tag" podup-darwin-arm64 podup-darwin-x86_64
	render "$WORK/bad-$tag"
	check "$tag is refused (exit 1)" "1" "$rc"
	check "$tag is named as no SemVer version" "1" "$(grep -c "is not a valid SemVer release version" <<<"$out")"
	check "$tag writes no formula" "0" "$(find "$WORK/bad-$tag/Formula" -name podup.rb | wc -l)"
done

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
