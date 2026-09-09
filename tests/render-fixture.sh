#!/usr/bin/env bash
#
# Shared fixture for the render tests. Sourced, never run: it stands up an
# ephemeral signing key, a stub `gh` that answers `release view`, `release
# download` and `attestation verify` from files on disk, and the helpers that
# publish a synthetic release and drive the generator.
#
# It exists because the cases outgrew one file. tests/render-formulae.test.sh
# was 451 code lines before build provenance was added, against a 300-line
# soft limit and a 500-line hard one. Splitting the cases and duplicating the
# fixture would have left two copies of a stub to keep in step, which is the
# shape that has bitten this organisation before, so the fixture moved here
# and both files source it.
#
# Not named *.test.sh on purpose: tests/ci-runs-every-test.test.sh requires
# every test file to be invoked by a workflow, and this one is not a test.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="$HERE/scripts/render-formulae.sh"
WORK="$(mktemp -d)"
RELEASES="$WORK/releases"
BIN="$WORK/bin"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pass=0
fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"
		pass=$((pass + 1))
	else
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

contains() { # <description> <file> <substring>
	if grep -qF -- "$3" "$2" 2>/dev/null; then
		echo "ok    $1"
		pass=$((pass + 1))
	else
		echo "FAIL  $1"
		echo "        $2 does not contain: $3"
		fail=$((fail + 1))
	fi
}

# --- an ephemeral signing key, and a stub gh that serves fixtures ------------

mkdir -p "$BIN" "$RELEASES"
PUBKEY="$(python3 - "$WORK" <<'PY'
import base64, os, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
key = Ed25519PrivateKey.generate()
raw = key.private_bytes(encoding=serialization.Encoding.Raw,
                        format=serialization.PrivateFormat.Raw,
                        encryption_algorithm=serialization.NoEncryption())
open(os.path.join(sys.argv[1], "signing.key"), "wb").write(raw)
pub = key.public_key().public_bytes(encoding=serialization.Encoding.Raw,
                                    format=serialization.PublicFormat.Raw)
# Unpadded, the way the generator stores and re-pads it.
print(base64.b64encode(pub).decode().rstrip("="))
PY
)"

# `gh release view --repo R --json tagName --jq .tagName` prints the tag stored
# for that repo; `gh release download TAG --repo R ... --dir D` copies the
# fixture's SHA256SUMS pair into D; `gh attestation verify FILE --repo R
# --source-ref REF --signer-workflow W --format json` succeeds unless
# ATTEST_STUB_OUTCOME says otherwise (wrong-tag, no-attestation,
# wrong-signer). Anything else is a test bug, not a silent pass, so it
# exits non-zero.
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
sub="${1:-}"; shift || true
repo=""; dir=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
	case "${args[i]}" in
		--repo) repo="${args[i+1]}" ;;
		--dir)  dir="${args[i+1]}" ;;
	esac
done
slug="${repo//\//__}"
base="$RELEASES/$slug"
case "$sub" in
	release)
		what="${args[0]}"
		[ -d "$base" ] || { echo "release not found" >&2; exit 1; }
		if [ "$what" = "view" ]; then
			cat "$base/tag"
		else
			cp "$base/SHA256SUMS" "$dir/SHA256SUMS" 2>/dev/null || exit 1
			cp "$base/SHA256SUMS.sig" "$dir/SHA256SUMS.sig" 2>/dev/null || exit 1
		fi
		;;
	attestation)
		# The two pins that close the gap the SHA256SUMS signature does
		# not cover: --source-ref names the tag the artifact was built
		# from, --signer-workflow names the workflow that signed the
		# attestation. A regression that drops either pin would let an
		# artifact from another tag, or one signed by a foreign
		# workflow, verify against this release; refuse on that fault
		# before honouring ATTEST_STUB_OUTCOME, so a stub that always
		# refused or always passed would still go red here.
		source_ref=""
		signer=""
		for ((i = 0; i < ${#args[@]}; i++)); do
			case "${args[i]}" in
				--source-ref)      source_ref="${args[i+1]}" ;;
				--signer-workflow) signer="${args[i+1]}" ;;
			esac
		done
		expected_ref="refs/tags/$(cat "$base/tag")"
		expected_signer="$repo/.github/workflows/release.yml"
		if [ -z "$source_ref" ]; then
			echo "stub gh: refusing attestation verify, --source-ref pin missing; an artifact from another tag would verify against this release" >&2
			exit 1
		fi
		if [ "$source_ref" != "$expected_ref" ]; then
			echo "stub gh: refusing attestation verify, --source-ref is $source_ref, expected $expected_ref" >&2
			exit 1
		fi
		if [ -z "$signer" ]; then
			echo "stub gh: refusing attestation verify, the trusted-workflow pin is missing; a foreign signing identity's provenance would verify against this release" >&2
			exit 1
		fi
		if [ "$signer" != "$expected_signer" ]; then
			echo "stub gh: refusing attestation verify, the trusted-workflow pin does not match; passed $signer, expected $expected_signer" >&2
			exit 1
		fi
		# Pins verified; ATTEST_STUB_OUTCOME controls the rest so the
		# wrong-tag, wrong-signer and no-attestation cases still fire.
		case "${ATTEST_STUB_OUTCOME:-ok}" in
			ok)
				cat "$base/attestation.json"
				;;
			no-attestation)
				echo "no attestations found for $repo at $source_ref (HTTP 404)" >&2
				exit 1
				;;
			wrong-tag)
				echo "the attestation source ref does not match expected $source_ref; the artifact was built from another tag" >&2
				exit 1
				;;
			wrong-signer)
				echo "the signer workflow does not match $signer; cert-identity check failed" >&2
				exit 1
				;;
			*)
				echo "stub gh: unknown ATTEST_STUB_OUTCOME ${ATTEST_STUB_OUTCOME}" >&2
				exit 90
				;;
		esac
		;;
	*) echo "stub gh: unexpected subcommand $sub" >&2; exit 90 ;;
esac
SH
chmod +x "$BIN/gh"
export RELEASES
export PATH="$BIN:$PATH"

# Curl stub for the asset download. Renders download from the fixture file
# matching the asset name. The URL is parsed to find the slug/asset pair
# so the stub does not need to be told where the fixture lives.
cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
for arg in "$@"; do :; done 2>/dev/null || true
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
	case "${args[i]}" in
		-o)    output="${args[i+1]}" ;;
		http*) url="${args[i]}" ;;
	esac
done
[ -n "$output" ] || { echo "curl stub: no -o output" >&2; exit 1; }
[ -n "$url" ] || { echo "curl stub: no url" >&2; exit 1; }
# https://github.com/owner/repo/releases/download/TAG/ASSET
path="${url#https://github.com/}"
owner_repo="${path%%/releases/download/*}"
rest="${path#*/releases/download/}"
tag="${rest%%/*}"
asset="${rest#*/}"
slug="${owner_repo//\//__}"
fixture="$RELEASES/$slug/asset_${asset}"
if [ "${CURL_STUB_FAIL:-}" = "1" ]; then
	echo "curl stub: configured to fail for $url" >&2
	exit 22
fi
if [ ! -f "$fixture" ]; then
	echo "curl stub: no fixture for $url (looked at $fixture)" >&2
	exit 1
fi
cp "$fixture" "$output"
SH
chmod +x "$BIN/curl"

# Publish a synthetic release: a SHA256SUMS listing the given assets, signed
# with the ephemeral key. Each asset gets a deterministic fixture file
# alongside it so the curl stub can serve it when verify_attestation
# downloads it, and SHA256SUMS carries the FIXTURE's real SHA-256 rather
# than a hand-computed one -- verify_attestation downloads the fixture,
# computes its SHA-256, and refuses if it does not match the manifest.
# A default attestation.json fixture is also written so the gh attestation
# stub has something to print in its "ok" branch.
publish() { # $1=repo $2=tag $3...=asset names
	local repo="$1" tag="$2"; shift 2
	local slug="${repo//\//__}" base
	base="$RELEASES/$slug"
	rm -rf "$base"; mkdir -p "$base"
	printf '%s' "$tag" > "$base/tag"
	: > "$base/SHA256SUMS"
	local asset content digest
	for asset in "$@"; do
		content="$(printf 'asset-%s' "$asset")"
		printf '%s' "$content" > "$base/asset_${asset}"
		digest="$(printf '%s' "$content" | sha256sum | awk '{print $1}')"
		printf '%s  %s\n' "$digest" "$asset" >> "$base/SHA256SUMS"
	done
	python3 - "$WORK/signing.key" "$base/SHA256SUMS" "$base/SHA256SUMS.sig" <<'PY'
import sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
key = Ed25519PrivateKey.from_private_bytes(open(sys.argv[1], "rb").read())
open(sys.argv[3], "wb").write(key.sign(open(sys.argv[2], "rb").read()))
PY
	# Default attestation: a JSON array with one entry whose certificate
	# matches the tag and signer the renderer is expected to verify.
	# Tests that exercise a different attestation outcome delete this file
	# or steer the gh stub with ATTEST_STUB_OUTCOME.
	python3 - "$base/attestation.json" "$repo" "$tag" <<'PY'
import json, sys
out, repo, tag = sys.argv[1], sys.argv[2], sys.argv[3]
expected_ref = f"refs/tags/{tag}"
expected_signer = (
    f"https://github.com/{repo}/.github/workflows/release.yml@{expected_ref}"
)
entry = {
    "verificationResult": {
        "signature": {
            "certificate": {
                "SourceRepository": expected_ref,
                "SubjectAlternativeName": expected_signer,
            },
        },
        "statement": {
            "predicate": {
                "sourceRepositoryRef": expected_ref,
            },
        },
    },
}
json.dump([entry], open(out, "w"))
PY
}

# Re-sign a hand-built SHA256SUMS so the generator still sees a valid signature.
# The point of these cases is malformed CONTENT behind a good signature.
resign() { # $1=sums file $2=repo
	local base="$RELEASES/${2//\//__}"
	cp "$1" "$base/SHA256SUMS"
	python3 - "$WORK/signing.key" "$base/SHA256SUMS" "$base/SHA256SUMS.sig" <<'SIGN'
import sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
key = Ed25519PrivateKey.from_private_bytes(open(sys.argv[1], "rb").read())
open(sys.argv[3], "wb").write(key.sign(open(sys.argv[2], "rb").read()))
SIGN
}

# A copy of the generator whose PRODUCTS table is replaced wholesale. Replacing
# the block rather than editing fields keeps these tests working when the table
# gains a column; it gained two while the generator was being rewritten.
generator_with() { # $1=destination $2...=table rows
	local dest="$1"; shift
	local rows
	rows="$(printf '\t"%s"\n' "$@")"
	awk -v rows="$rows" '
		/^PRODUCTS=\(/ { print; print rows; inside = 1; next }
		inside && /^\)/ { print; inside = 0; next }
		!inside        { print }
	' "$GENERATOR" > "$dest"
	chmod +x "$dest"
}

run() { # $1=script $2=repo root ; prints nothing, returns the exit status
	( cd "$2" && "$1" --pubkey "$PUBKEY" ) > "$WORK/out" 2>&1
}

# A repo root with a Formula/ directory, for the generator to write into.
new_root() { # $1=path
	rm -rf "$1"; mkdir -p "$1/scripts" "$1/Formula"
}

# The one product row both files build their tables from. shellcheck cannot
# see the sourcing files, so it reads this as unused.
# shellcheck disable=SC2034
PODUP="Glyndor/podup|podup|Podup|MIT|Docker-compose translator|podup-darwin-arm64|podup-darwin-x86_64|-|-|--version"
