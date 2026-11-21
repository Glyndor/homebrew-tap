# shellcheck shell=bash
#
# The release signature check of the two package-manager channels, sourced by
# their renderers: scripts/release/render-formulae.sh in Glyndor/homebrew-tap
# and scripts/release/render-manifests.sh in Glyndor/scoop-bucket.
#
# It is the part of the renderer that decides whether a release is trusted,
# and nothing in it depends on the package manager, so it is one text in both
# repositories rather than two copies of a function kept in step by hand.
# scripts/monitoring/channel-shared-paths.txt lists it, and check-channel-drift
# compares it byte for byte with the sibling's copy, comments included. It
# used to sit inside each renderer, where check-render-drift compared it as two
# units; it moved here when the second, ML-DSA-65 signature took the tap's
# renderer past the 500-line limit of line-limit.yml.
#
# Sourcing it defines three functions and runs nothing:
#
#   check_release_configuration   once, before any release is read
#   verify_sha256sums             for each release
#   release_key_bytes             the key decoding the first one uses
#
# Both read what the renderer declares before it sources this file: the
# RELEASE_PUBKEY*_B64, RELEASE_PQ_PUBKEY*_B64 and RELEASE_PQ_REQUIRED trust
# constants, the MAX_SUMS_BYTES, MAX_SIG_BYTES and MAX_PQ_SIG_BYTES caps,
# PQ_SIG_LENGTH, the PRODUCTS roster and the work directory in $work.
# shellcheck disable=SC2154 # every name above is assigned by the renderer

# Download a release's SHA256SUMS(+.sig) and verify the signature, failing closed.
verify_sha256sums() { # $1=repo $2=tag $3=product
	rm -f "$work/SHA256SUMS" "$work/SHA256SUMS.sig" "$work/SHA256SUMS.mldsa65.sig"
	local asset limit pq_code pq_rc pq_size required name verify_rc
	local -a required_products=()
	# Bound each transfer, not just the files the verifier eventually reads.
	for asset in SHA256SUMS SHA256SUMS.sig; do
		case "$asset" in
			SHA256SUMS) limit="$MAX_SUMS_BYTES" ;;
			SHA256SUMS.sig) limit="$MAX_SIG_BYTES" ;;
		esac
		if ! curl -fsSL --proto =https --proto-redir =https --connect-timeout 10 --max-time 120 \
			--max-filesize "$limit" -o "$work/$asset" \
			"https://github.com/$1/releases/download/$2/$asset"; then
			echo "::error::$1 $2: failed to download $asset within the ${limit}-byte cap and 120-second time limit" >&2
			return 1
		fi
	done
	# Retain disk bounds before Python reads either file, including the exact
	# Ed25519 signature length, even if the downloader does not enforce its cap.
	# A size refusal remains distinct from a malformed key or invalid signature.
	sums_size="$(stat -c%s "$work/SHA256SUMS")"
	[ "$sums_size" -le "$MAX_SUMS_BYTES" ] || {
		echo "::error::$1 $2: SHA256SUMS is $sums_size bytes, over the ${MAX_SUMS_BYTES}-byte cap" >&2
		return 1
	}
	sig_size="$(stat -c%s "$work/SHA256SUMS.sig")"
	[ "$sig_size" -eq "$MAX_SIG_BYTES" ] || {
		echo "::error::$1 $2: SHA256SUMS.sig is $sig_size bytes; an Ed25519 signature is exactly ${MAX_SIG_BYTES} bytes" >&2
		return 1
	}
	# The second signature, if this release carries one. Its absence is not an
	# error: a release that publishes only the Ed25519 signature is admitted
	# exactly as it was before, unless its product is in the required list.
	#
	# The status code is what tells the two apart, and it is read with the
	# transfer instead of guessed from curl's exit status: a 404 means the
	# release carries no second signature, while any other failure means the
	# question could not be answered. A release whose second signature could
	# not be read is not a release without one.
	#
	# The transfer carries no `-f` on purpose: a 404 is an answer, not a
	# failure, and curl would print it as an error on every release that
	# carries no second signature.
	pq_code=""
	pq_rc=0
	curl -sSL --proto =https --proto-redir =https --connect-timeout 10 --max-time 120 --max-filesize "$MAX_PQ_SIG_BYTES" \
		-o "$work/SHA256SUMS.mldsa65.sig" -w '%{http_code}' \
		"https://github.com/$1/releases/download/$2/SHA256SUMS.mldsa65.sig" > "$work/pq.code" || pq_rc=$?
	pq_code="$(cat "$work/pq.code" 2>/dev/null || true)"
	if [ "$pq_rc" -ne 0 ] && [ "$pq_code" != "404" ]; then
		echo "::error::$1 $2: failed to download SHA256SUMS.mldsa65.sig within the ${MAX_PQ_SIG_BYTES}-byte cap and 120-second time limit" >&2
		return 1
	fi
	case "$pq_code" in
		404)
			rm -f "$work/SHA256SUMS.mldsa65.sig"
			;;
		200)
			pq_size="$(stat -c%s "$work/SHA256SUMS.mldsa65.sig")"
			[ "$pq_size" -le "$MAX_PQ_SIG_BYTES" ] || {
				echo "::error::$1 $2: SHA256SUMS.mldsa65.sig is $pq_size bytes, over the ${MAX_PQ_SIG_BYTES}-byte cap" >&2
				return 1
			}
			[ "$pq_size" -eq "$PQ_SIG_LENGTH" ] || {
				echo "::error::$1 $2: SHA256SUMS.mldsa65.sig is $pq_size bytes; an ML-DSA-65 signature is exactly ${PQ_SIG_LENGTH} bytes" >&2
				return 1
			}
			;;
		*)
			echo "::error::$1 $2: the download of SHA256SUMS.mldsa65.sig answered HTTP ${pq_code:-none}; whether this release carries a second signature could not be decided" >&2
			return 1
			;;
	esac
	# Is the second signature required for this product? The list names
	# products of this repository's roster, and an entry that names none is a
	# mistake in this file that the configuration guard stops before any
	# release is read.
	required=0
	read -r -a required_products <<<"$RELEASE_PQ_REQUIRED"
	for name in "${required_products[@]}"; do
		if [ "$name" = "$3" ]; then
			required=1
		fi
	done
	# The Ed25519 signature is checked first and always; the ML-DSA-65 one is
	# checked when the release carries it, and always for a product the
	# required list names. The exit status says which failure it was: 1 the
	# release is not trusted, 2 our own trust anchor is malformed, 3 the
	# installed library cannot check the second signature.
	verify_rc=0
	python3 - "$work/SHA256SUMS" "$work/SHA256SUMS.sig" "$work/SHA256SUMS.mldsa65.sig" "$required" "$3" "$PQ_SIG_LENGTH" "$RELEASE_PUBKEY_B64" "$RELEASE_PUBKEY2_B64" "$RELEASE_PQ_PUBKEY_B64" "$RELEASE_PQ_PUBKEY2_B64" <<'PY' || verify_rc=$?
import base64, binascii, os, sys
from cryptography.exceptions import InvalidSignature, UnsupportedAlgorithm
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

sums_path, sig_path, pq_path = sys.argv[1:4]
required = sys.argv[4] == "1"
product = sys.argv[5]
pq_sig_bytes = int(sys.argv[6])
ed_keys_b64 = sys.argv[7:9]
# An empty slot is not a key, the same way the Ed25519 slots are read: only
# the slots that hold something are keys to check a signature against.
pq_keys_b64 = [k for k in sys.argv[9:11] if k]

msg = open(sums_path, "rb").read()
sig = open(sig_path, "rb").read()


def decode_key(b64):
    # Pad to a 4-character boundary rather than appending "==" blindly, and
    # reject anything outside the base64 alphabet. Without validate=True,
    # b64decode DISCARDS such characters: "AAAA!!!!BBBB" decodes to six bytes
    # without complaint, so a corrupted key silently becomes a shorter one.
    # Trim the ends before validating. The key reaches here as a shell
    # argument, and a value pasted into --pubkey arrives with whatever
    # whitespace came with it; validate=True would reject that as "not base64"
    # and point at the key when the fault is a trailing newline. Only the ends:
    # whitespace INSIDE the string is not a formatting convention for a base64
    # key the way grouping is for a gpg fingerprint, so it stays an error.
    #
    # check_release_configuration refuses these faults before any release is
    # read, so a renderer never gets here with a malformed key. This is the
    # second check, for a renderer that lost that call, and the suite of this
    # file reaches it on its own.
    b64 = b64.strip()
    b64 += "=" * (-len(b64) % 4)
    return base64.b64decode(b64, validate=True)


def load(b64):
    raw = decode_key(b64)
    if len(raw) != 32:
        raise ValueError(f"{len(raw)} bytes, not a 32-byte Ed25519 key")
    return Ed25519PublicKey.from_public_bytes(raw)


# Any configured key may be the one that signed this release; an empty slot is
# not a key. Still fails closed -- exhausting the slots is an error, not a
# fallthrough, so a stale pair aborts the render exactly as a single stale key
# did before.
raw_keys = [k for k in ed_keys_b64 if k]
if not raw_keys:
    sys.exit("no release key configured")

# Loading is separate from verifying so that a broken trust anchor of ours is
# not reported as a bad signature of theirs. Wrapping the verify call in
# `except Exception` collapsed both into one message, and the operator then
# went looking at the upstream release for a fault that was in this repository.
# apt/scripts/verify/verify-debs.sh already drew that line; this did not.
try:
    keys = [load(k) for k in raw_keys]
except (ValueError, binascii.Error) as exc:
    sys.stderr.write(f"malformed release public key: {exc}\n")
    sys.exit(2)

verified = False
for key in keys:
    try:
        key.verify(sig, msg)
    except InvalidSignature:
        continue
    verified = True
    break
if not verified:
    sys.exit("SHA256SUMS does not verify against any configured release key")
print("SHA256SUMS signature verified")

# The second signature. It is a hybrid and never a replacement: the Ed25519
# signature above is checked first and always, and the release is admitted
# only if this one verifies too.
#
# It is checked when the release carries it, and always for a product the
# required list names. A signature that is present and cannot be verified is
# a refusal and not a signature that passed, and neither is a signature that
# may be left out.
pq_present = os.path.exists(pq_path)
if not pq_present and not required:
    sys.exit(0)
if not pq_present:
    sys.stderr.write(
        f"no ML-DSA-65 signature for {product}; {product} requires the hybrid release signature\n"
    )
    sys.exit(1)
if not pq_keys_b64:
    sys.stderr.write(
        "the release carries an ML-DSA-65 signature and no ML-DSA-65 release public key is "
        "configured; refusing a signature that cannot be checked\n"
    )
    sys.exit(1)


def load_pq(b64):
    # The same decoding as the Ed25519 key, so a corrupted key is not silently
    # a shorter one.
    raw = decode_key(b64)
    if len(raw) != 1952:
        raise ValueError(f"{len(raw)} bytes, not a 1952-byte ML-DSA-65 public key")
    return raw


try:
    raw_pq_keys = [load_pq(k) for k in pq_keys_b64]
except (ValueError, binascii.Error) as exc:
    sys.stderr.write(f"malformed ML-DSA-65 release public key: {exc}\n")
    sys.exit(2)

# The library is imported only when there is a second signature to check, so a
# release without one needs nothing the runner's python3-cryptography does not
# carry. The runner's cryptography has no ML-DSA, and the wheel that does is
# installed only once a key is configured.
#
# A cryptography that has the module but was built against an OpenSSL without
# ML-DSA imports it and refuses the key instead, with UnsupportedAlgorithm.
# That is the library again and not our key, so the key is loaded inside the
# same check as the import.
try:
    from cryptography.hazmat.primitives.asymmetric.mldsa import MLDSA65PublicKey

    pq_keys = [MLDSA65PublicKey.from_public_bytes(raw) for raw in raw_pq_keys]
except (ImportError, UnsupportedAlgorithm) as exc:
    sys.stderr.write(
        f"the installed cryptography module cannot verify ML-DSA-65 ({exc}); "
        f"cryptography 50.0.2 or later is required, pinned in scripts/release/render-requirements.txt\n"
    )
    sys.exit(3)
except ValueError as exc:
    sys.stderr.write(f"malformed ML-DSA-65 release public key: {exc}\n")
    sys.exit(2)

# Read one byte past the signature's length rather than the whole file: a
# hostile sidecar is never read into memory wholesale before its length is
# known.
with open(pq_path, "rb") as f:
    pq_sig = f.read(pq_sig_bytes + 1)
if len(pq_sig) != pq_sig_bytes:
    sys.stderr.write(
        f"the ML-DSA-65 signature is {len(pq_sig)} bytes, expected exactly {pq_sig_bytes}\n"
    )
    sys.exit(1)

# Any configured key may have signed the release, as with the Ed25519 one.
# Pure ML-DSA with the empty context, so `openssl pkeyutl -verify -rawin` 3.5
# or later checks the same signature.
for key in pq_keys:
    try:
        key.verify(pq_sig, msg)
    except InvalidSignature:
        continue
    print("SHA256SUMS ML-DSA-65 signature verified")
    sys.exit(0)
sys.stderr.write("the ML-DSA-65 signature does not verify against any configured release key\n")
sys.exit(1)
PY
	# A `case` that matches no pattern succeeds, so a status the verifier was
	# never meant to return would admit the release: python3 missing (127), or
	# the verifier killed or crashed before it printed a verdict (137, 139).
	# Only the four statuses below are verdicts, and anything else is refused
	# here, before the case reads it.
	[ "$verify_rc" -le 3 ] || {
		echo "::error::$1 $2: the signature check stopped with status $verify_rc before reaching a verdict; the release is refused" >&2
		return 1
	}
	case "$verify_rc" in
		0) return 0 ;;
		1)
			echo "::error::$1 $2: the release was not admitted: its signature did not verify, or the second signature it carries is missing or invalid" >&2
			return 1
			;;
		2)
			echo "::error::$1 $2: the local release trust anchor is malformed; no key could be loaded to verify against" >&2
			return 1
			;;
		3)
			echo "::error::$1 $2: the installed cryptography cannot verify ML-DSA-65; the second signature is refused rather than skipped" >&2
			return 1
			;;
	esac
}


# Check the local configuration before any release is read.
#
# Two mistakes in this file are ours and not the release's: a trust anchor
# that is not a key, and a required product this repository does not publish.
# The first would make every signature it should check unverifiable, and the
# second would name a requirement that matches no product and drop it in
# silence. Both stop the run here, before a single release is read, and both
# are reported as a configuration error rather than as a bad release: a broken
# Ed25519 key used to stop each product in turn, reported per release, and the
# operator went looking at the release.
check_release_configuration() {
	local entry bytes name product found ed_keys=0
	local -a required=()
	for entry in "$RELEASE_PUBKEY_B64" "$RELEASE_PUBKEY2_B64"; do
		# The verifier trims the ends of an Ed25519 key, because a value
		# pasted into --pubkey brings whatever whitespace came with it, so
		# the ends are trimmed here too. Whitespace inside stays an error.
		entry="${entry#"${entry%%[![:space:]]*}"}"
		entry="${entry%"${entry##*[![:space:]]}"}"
		[ -n "$entry" ] || continue
		ed_keys=$((ed_keys + 1))
		bytes="$(release_key_bytes Ed25519 "$entry")" || return 1
		[ "$bytes" -eq 32 ] || {
			echo "::error::the Ed25519 release public key is $bytes bytes, not the 32 bytes of an Ed25519 key" >&2
			return 1
		}
	done
	[ "$ed_keys" -gt 0 ] || {
		echo "::error::no Ed25519 release public key is configured; every release would be refused" >&2
		return 1
	}
	for entry in "$RELEASE_PQ_PUBKEY_B64" "$RELEASE_PQ_PUBKEY2_B64"; do
		[ -n "$entry" ] || continue
		bytes="$(release_key_bytes ML-DSA-65 "$entry")" || return 1
		[ "$bytes" -eq 1952 ] || {
			echo "::error::the ML-DSA-65 release public key is $bytes bytes, not the 1952 bytes of an ML-DSA-65 key" >&2
			return 1
		}
	done
	# The list is one line. `read` takes the first line only, here and in
	# verify_sha256sums, so a product named on a second line would be dropped
	# by both without a word, and check-render-drift compares only the first
	# line of the declaration as well.
	case "$RELEASE_PQ_REQUIRED" in
		*$'\n'*)
			echo "::error::the required-products list spans more than one line; name the products on one line, separated by spaces" >&2
			return 1
			;;
	esac
	read -r -a required <<<"$RELEASE_PQ_REQUIRED"
	for name in "${required[@]}"; do
		found=""
		for entry in "${PRODUCTS[@]}"; do
			IFS='|' read -r _ product _ <<<"$entry"
			if [ "$product" = "$name" ]; then
				found=1
				break
			fi
		done
		[ -n "$found" ] || {
			echo "::error::the required-products list names '$name', which is not a product of this repository" >&2
			return 1
		}
	done
	# The two switches are set in one order: the public key reaches the
	# verifier first, and a product is required only after a release of it
	# has been verified with both signatures. A key with an empty list is the
	# state between those steps, and is valid: a second signature is checked
	# when a release carries one, and none is demanded yet. A list with no key
	# is not a state of that order. Every release of a required product would
	# be refused, reported as that product's release and not as this file, so
	# it stops here.
	if [ "${#required[@]}" -gt 0 ] && [ -z "$RELEASE_PQ_PUBKEY_B64$RELEASE_PQ_PUBKEY2_B64" ]; then
		echo "::error::the required-products list names ${required[*]}, and no ML-DSA-65 release public key is configured to check the signature it requires; the key is committed before any product is required" >&2
		return 1
	fi
}

# release_key_bytes <algorithm> <base64>: the number of bytes a configured key
# decodes to, read the way the verifier reads it, or a refusal that names the
# key. One line of base64: `base64 -d` skips a newline, so a key broken over
# two lines decoded here while the verifier refused it, and every signature
# would have failed on a key this check had passed. For an ML-DSA-65 key the
# line is also what update.yml reads to decide whether to install the library.
release_key_bytes() {
	local algorithm="$1" entry="$2" padded
	case "$entry" in
		*[[:space:]]*)
			echo "::error::the $algorithm release public key contains whitespace; it is one line of base64" >&2
			return 1
			;;
	esac
	# A key is stored unpadded, and a base64 decoder refuses a group it
	# cannot finish. The padding is restored here so the key is decoded the
	# way the verifier decodes it.
	case $(( ${#entry} % 4 )) in
		0) padded="$entry" ;;
		2) padded="${entry}==" ;;
		3) padded="${entry}=" ;;
		*)
			echo "::error::the $algorithm release public key is not a base64 string of whole bytes" >&2
			return 1
			;;
	esac
	# The status read is the decoder's, the last command of its pipeline, so
	# the refusal does not depend on the caller having set pipefail.
	printf '%s' "$padded" | base64 -d > /dev/null 2>&1 || {
		echo "::error::the $algorithm release public key is not valid base64" >&2
		return 1
	}
	printf '%s' "$padded" | base64 -d | wc -c
}
