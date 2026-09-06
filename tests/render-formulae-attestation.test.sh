#!/usr/bin/env bash
#
# Build provenance: the renderer must refuse a release whose attestation does
# not name the tag it is rendering. The signature on SHA256SUMS covers the
# checksums and not the version, so last year's binaries re-uploaded under a
# higher tag verify perfectly; the attestation is what binds a binary to its
# tag.
#
# Split from tests/render-formulae.test.sh, which was already at 451 code
# lines against a 300-line soft limit. The fixture both files need lives in
# tests/render-fixture.sh.

set -euo pipefail

HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The linter cannot follow a sourced path built at run time, and the fixture
# is where check() and the counters live. The disable is on the source line
# alone; the counters are re-declared here so nothing downstream has to be
# excused for reading them.
# shellcheck disable=SC1091
. "$HERE_FIXTURE/render-fixture.sh"
pass=0
fail=0

# --- build provenance: attestations must name the tag being rendered --------
#
# SHA256SUMS proves the digests the renderer writes into formulae. It does
# not prove the digests came from THIS release: an actor who can publish a
# release can re-upload last year's binaries with the matching old signed
# SHA256SUMS and have them accepted under a new higher tag. GitHub's SLSA
# attestations bind an artifact to the tag it was built from, so verifying
# one of a release's assets against the tag closes the gap. These cases
# pin the four shapes that must fail closed, plus the two properties
# (digest match, whole-render fail-closed) the requirements call out explicitly.
#
# The gh stub and curl stub serve fixture files from $RELEASES, and the
# stub's attestation branch is steered by ATTEST_STUB_OUTCOME. Each case
# below sets it to the value it needs and unsets it for the next.

# A release whose attestation names the tag the renderer is asking about
# renders normally. This is the new happy path that the whole section
# exists to support.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
unset ATTEST_STUB_OUTCOME
new_root "$WORK/p1"
generator_with "$WORK/p1/scripts/render-formulae.sh" "$PODUP"
rc=0
out="$( cd "$WORK/p1" && "$WORK/p1/scripts/render-formulae.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
check "an attestation naming the rendered tag is accepted" "0" "$rc"
contains "and the asset's real digest reaches the formula" \
	"$WORK/p1/Formula/podup.rb" \
	'sha256 "9c4c120a44c601243afdf38fb1a8f45bc86b1e74121aac78902f1c3f8b489a62"'

# An attestation whose certificate carries a different tag is the
# downgrade attack the function exists to catch.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
export ATTEST_STUB_OUTCOME=wrong-tag
new_root "$WORK/p2"
generator_with "$WORK/p2/scripts/render-formulae.sh" "$PODUP"
rc=0
out="$( cd "$WORK/p2" && "$WORK/p2/scripts/render-formulae.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
unset ATTEST_STUB_OUTCOME
check "an attestation naming a different tag is refused" "3" "$rc"
check "and the message says the artifact was built from another tag" "1" \
	"$(printf '%s' "$out" | grep -c 'the artifact was built from another tag')"
check "and no formula is written from it" "0" \
	"$(find "$WORK/p2/Formula" -name '*.rb' | wc -l)"

# A release predating attestations. The render must still refuse, but the
# message has to say this release carries no attestation rather than
# reporting a failed verification: those are different faults.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
export ATTEST_STUB_OUTCOME=no-attestation
new_root "$WORK/p3"
generator_with "$WORK/p3/scripts/render-formulae.sh" "$PODUP"
rc=0
out="$( cd "$WORK/p3" && "$WORK/p3/scripts/render-formulae.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
unset ATTEST_STUB_OUTCOME
check "a release with no attestation is refused" "3" "$rc"
check "and the message says the release carries no attestation" "1" \
	"$(printf '%s' "$out" | grep -c 'carries no attestation')"
check "and is NOT reported as a wrong-tag attack" "0" \
	"$(printf '%s' "$out" | grep -c 'the artifact was built from another tag')"
check "and no formula is written from it" "0" \
	"$(find "$WORK/p3/Formula" -name '*.rb' | wc -l)"

# An attestation signed by a workflow that is not the release workflow.
# This is a third shape: the digest matches, the tag matches, but the
# provenance claim was not made by the workflow this renderer trusts to
# make it.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
export ATTEST_STUB_OUTCOME=wrong-signer
new_root "$WORK/p4"
generator_with "$WORK/p4/scripts/render-formulae.sh" "$PODUP"
rc=0
out="$( cd "$WORK/p4" && "$WORK/p4/scripts/render-formulae.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
unset ATTEST_STUB_OUTCOME
check "an attestation signed by another workflow is refused" "3" "$rc"
check "and the message names the signer check" "1" \
	"$(printf '%s' "$out" | grep -c 'not signed by the release workflow of')"
check "and no formula is written from it" "0" \
	"$(find "$WORK/p4/Formula" -name '*.rb' | wc -l)"

# A digest that verifies but does not match the entry in SHA256SUMS. The
# requirement calls this out by name: verifying one thing and rendering
# another is a control that inspects nothing, so the renderer must
# compute the download's SHA-256 and compare it against SHA256SUMS
# before either of the attestation outcomes.
#
# Build the manifest and signature normally, then mutate the SHA256SUMS
# entry for the verified asset to something else, and re-sign. The
# signature is still valid, the attestation stub still says ok, but the
# downloaded file's digest disagrees with what the manifest declares.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
{
	# Replace the arm64 entry with a wrong digest; keep the rest intact.
	grep -v 'podup-darwin-arm64$' "$RELEASES/Glyndor__podup/SHA256SUMS"
	printf '%s  podup-darwin-arm64\n' "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0"
} > "$WORK/tmpsums"
resign "$WORK/tmpsums" Glyndor/podup
new_root "$WORK/p5"
generator_with "$WORK/p5/scripts/render-formulae.sh" "$PODUP"
rc=0
out="$( cd "$WORK/p5" && "$WORK/p5/scripts/render-formulae.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
check "a verified attestation whose digest disagrees with SHA256SUMS is refused" "3" "$rc"
check "and the message names the digest mismatch" "1" \
	"$(printf '%s' "$out" | grep -c 'not the .* that SHA256SUMS declares')"
check "and it is NOT reported as a failed attestation" "0" \
	"$(printf '%s' "$out" | grep -c 'attestation verification failed')"
check "and no formula is written from it" "0" \
	"$(find "$WORK/p5/Formula" -name '*.rb' | wc -l)"

# The whole render fails closed on any of the above rather than skipping
# the product and committing partial output. A product whose attestation
# failed verification must leave Formula/ exactly as it was: an existing
# formula stays, no new formula is written, and the script's exit code is
# 3 (skip) so the workflow commit is skipped.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
export ATTEST_STUB_OUTCOME=wrong-tag
new_root "$WORK/p6"
generator_with "$WORK/p6/scripts/render-formulae.sh" "$PODUP"
printf 'PRE-EXISTING-FORMULA\n' > "$WORK/p6/Formula/podup.rb"
rc=0
out="$( cd "$WORK/p6" && "$WORK/p6/scripts/render-formulae.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
unset ATTEST_STUB_OUTCOME
check "the whole render fails closed, not just the asset" "3" "$rc"
check "and the existing formula is left untouched" "PRE-EXISTING-FORMULA" \
	"$(cat "$WORK/p6/Formula/podup.rb")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
