#!/usr/bin/env bash
# Every published platform needs provenance, including both Linux assets.
set -euo pipefail

HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../fixtures/release" && pwd)"
# shellcheck disable=SC1091
. "$HERE_FIXTURE/render-fixture.sh"
pass=0
fail=0

# Keep the shared macOS-only row unchanged: this fixture explicitly publishes
# all four slots, with real digests and the ephemeral release-key signature.
product="Glyndor/podup|podup|Podup|MIT|Docker-compose translator|podup-darwin-arm64|podup-darwin-x86_64|podup-linux-arm64|podup-linux-x86_64|--version"
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64 \
	podup-linux-arm64 podup-linux-x86_64
unset ATTEST_STUB_OUTCOME ATTEST_STUB_REFUSE_ASSET
root="$WORK/linux"
new_root "$root"
generator_with "$root/scripts/release/render-formulae.sh" "$product"
export ATTEST_STUB_LOG="$WORK/attestation.log"
: > "$ATTEST_STUB_LOG"
rc=0
run "$root/scripts/release/render-formulae.sh" "$root" || rc=$?
check "a release with four attested assets renders successfully" "0" "$rc"
check "every asset gets its own provenance check (4 of 4)" "4" \
	"$(grep -c '^attestation verify ' "$ATTEST_STUB_LOG")"
contains "the formula publishes Linux arm64" "$root/Formula/podup.rb" \
	'/v9.9.9/podup-linux-arm64'
contains "the formula publishes Linux x86_64" "$root/Formula/podup.rb" \
	'/v9.9.9/podup-linux-x86_64'
unset ATTEST_STUB_LOG

# Preserve a real, previously rendered formula. Refuse each Linux asset on its
# own, while macOS and the other Linux asset retain valid provenance. The stub
# identifies the asset by its bytes because the renderer reuses one work file.
cp "$root/Formula/podup.rb" "$WORK/expected.rb"
for asset in podup-linux-arm64 podup-linux-x86_64; do
	export ATTEST_STUB_REFUSE_ASSET="$asset"
	rc=0
	run "$root/scripts/release/render-formulae.sh" "$root" || rc=$?
	check "$asset provenance naming another tag is refused" "3" "$rc"
	contains "the refusal identifies $asset and its wrong tag" "$WORK/out" \
		"stub gh: refusing attestation verify for $asset, its provenance names another tag"
	rc=0
	cmp -s "$WORK/expected.rb" "$root/Formula/podup.rb" || rc=$?
	check "$asset refusal leaves the formula byte-for-byte intact" "0" "$rc"
done
unset ATTEST_STUB_REFUSE_ASSET

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
