#!/usr/bin/env bash
#
# A tag that is no SemVer version but passes the character guard (v1.2, v1,
# v1.0.0+) is refused and writes nothing. Nothing pinned this: the character
# guard lets these through, and only the ordering check, which runs after the
# provenance checks on purpose (a downgrade is decided on authenticated
# metadata only), refuses them. The refusal keeps exit 1, not the skip code 3:
# update.yml must stop before it commits anything from that run.
#
# A tag whose version does not start with a digit (vabc, v-1.0.0) is refused
# earlier and differently: by version_guard, before anything is downloaded, and
# as a skipped product (exit 3), not as the abort of the whole publication.
# The character guard in front of it accepts both, so without its own case the
# digit check could be deleted and the tag would still be refused, later, by the
# ordering check, after every asset had been fetched and attested.
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

# A tag the character guard accepts but whose version does not start with a digit:
# refused before any download, and as a skip of the product.
for tag in vabc v-1.0.0; do
	publish Glyndor/podup "$tag" podup-darwin-arm64 podup-darwin-x86_64
	render "$WORK/nodigit-$tag"
	check "$tag is refused as a skipped product (exit 3)" "3" "$rc"
	check "$tag is named as not starting with a digit" "1" "$(grep -c 'does not start with a digit' <<<"$out")"
	check "$tag is NOT left to the SemVer ordering check" "0" "$(grep -c 'is not a valid SemVer release version' <<<"$out")"
	check "$tag asks for no attestation" "0" "$(wc -l < "$ATTEST_STUB_LOG")"
	check "$tag writes no formula" "0" "$(find "$WORK/nodigit-$tag/Formula" -name podup.rb | wc -l)"
done

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
