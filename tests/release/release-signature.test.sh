#!/usr/bin/env bash
#
# The release signature check in scripts/release/release-signature.sh, the half
# that needs no ML-DSA library, driven through the renderer that sources it:
# which second signature is required, which one is refused before any
# cryptography runs, how its download is read, the configuration guard, the
# verifier's own check of each key behind that guard, the trust constants that
# nothing may change once the arguments are read, and the refusal when the
# library cannot verify one. The cases that verify a real
# ML-DSA-65 signature are in
# tests/release/release-signature/release-signature-mldsa.test.sh, which needs
# cryptography 50.0.2.
#
# Every refusal asserts its reason and not only the exit status, and every
# fixture is valid in every respect except the one under test: the Ed25519
# signature verifies, an ML-DSA-65 public key is 1952 bytes of valid base64 and
# a second signature is 3309 bytes, so the check that refuses is the one the
# case names. Where a case would reach the ML-DSA library, the library is
# blocked, so it means the same on a machine that has ML-DSA and on one that
# does not.
#
# The file is the same in Glyndor/homebrew-tap and Glyndor/scoop-bucket
# (scripts/monitoring/channel-shared-paths.txt). What differs between the two,
# the renderer, the product row and the folder it writes to, comes from the
# render fixture.
#
# Requires: python3 with the `cryptography` module.
set -euo pipefail

HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../fixtures/release" && pwd)"
# shellcheck disable=SC1091
. "$HERE_FIXTURE/render-fixture.sh"
pass=0
fail=0
unset CURL_STUB_IGNORE_MAXFILESIZE CURL_STUB_FAIL CURL_STUB_PQ_STATUS CURL_STUB_PQ_RC

RENDERER="scripts/release/$(basename "$GENERATOR")"
SLUG="$RELEASES/Glyndor__podup"
# The second product of a two-product roster: the same row under another name.
OTHER="${PODUP//podup/other}"
ASSETS=()
OTHER_ASSETS=()
IFS='|' read -r -a fields <<<"$PODUP"
for field in "${fields[@]}"; do
	case "$field" in
		podup-*) ASSETS+=("$field"); OTHER_ASSETS+=("${field//podup/other}") ;;
	esac
done

# said <text>: 1 when the last run printed it, 0 when it did not.
# shellcheck disable=SC2153 # WORK is the fixture's folder; work is the sourced file's
said() { if grep -qF -- "$1" "$WORK/out"; then echo 1; else echo 0; fi; }
# written <root>: the files the renderer wrote, anything outside scripts/.
written() { find "$1" -path "$1/scripts" -prune -o -type f -print | wc -l | tr -d ' '; }
# fresh <name> [rows...]: a new root at $R whose renderer carries the rows.
fresh() {
	R="$WORK/$1"; shift
	[ $# -gt 0 ] || set -- "$PODUP"
	new_root "$R"
	generator_with "$R/$RENDERER" "$@"
}
# render <root> [arguments...]: run that root's renderer with the fixture's
# Ed25519 key; rc is its exit status and $WORK/out what it printed. BLOCK
# names a sitecustomize to load and WRAP a folder put first on PATH.
render() {
	local root="$1"; shift
	rc=0
	(
		cd "$root"
		if [ -n "${BLOCK:-}" ]; then export PYTHONPATH="$WORK/$BLOCK"; fi
		if [ -n "${WRAP:-}" ]; then PATH="$WORK/$WRAP:$PATH"; fi
		"$root/$RENDERER" --pubkey "$PUBKEY" "$@"
	) > "$WORK/out" 2>&1 || rc=$?
}
release() { publish Glyndor/podup v1.0.0 "${ASSETS[@]}"; }
sidecar() { head -c "$1" /dev/urandom > "$SLUG/SHA256SUMS.mldsa65.sig"; }

# Stand-in ML-DSA-65 public keys: 1952 random bytes are a well-formed key, which
# is all the checks here read. KEY is padded base64 and SHORT is one byte short.
read -r KEY SHORT < <(python3 -I -c '
import base64, os
print(base64.b64encode(os.urandom(1952)).decode(), base64.b64encode(os.urandom(1951)).decode())')
STRAY="${KEY:0:40}!${KEY:41}"

# The library blocked two ways: the module missing, as in the runner's
# python3-cryptography, and the module present on an OpenSSL without ML-DSA,
# which refuses the key at load.
mkdir -p "$WORK/no-mldsa" "$WORK/unsupported"
cat > "$WORK/no-mldsa/sitecustomize.py" <<'PY'
import sys
class Block:
    def find_spec(self, name, path=None, target=None):
        if name == "cryptography.hazmat.primitives.asymmetric.mldsa":
            raise ModuleNotFoundError("No module named " + repr(name))
sys.meta_path.insert(0, Block())
PY
cat > "$WORK/unsupported/sitecustomize.py" <<'PY'
import importlib.abc, importlib.machinery, sys
NAME = "cryptography.hazmat.primitives.asymmetric.mldsa"
class Loader(importlib.abc.Loader):
    def create_module(self, spec):
        return None
    def exec_module(self, module):
        from cryptography.exceptions import UnsupportedAlgorithm
        class MLDSA65PublicKey:
            @classmethod
            def from_public_bytes(cls, data):
                raise UnsupportedAlgorithm("ML-DSA-65 is not supported by this backend")
        module.MLDSA65PublicKey = MLDSA65PublicKey
class Finder(importlib.abc.MetaPathFinder):
    def find_spec(self, name, path=None, target=None):
        return importlib.machinery.ModuleSpec(name, Loader()) if name == NAME else None
sys.meta_path.insert(0, Finder())
PY

# --- row 2: no second signature, product not required: admitted, as before ----
fresh row2; release
render "$R"
check "no second signature and no key or list is admitted" "0 1" "$rc $(written "$R")"
check "and nothing about a second signature is said" "0" "$(said ML-DSA-65)"
fresh row2-key; release
render "$R" --pq-pubkey "$KEY"
check "with a key configured, a release without a second signature is still admitted" "0 1" "$rc $(written "$R")"
CURL_STUB_PQ_STATUS=404 render "$R" --pq-pubkey "$KEY"
check "a 404 for the second signature is an answer: the release carries none" "0" "$rc"
fresh row2-other "$PODUP" "$OTHER"; release; publish Glyndor/other v1.0.0 "${OTHER_ASSETS[@]}"
render "$R" --pq-pubkey "$KEY" --pq-required other
check "with another product required, this one is admitted without one" "0" "$(said 'podup requires')"
check "and the other one is refused for it" "1" "$(said 'no ML-DSA-65 signature for other; other requires the hybrid release signature')"
check "so exactly one product is rendered" "3 1" "$rc $(written "$R")"

# --- row 3: no second signature, product required: refused for that -----------
fresh row3; release
render "$R" --pq-pubkey "$KEY" --pq-required podup
check "a required product without its second signature is refused" "3 0" "$rc $(written "$R")"
check "and the refusal says the signature is missing" "1" "$(said 'no ML-DSA-65 signature for podup')"
check "and names the product that requires it" "1" "$(said 'podup requires the hybrid release signature')"
render "$R" --pq-pubkey "$KEY" --pq-required '  podup  '
check "a name padded with blanks is still a name" "3 1" \
	"$rc $(said 'podup requires the hybrid release signature')"

# --- row 5: a second signature and no ML-DSA-65 key configured ------------------
fresh row5; release; sidecar 3309
render "$R"
check "a second signature with no key configured is refused, not skipped" "3 0" "$rc $(written "$R")"
check "and the refusal says no key is configured" "1" "$(said 'no ML-DSA-65 release public key is configured')"

# --- row 6: the Ed25519 signature decides first --------------------------------
fresh row6; release; sidecar 3309
printf 'x' >> "$SLUG/SHA256SUMS"
BLOCK=no-mldsa render "$R" --pq-pubkey "$KEY" --pq-required podup
check "an invalid Ed25519 signature is refused beside a second one" "3 0" "$rc $(written "$R")"
check "and the refusal is the Ed25519 one" "1" "$(said 'SHA256SUMS does not verify against any configured release key')"
check "and the second signature is never reached" "0" "$(said ML-DSA-65)"
release; sidecar 3309; rm "$SLUG/SHA256SUMS.sig"
BLOCK=no-mldsa render "$R" --pq-pubkey "$KEY" --pq-required podup
check "a missing Ed25519 signature is refused beside a second one" "3 1 0" \
	"$rc $(said 'failed to download SHA256SUMS.sig') $(said ML-DSA-65)"

# --- the second signature's length and size, before any cryptography ----------
fresh length; release
for bytes in 3308 3310; do
	sidecar "$bytes"
	BLOCK=no-mldsa render "$R" --pq-pubkey "$KEY"
	check "a $bytes-byte second signature is refused for its length" "3 0 1" \
		"$rc $(written "$R") $(said "SHA256SUMS.mldsa65.sig is $bytes bytes; an ML-DSA-65 signature is exactly 3309 bytes")"
done
sidecar 3309
BLOCK=no-mldsa render "$R" --pq-pubkey "$KEY"
check "and one of 3309 bytes passes the length check and reaches the library" "0 1" \
	"$(said 'exactly 3309 bytes') $(said 'the installed cryptography cannot verify ML-DSA-65')"
sidecar 5000
BLOCK=no-mldsa render "$R" --pq-pubkey "$KEY"
check "a second signature over the cap is refused by the bounded transfer" "3 1" \
	"$rc $(said 'failed to download SHA256SUMS.mldsa65.sig within the 4096-byte cap')"
CURL_STUB_IGNORE_MAXFILESIZE=1 BLOCK=no-mldsa render "$R" --pq-pubkey "$KEY"
check "and by the size on disk when the server does not announce it" "3 1" \
	"$rc $(said 'SHA256SUMS.mldsa65.sig is 5000 bytes, over the 4096-byte cap')"
sidecar 4096
BLOCK=no-mldsa render "$R" --pq-pubkey "$KEY"
check "one of exactly 4096 bytes is within the cap and refused for its length" "0 1" \
	"$(said 'within the 4096-byte cap') $(said 'is 4096 bytes; an ML-DSA-65 signature is exactly 3309 bytes')"

# --- a read that failed is not a release without a second signature -----------
fresh status; release
for code in 500 503 403; do
	CURL_STUB_PQ_STATUS="$code" render "$R" --pq-pubkey "$KEY"
	check "an HTTP $code for the second signature is refused, not read as absent" "3 0 1" \
		"$rc $(written "$R") $(said "the download of SHA256SUMS.mldsa65.sig answered HTTP $code")"
done
CURL_STUB_PQ_STATUS=000 CURL_STUB_PQ_RC=7 render "$R" --pq-pubkey "$KEY"
check "a transfer that never connected is refused" "3 1" \
	"$rc $(said 'failed to download SHA256SUMS.mldsa65.sig within the 4096-byte cap')"
sidecar 3309
CURL_STUB_PQ_STATUS=200 CURL_STUB_PQ_RC=18 BLOCK=no-mldsa render "$R" --pq-pubkey "$KEY"
check "a 200 whose transfer broke is refused, even when the bytes look whole" "3 0 1" \
	"$rc $(written "$R") $(said 'failed to download SHA256SUMS.mldsa65.sig within the 4096-byte cap')"

# A 404 is an answer only when the transfer that carried it finished. curl exits 0
# for any status it was given without `-f`, so a non-zero exit with a 404 is a
# transfer that broke, and nothing about the release.
fresh status-404; release
CURL_STUB_PQ_STATUS=404 CURL_STUB_PQ_RC=18 render "$R" --pq-pubkey "$KEY"
check "a 404 whose transfer broke is refused, not read as a release without a second signature" "3 0 1 1" \
	"$rc $(written "$R") $(said 'failed to download SHA256SUMS.mldsa65.sig within the 4096-byte cap') $(said 'could not be decided')"
check "and the refusal says what it saw" "1 1" "$(said 'HTTP 404') $(said 'transfer status 18')"
CURL_STUB_PQ_STATUS=404 render "$R" --pq-pubkey "$KEY"
check "while a clean 404 on the same release is an answer, and the release is admitted" "0 1" "$rc $(written "$R")"

# --- the library cannot verify ML-DSA-65: refused, and the reason is said -------
fresh nolib; release; sidecar 3309
for block in no-mldsa unsupported; do
	BLOCK="$block" render "$R" --pq-pubkey "$KEY"
	check "a library that cannot verify ML-DSA-65 ($block) refuses the release" "3 0" "$rc $(written "$R")"
	check "and the reason is the library ($block)" "1 1" \
		"$(said 'the installed cryptography cannot verify ML-DSA-65; the second signature is refused rather than skipped') $(said 'cryptography 50.0.2 or later is required')"
done
rm "$SLUG/SHA256SUMS.mldsa65.sig"
BLOCK=no-mldsa render "$R" --pq-pubkey "$KEY"
check "and without a second signature the same machine admits the release" "0 1" "$rc $(written "$R")"

# --- a verifier that ends without a verdict refuses ----------------------------
# A python3 that is killed on the signature check, and only there: the release
# carries a tampered SHA256SUMS, so anything but a refusal is a release admitted
# with no signature checked.
REAL_PYTHON="$(command -v python3)"
mkdir -p "$WORK/py-killed"
# shellcheck disable=SC2016 # the wrapper reads these when it runs
printf '#!/usr/bin/env bash\ncase "${2:-}" in */SHA256SUMS) kill -KILL $$ ;; esac\nexec %s "$@"\n' \
	"$REAL_PYTHON" > "$WORK/py-killed/python3"
chmod +x "$WORK/py-killed/python3"
fresh killed; release; printf 'x' >> "$SLUG/SHA256SUMS"
WRAP=py-killed render "$R"
check "a verifier killed before its verdict refuses the release" "3 0" "$rc $(written "$R")"
check "and says it stopped without a verdict" "1" \
	"$(said 'the signature check stopped with status 137 before reaching a verdict')"

# Only the four statuses the verifier defines are verdicts: 0 admitted, 1 the
# release is not trusted, 2 our own key is malformed, 3 the library cannot check
# the second signature. Every other one is refused, and the release here is
# valid, so a status that reached the `case` unrefused would admit it: a
# verifier that exits with 4, the first number past the list, or with the 126 and
# 127 a shell gives for a program it cannot run, has reached no verdict.
for status in 4 99 126 127; do
	mkdir -p "$WORK/py-status-$status"
	# shellcheck disable=SC2016 # the wrapper reads these when it runs
	printf '#!/usr/bin/env bash\ncase "${2:-}" in */SHA256SUMS) exit %s ;; esac\nexec %s "$@"\n' \
		"$status" "$REAL_PYTHON" > "$WORK/py-status-$status/python3"
	chmod +x "$WORK/py-status-$status/python3"
	fresh "status-$status"; release
	WRAP="py-status-$status" render "$R"
	check "a verifier that exits with $status, which is no verdict, refuses the release" "3 0 1" \
		"$rc $(written "$R") $(said "the signature check stopped with status $status before reaching a verdict")"
done
fresh verdicts; release
render "$R"
check "and the same release, with the real verifier, is admitted" "0 1" "$rc $(written "$R")"

# --- our own configuration, checked before any release is read ----------------
fresh guard "$PODUP" "$OTHER"; release
guard() { # <description> <message> <arguments...>
	local what="$1" message="$2"; shift 2
	render "$R" "$@"
	check "$what" "2 1 0 0" "$rc $(said "$message") $(said 'SHA256SUMS signature verified') $(written "$R")"
}
guard "a key with a character outside base64 stops the run" \
	"the ML-DSA-65 release public key is not valid base64" --pq-pubkey "$STRAY"
guard "a key of a length no base64 string has stops the run" \
	"the ML-DSA-65 release public key is not a base64 string of whole bytes" --pq-pubkey "${KEY}A"
guard "a 1951-byte key stops the run" \
	"the ML-DSA-65 release public key is 1951 bytes, not the 1952 bytes" --pq-pubkey "$SHORT"
guard "a bad key in the second slot stops the run too" \
	"the ML-DSA-65 release public key is 1951 bytes" --pq-pubkey "$KEY" --pq-pubkey2 "$SHORT"
split="${KEY:0:500}"$'\n'"${KEY:500:500}"$'\n'"${KEY:1000:500}"$'\n'"${KEY:1500:500}"$'\n'"${KEY:2000}"
guard "a key broken over lines stops the run, though it decodes to 1952 bytes" \
	"the ML-DSA-65 release public key contains whitespace" --pq-pubkey "$split"
guard "a key with a trailing blank stops the run" \
	"the ML-DSA-65 release public key contains whitespace" --pq-pubkey "$KEY "
for entry in 'Podup' 'pod up' 'podup,other' '-podup' 'p' 'podup #'; do
	guard "the required entry '$entry' stops the run" "which is not a product of this repository" \
		--pq-pubkey "$KEY" --pq-required "$entry"
done
guard "a required list on two lines stops the run" \
	"the required-products list spans more than one line" --pq-pubkey "$KEY" --pq-required "podup"$'\n'"other"
render "$R" --pq-required podup
check "a required product with no ML-DSA-65 key configured stops the run" "2 1 0 0" \
	"$rc $(said 'the required-products list names podup, and no ML-DSA-65 release public key is configured') $(said 'SHA256SUMS signature verified') $(written "$R")"
guard "and so does one named with blanks around it" \
	"the required-products list names podup, and no ML-DSA-65 release public key is configured" --pq-required '  podup  '
render "$R" --pq-pubkey2 "$KEY" --pq-required podup
check "a key in the second slot alone is a key configured for the list" "3 1 0" \
	"$rc $(said 'no ML-DSA-65 signature for podup') $(said 'no ML-DSA-65 release public key is configured')"
render "$R" --pq-pubkey "$KEY"
check "and a key with an empty list, the state between the two steps, starts and admits" "0 1" \
	"$rc $(said 'SHA256SUMS signature verified')"
check "and the stop is a configuration error, not a tampered release" "0" "$(said 'release was not admitted')"
# That run was admitted and wrote its files, and the cases after it count what a
# refused run leaves behind, so they start from a root nothing was written to.
fresh guard-refused "$PODUP" "$OTHER"; release

# The Ed25519 slots are held to the same check. A malformed one used to reach the
# verifier, which refused every release in turn as if each were bad.
read -r ED_SHORT < <(python3 -I -c '
import base64, sys
k = sys.argv[1] + "=" * (-len(sys.argv[1]) % 4)
print(base64.b64encode(base64.b64decode(k)[:31]).decode().rstrip("="))' "$PUBKEY")
ED_STRAY="${PUBKEY:0:10}!!!!${PUBKEY:10}"
guard "an Ed25519 key with characters outside base64 stops the run" \
	"the Ed25519 release public key is not valid base64" --pubkey "$ED_STRAY"
guard "a 31-byte Ed25519 key stops the run" \
	"the Ed25519 release public key is 31 bytes, not the 32 bytes" --pubkey "$ED_SHORT"
guard "a bad Ed25519 key in the second slot stops the run too" \
	"the Ed25519 release public key is 31 bytes" --pubkey2 "$ED_SHORT"
guard "whitespace inside an Ed25519 key stops the run" \
	"the Ed25519 release public key contains whitespace" --pubkey "${PUBKEY:0:20} ${PUBKEY:20}"
guard "no Ed25519 key at all stops the run" \
	"no Ed25519 release public key is configured" --pubkey ""
render "$R" --pubkey "  $PUBKEY  "
check "and an Ed25519 key with blanks on its ends is read as the key" "0 1" "$rc $(said 'SHA256SUMS signature verified')"

# --- the verifier's own check of each key, behind the configuration guard ------
# The guard refuses a malformed key before any release is read, so a run of the
# renderer never reaches the check the verifier makes again when it loads a key.
# That check is the second net, and a net nothing reaches is one nobody notices
# gone: these cases source the file on its own and call verify_sha256sums without
# the guard, the way a renderer that lost its call to the guard would. The
# values are the renderer's.
# shellcheck disable=SC2034 # every name is read by the sourced release-signature.sh
verify_alone() { # <Ed25519 key> <ML-DSA-65 key>; rc and $WORK/out as render
	local blocked=""
	if [ -n "${BLOCK:-}" ]; then blocked="$WORK/$BLOCK"; fi
	rc=0
	(
		RELEASE_PUBKEY_B64="$1" RELEASE_PUBKEY2_B64="" RELEASE_PQ_REQUIRED=""
		RELEASE_PQ_PUBKEY_B64="$2" RELEASE_PQ_PUBKEY2_B64=""
		MAX_SUMS_BYTES=4096 MAX_SIG_BYTES=64 MAX_PQ_SIG_BYTES=4096 PQ_SIG_LENGTH=3309
		PRODUCTS=("$PODUP")
		work="$(mktemp -d "$WORK/alone.XXXXXX")"
		# shellcheck disable=SC1091 # the file under test, beside the renderer
		. "$HERE/scripts/release/release-signature.sh"
		PYTHONPATH="$blocked" verify_sha256sums Glyndor/podup v1.0.0 podup
	) > "$WORK/out" 2>&1 || rc=$?
}
KEYU="${KEY%%=*}"
release
verify_alone "$PUBKEY" ""
check "on its own, the verifier admits a release signed by the key it is given" "0 1" "$rc $(said 'SHA256SUMS signature verified')"
verify_alone "$ED_STRAY" ""
check "and refuses an Ed25519 key with characters outside base64, not reading it shorter" "1 1 0" \
	"$rc $(said 'malformed release public key: Only base64 data is allowed') $(said 'SHA256SUMS signature verified')"
verify_alone "$ED_SHORT" ""
check "and refuses a 31-byte Ed25519 key for its length" "1 1" \
	"$rc $(said 'malformed release public key: 31 bytes, not a 32-byte Ed25519 key')"
sidecar 3309
BLOCK=no-mldsa verify_alone "$PUBKEY" "$KEYU"
check "a well-formed ML-DSA-65 key passes its own check and reaches the library" "1 1 0" \
	"$rc $(said 'the installed cryptography cannot verify ML-DSA-65') $(said 'malformed ML-DSA-65')"
BLOCK=no-mldsa verify_alone "$PUBKEY" "${KEYU:0:10}!!!!${KEYU:10}"
check "and one with characters outside base64 is refused, not read shorter" "1 1 0" \
	"$rc $(said 'malformed ML-DSA-65 release public key: Only base64 data is allowed') $(said 'cannot verify ML-DSA-65')"
BLOCK=no-mldsa verify_alone "$PUBKEY" "$SHORT"
check "and a 1951-byte one is refused for its length" "1 1 0" \
	"$rc $(said 'malformed ML-DSA-65 release public key: 1951 bytes, not a 1952-byte ML-DSA-65 public key') $(said 'cannot verify ML-DSA-65')"

# --- the trust constants are fixed once the arguments are read -----------------
# The renderer declares the constants read-only after its arguments, so nothing
# later in it, or in the file it sources, can change what it trusts or how much
# it reads. An assignment planted after that point has to stop the run, one
# constant at a time.
fresh fixed; release
for name in RELEASE_PUBKEY_B64 RELEASE_PUBKEY2_B64 RELEASE_PQ_PUBKEY_B64 RELEASE_PQ_PUBKEY2_B64 \
	RELEASE_PQ_REQUIRED MAX_SUMS_BYTES MAX_SIG_BYTES MAX_PQ_SIG_BYTES PQ_SIG_LENGTH; do
	generator_with "$R/$RENDERER" "$PODUP"
	sed -i "/^PRODUCTS=(/i $name=\"\"" "$R/$RENDERER"
	# bash words the refusal in the language of the locale.
	LC_ALL=C render "$R"
	check "an assignment to $name after the arguments stops the run" "1 1 0" \
		"$rc $(said "$name: readonly variable") $(written "$R")"
done
generator_with "$R/$RENDERER" "$PODUP"
render "$R"
check "and the same renderer without it renders" "0 1" "$rc $(written "$R")"

# --- the committed constants ---------------------------------------------------
committed() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "$HERE/$RENDERER"; }
if [ -z "$(committed RELEASE_PQ_REQUIRED)" ] || [ -n "$(committed RELEASE_PQ_PUBKEY_B64)$(committed RELEASE_PQ_PUBKEY2_B64)" ]; then
	check "no product is required before an ML-DSA-65 key is committed" "1" "1"
else
	check "no product is required before an ML-DSA-65 key is committed" "a key" "none, and $(committed RELEASE_PQ_REQUIRED) is required"
fi
fresh committed; release
if [ -n "$(committed RELEASE_PQ_REQUIRED)" ]; then
	echo "not run - the committed renderer admits a release without a second signature (a product is required now)"
else
	render "$R"
	check "the committed renderer admits a release without a second signature" "0 1" "$rc $(written "$R")"
fi
if [ -n "$(committed RELEASE_PQ_PUBKEY_B64)$(committed RELEASE_PQ_PUBKEY2_B64)" ]; then
	echo "not run - the committed renderer refuses a second signature for want of a key (it holds one now)"
else
	sidecar 3309
	render "$R"
	check "and refuses one that carries a second signature, holding no key to check it" "3 1" \
		"$rc $(said 'no ML-DSA-65 release public key is configured')"
fi

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
