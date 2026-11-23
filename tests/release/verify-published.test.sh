#!/usr/bin/env bash
#
# `render-formulae.sh --verify-published` reads the formulae already in Formula/ against the signed SHA256SUMS of the
# release each url names. A render writes only digests it verified, but a formula is a file a person can edit, and
# the digest in it was never read against the signed list again: the digest of an asset nobody signed passes the
# structural gate and the byte comparison alike, because the bytes behind the url really do have that digest.
#
# Each refusal below plants one fault in an otherwise good tree and says which check refused it. The accepted case
# runs first, on the formula the renderer wrote itself, and the faults are applied to a copy of it.
#
# Requires: python3 with cryptography.
set -euo pipefail

HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../fixtures/release" && pwd)"
# shellcheck disable=SC1091
. "$HERE_FIXTURE/render-fixture.sh"
pass=0
fail=0

unset ATTEST_STUB_OUTCOME

SCRIPT_OF() { echo "$1/scripts/release/render-formulae.sh"; }

# verify <root>: the exit status in $rc, the output in $out.
verify() {
	rc=0
	out="$( cd "$1" && "$(SCRIPT_OF "$1")" --pubkey "$PUBKEY" --verify-published 2>&1 )" || rc=$?
}
said() { printf '%s\n' "$out" | grep -cF -- "$1" || true; }
reads() { grep -c -- "$1\$" "$WORK/curl.log" || true; }

MAC="podup-darwin-arm64 podup-darwin-x86_64"
# A tree whose Formula/ the renderer wrote from a published release.
good_tree() { # $1=root
	# shellcheck disable=SC2086 # the asset names are words
	publish Glyndor/podup v9.9.9 $MAC
	new_root "$1"
	generator_with "$(SCRIPT_OF "$1")" "$PODUP"
	run "$(SCRIPT_OF "$1")" "$1"
}
# edit <root> <sed expression over Formula/podup.rb>
edit() { sed -i "$2" "$1/Formula/podup.rb"; }
DIGEST_ARM="$(printf '%s' 'asset-podup-darwin-arm64' | sha256sum | awk '{print $1}')"
DIGEST_X86="$(printf '%s' 'asset-podup-darwin-x86_64' | sha256sum | awk '{print $1}')"

good_tree "$WORK/ok"
check "the renderer wrote the formula the cases start from" "1" "$(grep -c "$DIGEST_ARM" "$WORK/ok/Formula/podup.rb")"
verify "$WORK/ok"
check "a formula whose digests are the signed ones is accepted" "0" "$rc"
check "and says how many digests it read" "1" "$(said 'verified 2 published digest(s)')"

# The two assets name one release, so it is read once: SHA256SUMS, its signature and the second signature are three
# transfers, not six.
rm -f "$WORK/curl.log"
CURL_STUB_LOG="$WORK/curl.log" verify "$WORK/ok"
check "two assets of one release are accepted" "0" "$rc"
check "and SHA256SUMS of the release was fetched once" "1" "$(reads '/SHA256SUMS')"
check "and its Ed25519 signature was fetched once" "1" "$(reads '/SHA256SUMS.sig')"
check "and its second signature was asked for once" "1" "$(reads '/SHA256SUMS.mldsa65.sig')"
check "and nothing else was fetched but the two assets, which the attestation is verified over" "5" "$(wc -l < "$WORK/curl.log")"

# --- a digest that is not the signed one ------------------------------------
good_tree "$WORK/digest"
edit "$WORK/digest" "s/$DIGEST_ARM/$(printf 'e%.0s' {1..64})/"
verify "$WORK/digest"
check "a digest that is not the signed one is refused" "1" "$rc"
check "and the refusal names the signed one" "1" "$(said "but the signed SHA256SUMS of Glyndor/podup v9.9.9 gives $DIGEST_ARM for podup-darwin-arm64")"
check "and the asset that was not edited is not reported" "0" "$(said 'for podup-darwin-x86_64')"

# The second asset reads the list the first one verified, and its own digest is still compared with it.
good_tree "$WORK/digest-second"
edit "$WORK/digest-second" "s/$DIGEST_X86/$(printf 'd%.0s' {1..64})/"
verify "$WORK/digest-second"
check "a digest of the asset that reads the list again is refused" "1" "$rc"
check "and the refusal names the signed one for that asset" "1" "$(said "gives $DIGEST_X86 for podup-darwin-x86_64")"
check "and the asset that was not edited is not reported" "0" "$(said 'for podup-darwin-arm64')"

# --- an asset the signed list does not carry ---------------------------------
# The release holds one more file, with a digest of its own that is the digest of its bytes, and the formula points at
# it. Every local check and the byte comparison agree with that formula; the signed list does not carry the file.
good_tree "$WORK/extra"
extra_digest="$(printf 'asset-evil' | sha256sum | awk '{print $1}')"
edit "$WORK/extra" "s|podup-darwin-arm64\"|evil\"|; s/$DIGEST_ARM/$extra_digest/"
printf 'asset-evil' > "$RELEASES/Glyndor__podup/asset_evil"
verify "$WORK/extra"
check "an asset the signed list does not carry is refused" "1" "$rc"
check "and the refusal says the signed list does not list it" "1" "$(said 'downloads evil, which the signed SHA256SUMS of Glyndor/podup v9.9.9 does not list once')"

# --- a list whose signature does not verify ---------------------------------------
good_tree "$WORK/forged"
# Every digest the formula declares is still in the list, so only the signature is wrong.
printf '%s  unrelated\n' "$DIGEST_ARM" >> "$RELEASES/Glyndor__podup/SHA256SUMS"
rm -f "$WORK/curl.log"
CURL_STUB_LOG="$WORK/curl.log" verify "$WORK/forged"
check "a SHA256SUMS whose signature does not verify is refused" "1" "$rc"
check "and the refusal is the signature's, not the digest's" "0" "$(said 'but the signed SHA256SUMS')"
check "and the verifier read the refused release once" "3" "$(wc -l < "$WORK/curl.log")"
check "and it counts as a failure for the first asset" "1" "$(said 'podup-darwin-arm64 names Glyndor/podup v9.9.9, whose release was not admitted')"
check "and for the second" "1" "$(said 'podup-darwin-x86_64 names Glyndor/podup v9.9.9, whose release was not admitted')"
check "and both digests are counted as not verified" "1" "$(said '2 of 2 published digest(s) are not the ones')"
check "and no digest was reported as verified" "0" "$(said 'verified 2')"

# --- a signed list republished under another tag -------------------------------------
# The attack the signature does not cover: an old SHA256SUMS, with its valid signature and its binaries, published again
# under a new tag. Every digest of the formula is in the signed list, so the digest comparison accepts it; the attestation
# of the binary names the old tag, and that is what refuses it.
good_tree "$WORK/replay"
ATTEST_STUB_OUTCOME=wrong-tag verify "$WORK/replay"
check "a signed list republished under another tag is refused" "1" "$rc"
check "and the refusal is the provenance's, not the digest's" "0" "$(said 'but the signed SHA256SUMS')"
check "and says the provenance names another tag" "1" "$(said 'the build provenance of podup-darwin-arm64 is missing, names another tag than v9.9.9')"
check "and the second asset is refused as well" "1" "$(said 'the build provenance of podup-darwin-x86_64 is missing')"
check "and both are counted as not verified" "1" "$(said '2 of 2 published digest(s) are not the ones')"
good_tree "$WORK/replay-one"
ATTEST_STUB_REFUSE_ASSET=podup-darwin-x86_64 verify "$WORK/replay-one"
check "one asset whose provenance names another tag refuses the release even when the other is genuine" "1" "$rc"
check "and only that asset is named" "1" "$(said 'the build provenance of podup-darwin-x86_64')"
check "and the genuine one is not" "0" "$(said 'the build provenance of podup-darwin-arm64')"
for outcome in no-attestation wrong-signer empty-list; do
	good_tree "$WORK/replay-$outcome"
	ATTEST_STUB_OUTCOME=$outcome verify "$WORK/replay-$outcome"
	check "an attestation that is $outcome refuses the release" "1" "$rc"
done
# The attestation is asked for every asset, pinned to the tag by the stub itself (it refuses a verify that lacks --source-ref
# refs/tags/<tag> or the signer workflow of the repository), so a good tree being accepted shows both pins are passed.
good_tree "$WORK/asked"
rm -f "$WORK/attest.log"
ATTEST_STUB_LOG="$WORK/attest.log" verify "$WORK/asked"
check "the attestation is asked once for each asset" "2" "$(wc -l < "$WORK/attest.log")"
check "and a good tree is accepted with both pins in place" "0" "$rc"
# A digest that is not the signed one is refused before any attestation is asked for.
good_tree "$WORK/digest-first"
edit "$WORK/digest-first" "s/$DIGEST_ARM/$(printf 'c%.0s' {1..64})/"
rm -f "$WORK/attest.log"
ATTEST_STUB_LOG="$WORK/attest.log" verify "$WORK/digest-first"
check "an asset whose digest is not the signed one is not asked about" "1" "$(wc -l < "$WORK/attest.log")"

# --- a url outside the product's repository -----------------------------------------
good_tree "$WORK/other-repo"
edit "$WORK/other-repo" '0,/url "https:\/\/github.com\/Glyndor\/podup/s//url "https:\/\/github.com\/Glyndor\/other/'
verify "$WORK/other-repo"
check "a url that names another repository is refused" "1" "$rc"
check "and the refusal says it is not an asset of the product's repository" "1" "$(said 'is not an asset of Glyndor/podup')"

# --- a url that is not one asset of one release -------------------------------------
good_tree "$WORK/nested"
edit "$WORK/nested" '0,/podup-darwin-arm64"/s//sub\/podup-darwin-arm64"/'
verify "$WORK/nested"
check "a url with a folder after the tag is refused" "1" "$rc"
check "and says it is not one asset of one release" "1" "$(said 'is not one asset of one release')"

# --- a formula of no product, and a tap of none ---------------------------------------
good_tree "$WORK/stranger"
cp "$WORK/stranger/Formula/podup.rb" "$WORK/stranger/Formula/other.rb"
verify "$WORK/stranger"
check "a formula the PRODUCTS table has no row for is refused" "1" "$rc"
check "and the refusal names the missing row" "1" "$(said 'has no row for "other"')"

good_tree "$WORK/empty"
rm "$WORK/empty/Formula/podup.rb"
verify "$WORK/empty"
check "a tap with no formula is not a pass" "1" "$rc"
check "and says that nothing was read" "1" "$(said 'no digest was read against a signed release')"

good_tree "$WORK/nodigest"
edit "$WORK/nodigest" '/sha256 "/d'
verify "$WORK/nodigest"
check "a url with no digest after it is refused" "1" "$rc"

# --- nothing is rendered ----------------------------------------------------------------
good_tree "$WORK/readonly"
before="$(find "$WORK/readonly/Formula" -type f -exec sha256sum {} + | sort)"
verify "$WORK/readonly"
check "the verification of a good tree succeeds" "0" "$rc"
check "and writes nothing under Formula/" "$before" "$(find "$WORK/readonly/Formula" -type f -exec sha256sum {} + | sort)"
check "and renders nothing" "0" "$(said 'rendered Formula/')"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
