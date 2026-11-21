#!/usr/bin/env bash
#
# The hybrid release signature in scripts/release/release-signature.sh,
# verified for real: an Ed25519 signature and an ML-DSA-65 one over the same
# SHA256SUMS, both required to pass, driven through the renderer that sources
# it. The cases that need no ML-DSA library are in
# tests/release/release-signature.test.sh.
#
# The ML-DSA-65 keys are made here, at run time, and one fixed vector is checked
# as well. tests/fixtures/release/mldsa65/ is a copy, byte for byte, of the
# vector in Glyndor/apt (tests/fixtures/verify-debs/mldsa65/): a public key, a
# message and its ML-DSA-65 signature, made with OpenSSL 3.5.5 (`openssl genpkey
# -algorithm ML-DSA-65`, `openssl pkeyutl -sign -rawin`) and not with the
# library under test. The message is a small .deb there; here it stands as a
# release's SHA256SUMS, so the renderer checks both signatures over it and then
# stops at the listing, which names no asset. A verifier that agrees only with
# itself passes the generated cases and fails that one, and the three verifiers
# agree on the same bytes.
#
# This suite needs cryptography 50.0.2 or later, which the Ubuntu runner's
# python3-cryptography is not. CI runs it in a job of its own, with a virtual
# environment built from scripts/release/render-requirements.txt first on PATH.
# Without the library it fails and says so: a suite that could not run is not a
# pass.
#
# The file is the same in Glyndor/homebrew-tap and Glyndor/scoop-bucket
# (scripts/monitoring/channel-shared-paths.txt).
#
# Requires: python3 with cryptography >= 50.0.2.
set -euo pipefail

if ! python3 -I -c 'from cryptography.hazmat.primitives.asymmetric.mldsa import MLDSA65PrivateKey' 2>/dev/null; then
	echo "FAIL  $(command -v python3) has no cryptography with ML-DSA; install scripts/release/render-requirements.txt into a virtual environment and put it first on PATH"
	echo "0 passed, 1 failed"
	printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" 0 1
	exit 1
fi

HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../fixtures/release" && pwd)"
# shellcheck disable=SC1091
. "$HERE_FIXTURE/render-fixture.sh"
pass=0
fail=0
unset CURL_STUB_IGNORE_MAXFILESIZE CURL_STUB_FAIL CURL_STUB_PQ_STATUS CURL_STUB_PQ_RC

RENDERER="scripts/release/$(basename "$GENERATOR")"
SLUG="$RELEASES/Glyndor__podup"
VECTOR="$HERE_FIXTURE/mldsa65"
ASSETS=()
IFS='|' read -r -a fields <<<"$PODUP"
for field in "${fields[@]}"; do
	case "$field" in podup-*) ASSETS+=("$field") ;; esac
done

said() { if grep -qF -- "$1" "$WORK/out"; then echo 1; else echo 0; fi; }
written() { find "$1" -path "$1/scripts" -prune -o -type f -print | wc -l | tr -d ' '; }
fresh() { R="$WORK/$1"; new_root "$R"; generator_with "$R/$RENDERER" "$PODUP"; }
render() {
	local root="$1"; shift
	rc=0
	( cd "$root" && "$root/$RENDERER" --pubkey "$PUBKEY" "$@" ) > "$WORK/out" 2>&1 || rc=$?
}
release() { publish Glyndor/podup "$1" "${ASSETS[@]}"; }

# Two ML-DSA-65 keys, as seeds, and their public halves as unpadded base64,
# the way the renderer stores them.
python3 -I - "$WORK" <<'PY'
import base64, os, sys
from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric.mldsa import MLDSA65PrivateKey
for name in ("a", "b"):
    seed = os.urandom(32)
    open(os.path.join(sys.argv[1], "pq-%s.seed" % name), "wb").write(seed)
    raw = MLDSA65PrivateKey.from_seed_bytes(seed).public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)
    open(os.path.join(sys.argv[1], "pq-%s.b64" % name), "w").write(base64.b64encode(raw).decode().rstrip("="))
PY
A="$(cat "$WORK/pq-a.b64")"
B="$(cat "$WORK/pq-b.b64")"

# sign <a|b>: the release's second signature, by key a or b, over its SHA256SUMS.
sign() {
	python3 -I - "$WORK/pq-$1.seed" "$SLUG/SHA256SUMS" "$SLUG/SHA256SUMS.mldsa65.sig" <<'PY'
import sys
from cryptography.hazmat.primitives.asymmetric.mldsa import MLDSA65PrivateKey
key = MLDSA65PrivateKey.from_seed_bytes(open(sys.argv[1], "rb").read())
open(sys.argv[3], "wb").write(key.sign(open(sys.argv[2], "rb").read()))
PY
}

# --- row 1: both signatures valid ----------------------------------------------
fresh row1; release v1.0.0; sign a
render "$R" --pq-pubkey "$A"
check "both signatures valid, product not required: admitted" "0 1" "$rc $(written "$R")"
check "and the second signature is reported verified" "1" "$(said 'SHA256SUMS ML-DSA-65 signature verified')"
check "and after the Ed25519 one" "SHA256SUMS signature verified SHA256SUMS ML-DSA-65 signature verified" \
	"$(grep -E '^SHA256SUMS (ML-DSA-65 )?signature verified$' "$WORK/out" | tr '\n' ' ' | sed 's/ $//')"
fresh row1-required; release v1.0.0; sign a
render "$R" --pq-pubkey "$A" --pq-required podup
check "both signatures valid, product required: admitted" "0 1" "$rc $(written "$R")"

# --- row 4: the second signature present and bad -------------------------------
fresh row4; release v1.0.0; sign b
render "$R" --pq-pubkey "$A"
check "a second signature by a key that is not configured is refused" "3 0" "$rc $(written "$R")"
check "and the refusal is the ML-DSA-65 one" "1 0" \
	"$(said 'the ML-DSA-65 signature does not verify against any configured release key') $(said 'ML-DSA-65 signature verified')"
head -c 3309 /dev/urandom > "$SLUG/SHA256SUMS.mldsa65.sig"
render "$R" --pq-pubkey "$A"
check "a second signature of the right length that does not verify is refused" "3 1" \
	"$rc $(said 'the ML-DSA-65 signature does not verify against any configured release key')"

# --- two keys configured: either one may have signed (rotation overlap) --------
fresh rotation; release v1.0.0; sign b
render "$R" --pq-pubkey "$A" --pq-pubkey2 "$B"
check "a signature by the second of two configured keys is admitted" "0 1" "$rc $(written "$R")"
fresh rotation-second; release v1.0.0; sign b
render "$R" --pq-pubkey2 "$B" --pq-required podup
check "and so it is with the key in the second slot alone" "0 1" "$rc $(written "$R")"
fresh rotation-first; release v1.0.0; sign b
render "$R" --pq-pubkey "$A" --pq-required podup
check "and the same signature is refused when only the first key is configured" "3 1" \
	"$rc $(said 'the ML-DSA-65 signature does not verify')"

# --- a required product whose second signature is real and wrong --------------
# The list of required products and a second signature that really is checked
# meet here: the release a forger publishes for a required product carries a
# second signature, and it is one that does not verify. The refusal must be
# that one, and not the refusal for a signature left out.
fresh required-bad; release v1.0.0; sign b
render "$R" --pq-pubkey "$A" --pq-required podup
check "a required product signed by a key that is not configured is refused" "3 0" "$rc $(written "$R")"
check "and the refusal is that it does not verify, not that it is missing" "1 0" \
	"$(said 'the ML-DSA-65 signature does not verify against any configured release key') $(said 'no ML-DSA-65 signature for podup')"
head -c 3309 /dev/urandom > "$SLUG/SHA256SUMS.mldsa65.sig"
render "$R" --pq-pubkey "$A" --pq-required podup
check "a required product whose second signature is 3309 bytes of noise is refused" "3 1 0" \
	"$rc $(said 'the ML-DSA-65 signature does not verify against any configured release key') $(said 'no ML-DSA-65 signature for podup')"
sign a
render "$R" --pq-pubkey "$A" --pq-required podup
check "and the same release signed by the configured key is admitted" "0 1" "$rc $(written "$R")"

# --- a valid second signature of ANOTHER release -------------------------------
# The fixture's SHA256SUMS depends only on the asset names, so the release the
# sidecar is taken from lists one more line: two genuine manifests, each with a
# second signature that verifies for its own bytes. Swapped, it must not: the
# signature binds the manifest's bytes, not the file's name.
release v2.0.0
cp "$SLUG/SHA256SUMS" "$WORK/donor.sums"
printf '%s  podup-extra\n' "$(printf 'asset-podup-extra' | sha256sum | awk '{print $1}')" >> "$WORK/donor.sums"
resign "$WORK/donor.sums" Glyndor/podup; sign a
cp "$SLUG/SHA256SUMS.mldsa65.sig" "$WORK/other-release.sig"
fresh donor
render "$R" --pq-pubkey "$A"
check "the donor release verifies with its own second signature" "0 1" "$rc $(said 'SHA256SUMS ML-DSA-65 signature verified')"
fresh swap; release v1.0.0
cp "$WORK/other-release.sig" "$SLUG/SHA256SUMS.mldsa65.sig"
render "$R" --pq-pubkey "$A"
check "a valid second signature of another release is refused" "3 0" "$rc $(written "$R")"
check "and the refusal is the ML-DSA-65 one" "1" "$(said 'the ML-DSA-65 signature does not verify against any configured release key')"
render "$R" --pq-pubkey "$A" --pq-required podup
check "and so it is for a required product" "3 1 0" \
	"$rc $(said 'the ML-DSA-65 signature does not verify against any configured release key') $(said 'no ML-DSA-65 signature for podup')"

# --- required product, valid second signature, invalid first one --------------
fresh edbad; release v1.0.0; sign a
head -c 64 /dev/zero > "$SLUG/SHA256SUMS.sig"
render "$R" --pq-pubkey "$A" --pq-required podup
check "a valid second signature does not rescue an invalid Ed25519 one" "3 0" "$rc $(written "$R")"
check "and the refusal is the Ed25519 one" "1" "$(said 'SHA256SUMS does not verify against any configured release key')"
check "and the second signature is not checked first" "0" "$(said 'ML-DSA-65 signature verified')"

# --- the fixed vector, made by another implementation --------------------------
fresh vector; release v1.0.0
base64 -d "$VECTOR/vector_1.0_amd64.deb.b64" > "$WORK/vector.msg"
resign "$WORK/vector.msg" Glyndor/podup
base64 -d "$VECTOR/vector_1.0_amd64.deb.mldsa65.sig.b64" > "$SLUG/SHA256SUMS.mldsa65.sig"
VKEY="$(grep -v '^#' "$VECTOR/vector.mldsa65.b64" | tr -d '\n')"
render "$R" --pq-pubkey "$VKEY"
check "the OpenSSL-made ML-DSA-65 vector verifies" "1 0" \
	"$(said 'SHA256SUMS ML-DSA-65 signature verified') $(said 'signatures did not verify')"
check "and the render stops after both signatures, at the listing" "3 0" "$rc $(written "$R")"
python3 -I - "$SLUG/SHA256SUMS.mldsa65.sig" <<'PY'
import sys
p = sys.argv[1]
b = bytearray(open(p, "rb").read())
b[1000] ^= 0x01
open(p, "wb").write(bytes(b))
PY
render "$R" --pq-pubkey "$VKEY"
check "and with one bit of its signature changed it does not" "0 1" \
	"$(said 'SHA256SUMS ML-DSA-65 signature verified') $(said 'the ML-DSA-65 signature does not verify against any configured release key')"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
