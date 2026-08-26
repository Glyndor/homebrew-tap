#!/usr/bin/env bash
# Regenerate Formula/*.rb from the latest signed release of each Glyndor product.
#
# Pull-based, mirroring Glyndor/apt: no product pushes into this repository. This
# reads each product's public GitHub release, verifies its signed SHA256SUMS
# against the org release-signing key, and renders a formula that installs the
# macOS binary from that release with the verified checksum. macOS only — Linux
# is served by the apt repo (apt.glyndor.net).
#
# Run by .github/workflows/update.yml on a schedule and on demand.
#
# Exit codes: 0 every product rendered; 3 at least one product was skipped and
# the rest rendered (update.yml commits those, then fails the job); anything
# else is a failure before any product was reached.
set -euo pipefail

# The org's Ed25519 release-signing public key, raw and unpadded base64.
# Verifying against it is what makes the rendered checksum trustworthy rather
# than whatever an attacker-influenced release asset happens to contain.
#
# Rotating the org release key means editing this constant here AND in
# Glyndor/scoop-bucket's render-manifests.sh, on top of the products that embed
# it in their own verifiers. A stale value fails closed: every render aborts on
# a signature that no longer matches.
RELEASE_PUBKEY_B64="HFv7vg5FCY7YyKUDbJhaQSfB9SboJGSblJtFbLmLHzM"

# Second slot, empty until a rotation is in flight. The org rotation is
# make-before-break: phase one publishes a release still signed with the old
# key that carries both, consumers pick the new one up, and only then does
# phase two sign with the new key. A renderer with a single slot cannot take
# part in that -- it would verify fine through phase one and start failing the
# moment phase two lands. And because this channel is pull-based, that failure
# is invisible: the render aborts, no formula is updated, and the tap simply
# stops moving on the last version it could verify. install.sh and install.ps1
# have carried two slots for exactly this reason; this brings the tap level
# with them.
RELEASE_PUBKEY2_B64=""

# The only way to override it is --pubkey, which tests/render-formulae.test.sh
# uses to sign a synthetic release with an ephemeral key. A run with no
# arguments trusts the constant above and nothing else — there is deliberately
# no environment variable that could swap the trust anchor from outside. This is
# the shape Glyndor/apt's verify-debs.sh already uses, where the key is an
# argument for the same reason.
while [ $# -gt 0 ]; do
	case "$1" in
		--pubkey)
			[ $# -ge 2 ] || { echo "--pubkey needs a value" >&2; exit 2; }
			RELEASE_PUBKEY_B64="$2"
			shift 2
			;;
		--pubkey2)
			[ $# -ge 2 ] || { echo "--pubkey2 needs a value" >&2; exit 2; }
			RELEASE_PUBKEY2_B64="$2"
			shift 2
			;;
		*)
			echo "unknown argument: $1" >&2
			exit 2
			;;
	esac
done

# Products to publish, one per line:
#   repo|formula|Class|SPDX licence|description|arm64|x86_64|version check
#
# An asset field of "-" means the product publishes nothing for that
# architecture and the formula omits it; at least one must be a real name. An
# EMPTY field stays an error, because that is what a dropped column looks like.
#
# `arm64`/`x86_64` are the macOS release asset names, and `version check` is the
# argument the formula's test block passes to the installed binary. Add a
# product here once it ships macOS binaries with a signed SHA256SUMS. Keep it in
# step with the apt repo's PRODUCTS list where a product ships on both.
#
# The licence and the version check used to be written into the template for
# every product. Both happened to be right for podup and neither was checkable:
# `brew audit --strict` only reads what the formula declares, so a formula
# claiming MIT for a product that is not MIT passes, and Homebrew shows that
# claim to the user. The org's Apache-2.0 to MIT migration is not finished, so
# that case is reachable rather than hypothetical.
#
# This table is the only place a product is declared. The formula it renders,
# the formulae pruned below, and the README's "Available formulae" table (which
# ci.yml checks against this list) all follow from it.
PRODUCTS=(
	"Glyndor/podup|podup|Podup|MIT|Docker-compose translator and runner for rootless Podman|podup-darwin-arm64|podup-darwin-x86_64|--version"
)

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Download a release's SHA256SUMS(+.sig) and verify the signature, failing closed.
verify_sha256sums() { # $1=repo $2=tag
	rm -f "$work/SHA256SUMS" "$work/SHA256SUMS.sig"
	gh release download "$2" --repo "$1" \
		--pattern SHA256SUMS --pattern SHA256SUMS.sig --dir "$work" --clobber \
		|| return 1
	python3 - "$work/SHA256SUMS" "$work/SHA256SUMS.sig" \
		"$RELEASE_PUBKEY_B64" "$RELEASE_PUBKEY2_B64" <<'PY'
import base64, binascii, sys
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

msg = open(sys.argv[1], "rb").read()
sig = open(sys.argv[2], "rb").read()


def load(b64):
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
    b64 = b64.strip()
    b64 += "=" * (-len(b64) % 4)
    raw = base64.b64decode(b64, validate=True)
    if len(raw) != 32:
        raise ValueError(f"{len(raw)} bytes, not a 32-byte Ed25519 key")
    return Ed25519PublicKey.from_public_bytes(raw)


# Any configured key may be the one that signed this release; an empty slot is
# not a key. Still fails closed -- exhausting the slots is an error, not a
# fallthrough, so a stale pair aborts the render exactly as a single stale key
# did before.
raw_keys = [k for k in sys.argv[3:] if k]
if not raw_keys:
    sys.exit("no release key configured")

# Loading is separate from verifying so that a broken trust anchor of ours is
# not reported as a bad signature of theirs. Wrapping the verify call in
# `except Exception` collapsed both into one message, and the operator then
# went looking at the upstream release for a fault that was in this repository.
# apt/scripts/verify-debs.sh already drew that line; this did not.
try:
    keys = [load(k) for k in raw_keys]
except (ValueError, binascii.Error) as exc:
    sys.exit(f"malformed release public key: {exc}")

for key in keys:
    try:
        key.verify(sig, msg)
    except InvalidSignature:
        continue
    print("SHA256SUMS signature verified")
    sys.exit(0)
sys.exit("SHA256SUMS does not verify against any configured release key")
PY
}

# Print the verified SHA-256 of an asset. Fails unless the manifest lists it
# exactly once with a well-formed digest.
#
# The signature proves the manifest is the one the product published; it says
# nothing about it being well-formed. Before this, a duplicated entry printed
# BOTH hashes into one field and the run exited 0 -- a fail-open on
# signature-verified input, and in the Scoop bucket's case one that passed
# ci.yml's validation and would have been committed to main. Glyndor/apt's
# publish.yml states the assumption this rests on: the release assets are
# attacker-influenced, because whoever can publish a release controls them.
hash_of() { # $1=asset
	local matches count digest
	matches="$(awk -v a="$1" '$2 == a { print $1 }' "$work/SHA256SUMS")"
	[ -n "$matches" ] || return 1
	count="$(printf '%s\n' "$matches" | wc -l)"
	[ "$count" -eq 1 ] || {
		echo "::error::the verified SHA256SUMS lists $1 $count times; it must list it exactly once" >&2
		return 1
	}
	digest="$matches"
	case "$digest" in
		*[!0-9a-fA-F]* | "")
			echo "::error::the checksum the verified SHA256SUMS gives for $1 is not hexadecimal" >&2
			return 1
			;;
	esac
	[ "${#digest}" -eq 64 ] || {
		echo "::error::the checksum the verified SHA256SUMS gives for $1 is ${#digest} characters, not 64" >&2
		return 1
	}
	printf '%s\n' "$digest"
}

# Render one product's formula. Returns non-zero without touching any file when
# the release cannot be read, its SHA256SUMS does not verify, or an asset the
# table names is missing.
#
# Every step is checked explicitly rather than left to `set -e`: this runs as an
# `if !` condition below, which disables errexit for the whole function, so an
# unchecked failure would carry on and render a formula from a half-read state.
render_product() { # $1=table entry
	local entry="$1"
	local repo formula cls licence desc arm intel version_check
	local tag version arm_sha intel_sha base arch_blocks install_body

	IFS='|' read -r repo formula cls licence desc arm intel version_check <<<"$entry"

	for field in repo formula cls licence desc arm intel version_check; do
		[ -n "${!field}" ] || {
			echo "::error::the PRODUCTS entry \"$entry\" has no $field"
			return 1
		}
	done

	tag="$(gh release view --repo "$repo" --json tagName --jq .tagName)" || {
		echo "::error::$repo: could not read the latest release"
		return 1
	}
	version="${tag#v}"

	verify_sha256sums "$repo" "$tag" || {
		echo "::error::$repo $tag: SHA256SUMS is missing or does not verify against the org release key"
		return 1
	}

	# "-" means the product publishes nothing for that architecture, so the
	# formula omits it. An EMPTY field is still rejected above: an empty field
	# between two pipes is what a dropped column looks like, and confusing "not
	# published" with "I mistyped the row" would silently ship half a formula.
	[ "$arm" != "-" ] || [ "$intel" != "-" ] || {
		echo "::error::the PRODUCTS entry \"$entry\" publishes neither architecture"
		return 1
	}

	if [ "$arm" != "-" ]; then
		arm_sha="$(hash_of "$arm")" || {
			echo "::error::$repo $tag: the verified SHA256SUMS does not list $arm"
			return 1
		}
	fi
	if [ "$intel" != "-" ]; then
		intel_sha="$(hash_of "$intel")" || {
			echo "::error::$repo $tag: the verified SHA256SUMS does not list $intel"
			return 1
		}
	fi

	base="https://github.com/$repo/releases/download/$tag"

	# Build only the blocks the product actually ships. A single-architecture
	# formula installs its one asset directly; there is nothing to pick between.
	arch_blocks=""
	if [ "$arm" != "-" ]; then
		arch_blocks="    on_arm do
      url \"$base/$arm\"
      sha256 \"$arm_sha\"
    end"
	fi
	if [ "$intel" != "-" ]; then
		[ -n "$arch_blocks" ] && arch_blocks="$arch_blocks
"
		arch_blocks="$arch_blocks    on_intel do
      url \"$base/$intel\"
      sha256 \"$intel_sha\"
    end"
	fi

	if [ "$arm" != "-" ] && [ "$intel" != "-" ]; then
		install_body="    # A bare-binary download stages under its release-asset name. Take that name
    # from the generator's table, which is the same source the urls above come
    # from, rather than globbing for one: a product whose assets are not named
    # \"<tool>-darwin-<arch>\" would match nothing and install an empty formula.
    asset = Hardware::CPU.arm? ? \"$arm\" : \"$intel\"
    bin.install asset => \"$formula\""
	elif [ "$arm" != "-" ]; then
		install_body="    # Only an arm64 build is published, so there is nothing to pick between.
    bin.install \"$arm\" => \"$formula\""
	else
		install_body="    # Only an x86_64 build is published, so there is nothing to pick between.
    bin.install \"$intel\" => \"$formula\""
	fi

	cat >"$root/Formula/$formula.rb" <<RB
# typed: false
# frozen_string_literal: true

# Generated by scripts/render-formulae.sh from the signed release of $repo.
# Do not edit by hand — edit the generator and re-run the update workflow.
class $cls < Formula
  desc "$desc"
  homepage "https://github.com/$repo"
  version "$version"
  license "$licence"

  on_macos do
$arch_blocks
  end

  def install
$install_body
  end

  test do
    # The argument comes from the generator's table: brew audit --strict
    # requires a test block, and not every product answers --version.
    system "#{bin}/$formula", "$version_check"
  end
end
RB

	echo "rendered Formula/$formula.rb -> $version"
}

mkdir -p "$root/Formula"

declared=()
skipped=()

for entry in "${PRODUCTS[@]}"; do
	IFS='|' read -r _ formula _ <<<"$entry"
	declared+=("$formula")

	# Render each product on its own. Before this, one product's broken release
	# aborted the whole script under `set -e`, so a missing macOS binary — or a
	# signature that stopped verifying — held back every other product's update
	# too. A failure now leaves that product's existing formula exactly as it is,
	# which still points at its last verified release.
	if ! render_product "$entry"; then
		skipped+=("$formula")
	fi
done

# Drop formulae for products that are no longer in the table. Keyed on the table
# and not on what rendered this run: a product skipped above must keep the
# formula it already has, or one bad release would uninstall it from the tap.
shopt -s nullglob
for existing in "$root"/Formula/*.rb; do
	name="$(basename "$existing" .rb)"
	found=""
	for formula in "${declared[@]}"; do
		[ "$formula" = "$name" ] && found=1 && break
	done
	[ -n "$found" ] && continue
	rm -f "$existing"
	echo "removed Formula/$name.rb (no longer in PRODUCTS)"
done

if [ ${#skipped[@]} -gt 0 ]; then
	echo "::error::skipped ${#skipped[@]} of ${#declared[@]} product(s): ${skipped[*]}"
	exit 3
fi
