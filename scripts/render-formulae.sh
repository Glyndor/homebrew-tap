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

# Products to publish, one per line:
#   repo|formula|Class|SPDX licence|description|arm64|x86_64|version check
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
	python3 - "$work/SHA256SUMS" "$work/SHA256SUMS.sig" "$RELEASE_PUBKEY_B64" <<'PY'
import base64, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
msg = open(sys.argv[1], "rb").read()
sig = open(sys.argv[2], "rb").read()
Ed25519PublicKey.from_public_bytes(base64.b64decode(sys.argv[3] + "==")).verify(sig, msg)
print("SHA256SUMS signature verified")
PY
}

# Print the verified SHA-256 of an asset, or fail if it is absent from the manifest.
hash_of() { # $1=asset
	awk -v a="$1" '$2 == a { print $1; found = 1 } END { if (!found) exit 1 }' \
		"$work/SHA256SUMS"
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
	local tag version arm_sha intel_sha base

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

	arm_sha="$(hash_of "$arm")" || {
		echo "::error::$repo $tag: the verified SHA256SUMS does not list $arm"
		return 1
	}
	intel_sha="$(hash_of "$intel")" || {
		echo "::error::$repo $tag: the verified SHA256SUMS does not list $intel"
		return 1
	}

	base="https://github.com/$repo/releases/download/$tag"

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
    on_arm do
      url "$base/$arm"
      sha256 "$arm_sha"
    end
    on_intel do
      url "$base/$intel"
      sha256 "$intel_sha"
    end
  end

  def install
    # A bare-binary download stages under its release-asset name. Take that name
    # from the generator's table, which is the same source the urls above come
    # from, rather than globbing for one: a product whose assets are not named
    # "<tool>-darwin-<arch>" would match nothing and install an empty formula.
    asset = Hardware::CPU.arm? ? "$arm" : "$intel"
    bin.install asset => "$formula"
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
