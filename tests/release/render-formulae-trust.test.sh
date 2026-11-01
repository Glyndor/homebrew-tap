#!/usr/bin/env bash
#
# Trust and bounds of render-formulae.sh: asset size caps, key slots, a broken trust anchor and signed-but-malformed manifests.
#
# Part of the render-formulae suite; see render-formulae.test.sh for the harness.
#
# Requires: python3 with cryptography, bash 4+.

set -euo pipefail

HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../fixtures/release" && pwd)"
# The linter cannot follow a sourced path built at run time, and the fixture
# is where check() and the counters live. The disable is on the source line
# alone; the counters are re-declared here so nothing downstream has to be
# excused for reading them.
# shellcheck disable=SC1091
. "$HERE_FIXTURE/render-fixture.sh"
pass=0
fail=0



# Shared setup: the same signed v9.9.9 release rendered once into $WORK/r1, which
# the cases below reuse as their starting tree.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
new_root "$WORK/r1"
generator_with "$WORK/r1/scripts/release/render-formulae.sh" "$PODUP"
run "$WORK/r1/scripts/release/render-formulae.sh" "$WORK/r1" || true

# --- the release assets are attacker-influenced; bound them -----------------
#
# The signature proves what the publisher meant, but it does not bound how
# much of it there is. Whoever can attach an asset to a release decides what
# every hourly run transfers and the embedded python holds in memory, so the
# renderer refuses anything outside the per-file caps below before the python
# opens the file. A size refusal is a third thing and must not be reported as
# either "the trust anchor is malformed" or "their signature does not verify";
# the test pinpoints the third message by name.
#
# The happy path at the top of this file uses a real signed release with a
# real sized signature, so its assertions still hold: a harness that refused
# everything would turn that test red and would never reach these cases.

publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
# Pad the manifest past MAX_SUMS_BYTES (4096). The signature is now stale,
# but the size check fires before the python verifies it, so the signature
# path is never reached and the test stays a pure size test.
# No pipe, no SIGPIPE: `printf 'X\n%.0s' $(seq 1 N)` writes N lines of
# "X\n" without a pipe, so `set -o pipefail` does not kill it when the
# producer finishes.
printf 'a\n%.0s' $(seq 1 5000) > "$RELEASES/Glyndor__podup/SHA256SUMS"
new_root "$WORK/r6b"
generator_with "$WORK/r6b/scripts/release/render-formulae.sh" "$PODUP"
rc=0
out="$( cd "$WORK/r6b" && "$WORK/r6b/scripts/release/render-formulae.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
check "an oversized SHA256SUMS is refused" "3" "$rc"
check "and the message names the size limit" "1" \
	"$(printf '%s' "$out" | grep -c 'over the 4096-byte cap')"
check "and it is NOT reported as a failed signature" "0" \
	"$(printf '%s' "$out" | grep -c 'does not verify against any configured release key')"
check "and it is NOT reported as a malformed key" "0" \
	"$(printf '%s' "$out" | grep -c 'malformed release public key')"
check "and no formula is written" "0" "$(find "$WORK/r6b/Formula" -name '*.rb' | wc -l)"

# A signature that is not 64 bytes is refused at the size check, not at the
# signature check, and the message names the measured size. Two distinct
# sizes prove the check measures exactly and is not satisfied by anything
# larger (or smaller) than 64.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
for sz in 32 128; do
	head -c "$sz" /dev/zero | tr '\0' X > "$RELEASES/Glyndor__podup/SHA256SUMS.sig"
	new_root "$WORK/r6c$sz"
	generator_with "$WORK/r6c$sz/scripts/release/render-formulae.sh" "$PODUP"
	rc=0
	out="$( cd "$WORK/r6c$sz" && "$WORK/r6c$sz/scripts/release/render-formulae.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
	check "a ${sz}-byte signature is refused" "3" "$rc"
	check "and is named by its measured size, not as a bad signature ($sz bytes)" "1" \
		"$(printf '%s' "$out" | grep -c "SHA256SUMS.sig is ${sz} bytes")"
	check "and is NOT reported as a failed signature ($sz bytes)" "0" \
		"$(printf '%s' "$out" | grep -c 'does not verify against any configured release key')"
	check "and is NOT reported as a malformed key ($sz bytes)" "0" \
		"$(printf '%s' "$out" | grep -c 'malformed release public key')"
done

# --- the binary has a cap too -------------------------------------------------
#
# MAX_ASSET_BYTES bounds what the renderer downloads, twice: curl is told
# --max-filesize, which refuses an asset whose announced size is over it, and a
# stat after the download catches a server that announces nothing. The real cap
# is 100 MiB, so these cases lower it in a copy of the generator. The fixture
# assets are "asset-" plus their name: 24 bytes for the arm64 one, 25 for the
# x86_64 one.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
cap_case() { # $1=cap  $2=1 when the server does not announce a size
	local d="$WORK/cap$1${2:-}"
	new_root "$d"
	generator_with "$d/scripts/release/render-formulae.sh" "$PODUP"
	sed -i "s/^MAX_ASSET_BYTES=.*/MAX_ASSET_BYTES=$1/" "$d/scripts/release/render-formulae.sh"
	rc=0
	out="$( cd "$d" && CURL_STUB_IGNORE_MAXFILESIZE="${2:-}" "$d/scripts/release/render-formulae.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
}
cap_case 25
check "an asset exactly at the cap is accepted" "0" "$rc"
cap_case 24
check "an asset one byte over the cap is refused by curl" "3" "$rc"
check "and the refusal is the failed download" "1" "$(printf '%s' "$out" | grep -c 'failed to download')"
cap_case 24 1
check "a server that announces no size is caught by the check after the download" "3" "$rc"
check "and the message names the cap" "1" "$(printf '%s' "$out" | grep -c 'over the 24-byte cap')"
check "and no formula is written from it" "0" "$(find "$WORK/cap241/Formula" -name '*.rb' | wc -l)"

# A clean signed release for this section: the cases above leave a corrupted one.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64

# --- the key is an argument, not an environment variable --------------------

rc=0
( cd "$WORK/r1" && "$WORK/r1/scripts/release/render-formulae.sh" --pubkey ) >/dev/null 2>&1 || rc=$?
check "--pubkey without a value is a usage error" "2" "$rc"
rc=0
( cd "$WORK/r1" && "$WORK/r1/scripts/release/render-formulae.sh" --wat ) >/dev/null 2>&1 || rc=$?
check "an unknown argument is a usage error" "2" "$rc"
rc=0
( cd "$WORK/r1" && RELEASE_PUBKEY_B64="$PUBKEY" "$WORK/r1/scripts/release/render-formulae.sh" ) >/dev/null 2>&1 || rc=$?
check "the environment cannot swap the trust anchor" "3" "$rc"

# --- two key slots, so a rotation can be made-before-break ------------------
#
# The org rotation signs with the old key while both are published, and only
# then switches. A renderer with one slot verifies fine through that first
# phase and starts failing when the second lands -- silently, because the
# channel is pull-based and a failed render just stops updating the tap.

rc=0
( cd "$WORK/r1" && "$WORK/r1/scripts/release/render-formulae.sh" --pubkey2 ) >/dev/null 2>&1 || rc=$?
check "--pubkey2 without a value is a usage error" "2" "$rc"

# The real release is signed with $PUBKEY. Put it in the SECOND slot behind a
# wrong-but-well-formed first key: the render must still succeed, which is the
# whole point of the second slot.
OTHER="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
rc=0
( cd "$WORK/r1" && "$WORK/r1/scripts/release/render-formulae.sh" \
	--pubkey "$OTHER" --pubkey2 "$PUBKEY" ) >/dev/null 2>&1 || rc=$?
check "a release signed by the second key still verifies" "0" "$rc"

# And the reverse: the first slot alone is enough, an empty second changes
# nothing.
rc=0
( cd "$WORK/r1" && "$WORK/r1/scripts/release/render-formulae.sh" --pubkey "$PUBKEY" ) >/dev/null 2>&1 || rc=$?
check "the first key alone still verifies" "0" "$rc"

# Exhausting both slots is an error, not a fallthrough. This is the property
# that must survive: two wrong keys fail exactly as one wrong key did.
rc=0
( cd "$WORK/r1" && "$WORK/r1/scripts/release/render-formulae.sh" \
	--pubkey "$OTHER" --pubkey2 "$OTHER" ) >/dev/null 2>&1 || rc=$?
check "two wrong keys still fail closed" "3" "$rc"

# A clean signed release for this section: the cases above leave a corrupted one.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64

# --- a broken trust anchor is not a bad signature ---------------------------
#
# `except Exception: continue` around the verify call collapsed "this key did
# not sign it" and "this key is not a key" into one message. The operator then
# read "does not verify against any configured release key" and went looking at
# the upstream release for a fault that was in this repository.
#
# The three shapes below are the ones that reach it: not base64 at all, too
# short, and the right alphabet but the wrong length. Each must say the key is
# malformed and say which way.

for bad_case in \
	"AAAA!!!!AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA|Only base64 data is allowed|not base64" \
	"AAAA|3 bytes|too short" \
	"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA|33 bytes|one byte too long"; do
	bad_key="${bad_case%%|*}"; rest="${bad_case#*|}"
	needle="${rest%%|*}"; label="${rest#*|}"
	rc=0
	out="$( cd "$WORK/r1" && "$WORK/r1/scripts/release/render-formulae.sh" \
		--pubkey "$bad_key" 2>&1 )" || rc=$?
	check "a key that is $label is refused" "3" "$rc"
	check "and it is named as malformed, not as a failed signature ($label)" "1" \
		"$(printf '%s' "$out" | grep -c 'malformed release public key')"
	check "and the message says how it is malformed ($label)" "1" \
		"$(printf '%s' "$out" | grep -cF "$needle")"
done

# A key pasted with whitespace on the ends still loads. It arrives here as a
# shell argument, so a value copied from anywhere brings whatever came with it;
# rejecting that as "not base64" would point at the key when the fault is a
# trailing newline. Whitespace INSIDE stays an error: unlike a gpg fingerprint,
# a base64 key has no grouped display convention to accommodate.
rc=0
( cd "$WORK/r1" && "$WORK/r1/scripts/release/render-formulae.sh" \
	--pubkey "  $PUBKEY
" ) >/dev/null 2>&1 || rc=$?
check "a key pasted with whitespace on the ends still verifies" "0" "$rc"

rc=0
out="$( cd "$WORK/r1" && "$WORK/r1/scripts/release/render-formulae.sh" \
	--pubkey "$(printf '%s' "$PUBKEY" | sed 's/^\(..........\)/\1 /')" 2>&1 )" || rc=$?
check "but whitespace inside the key is still refused" "3" "$rc"
check "and it is named as malformed" "1" \
	"$(printf '%s' "$out" | grep -c 'malformed release public key')"

# The mirror image, so the cases above are not satisfied by a renderer that
# calls every key malformed: a well-formed key that simply did not sign this
# release must still be reported as a signature failure, not as a broken key.
rc=0
out="$( cd "$WORK/r1" && "$WORK/r1/scripts/release/render-formulae.sh" \
	--pubkey "$OTHER" 2>&1 )" || rc=$?
check "a well-formed key that did not sign it fails as a signature" "3" "$rc"
check "and is NOT reported as malformed" "0" \
	"$(printf '%s' "$out" | grep -c 'malformed release public key')"
check "and says the signature did not verify" "1" \
	"$(printf '%s' "$out" | grep -c 'does not verify against any configured release key')"

# --- a signed manifest can still be malformed --------------------------------

# A duplicated entry used to render BOTH hashes into one field and exit 0.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-arm64 podup-darwin-x86_64
new_root "$WORK/r9"
generator_with "$WORK/r9/scripts/release/render-formulae.sh" "$PODUP"
rc=0; run "$WORK/r9/scripts/release/render-formulae.sh" "$WORK/r9" || rc=$?
check "an asset listed twice is rejected" "3" "$rc"
contains "and the error says how many times" "$WORK/out" "lists podup-darwin-arm64 2 times"
check "and no formula is written" "0" "$(find "$WORK/r9/Formula" -name '*.rb' | wc -l)"

publish Glyndor/podup v9.9.9 podup-darwin-x86_64
{
	printf 'nothexadecimal!!nothexadecimal!!nothexadecimal!!nothexadecimal!!  podup-darwin-arm64\n'
	cat "$RELEASES/Glyndor__podup/SHA256SUMS"
} > "$WORK/tmpsums"
resign "$WORK/tmpsums" Glyndor/podup
new_root "$WORK/r10"
generator_with "$WORK/r10/scripts/release/render-formulae.sh" "$PODUP"
rc=0; run "$WORK/r10/scripts/release/render-formulae.sh" "$WORK/r10" || rc=$?
check "a non-hexadecimal checksum is rejected" "3" "$rc"
contains "and the error says why" "$WORK/out" "is not hexadecimal"

publish Glyndor/podup v9.9.9 podup-darwin-x86_64
{
	printf 'abcdef  podup-darwin-arm64\n'
	cat "$RELEASES/Glyndor__podup/SHA256SUMS"
} > "$WORK/tmpsums"
resign "$WORK/tmpsums" Glyndor/podup
new_root "$WORK/r11"
generator_with "$WORK/r11/scripts/release/render-formulae.sh" "$PODUP"
rc=0; run "$WORK/r11/scripts/release/render-formulae.sh" "$WORK/r11" || rc=$?
check "a short digest is rejected" "3" "$rc"
contains "and the error gives the length" "$WORK/out" "is 6 characters, not 64"

# The size cap is exact: a signed manifest of exactly MAX_SUMS_BYTES passes the
# size check and goes on to be rendered, one byte more is refused as oversized.
for size in 4096 4097; do
	publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
	cp "$RELEASES/Glyndor__podup/SHA256SUMS" "$WORK/tmpsums"
	pad=$(( size - $(stat -c%s "$WORK/tmpsums") - 64 - 2 - 1 ))
	{
		cat "$WORK/tmpsums"
		printf '%064d  ' 0
		head -c "$pad" /dev/zero | tr '\0' x
		printf '\n'
	} > "$WORK/tmpsums2"
	check "the fixture manifest is exactly $size bytes" "$size" "$(stat -c%s "$WORK/tmpsums2")"
	resign "$WORK/tmpsums2" Glyndor/podup
	new_root "$WORK/cap$size"
	generator_with "$WORK/cap$size/scripts/release/render-formulae.sh" "$PODUP"
	rc=0; run "$WORK/cap$size/scripts/release/render-formulae.sh" "$WORK/cap$size" || rc=$?
	if [ "$size" = 4096 ]; then
		check "a signed manifest of exactly 4096 bytes is accepted" "0" "$rc"
	else
		check "a signed manifest of 4097 bytes is refused" "3" "$rc"
		contains "and is named as over the cap" "$WORK/out" "over the 4096-byte cap"
	fi
done

# An uppercase digest in the signed manifest is well-formed hexadecimal, but the
# renderer compares it with the lowercase sha256sum of the download: it must be
# refused rather than rendered under a digest that was not the one verified.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
awk '{ print toupper($1) "  " $2 }' "$RELEASES/Glyndor__podup/SHA256SUMS" > "$WORK/tmpsums"
resign "$WORK/tmpsums" Glyndor/podup
new_root "$WORK/upper"
generator_with "$WORK/upper/scripts/release/render-formulae.sh" "$PODUP"
rc=0; run "$WORK/upper/scripts/release/render-formulae.sh" "$WORK/upper" || rc=$?
check "an uppercase digest in the manifest is not rendered" "3" "$rc"
contains "and the refusal is the digest comparison" "$WORK/out" "has digest"
check "and no formula is written" "0" "$(find "$WORK/upper/Formula" -name '*.rb' | wc -l)"


echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
