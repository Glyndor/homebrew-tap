#!/usr/bin/env bash
#
# Tests for scripts/render-formulae.sh — the generator that turns a product's
# signed release into the formula `brew install` uses.
#
# Why this is worth testing at all: update.yml commits this generator's output
# straight to `main`, so there is no pull request between a bug here and a user
# installing its result. The properties below are the ones that keep that safe —
# the signature gate is fail-closed, one product's broken release cannot remove
# or hold back another's, and what the table declares is what the formula says.
#
# Nothing here touches the network. A stub `gh` on PATH serves a synthetic
# release out of a fixture directory, and the release is signed with an
# ephemeral Ed25519 key passed to the generator with --pubkey; the org key
# stays the default for a run with no arguments.
#
# Requires: python3 with cryptography, bash 4+.

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
# fixture's SHA256SUMS pair into D. Anything else is a test bug, not a silent
# pass, so it exits non-zero.
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
	*) echo "stub gh: unexpected subcommand $sub" >&2; exit 90 ;;
esac
SH
chmod +x "$BIN/gh"
export RELEASES
export PATH="$BIN:$PATH"

# Publish a synthetic release: a SHA256SUMS listing the given assets, signed
# with the ephemeral key.
publish() { # $1=repo $2=tag $3...=asset names
	local repo="$1" tag="$2"; shift 2
	local slug="${repo//\//__}" base
	base="$RELEASES/$slug"
	rm -rf "$base"; mkdir -p "$base"
	printf '%s' "$tag" > "$base/tag"
	: > "$base/SHA256SUMS"
	local i=0 asset
	for asset in "$@"; do
		i=$((i + 1))
		printf '%064d  %s\n' "$i" "$asset" >> "$base/SHA256SUMS"
	done
	python3 - "$WORK/signing.key" "$base/SHA256SUMS" "$base/SHA256SUMS.sig" <<'PY'
import sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
key = Ed25519PrivateKey.from_private_bytes(open(sys.argv[1], "rb").read())
open(sys.argv[3], "wb").write(key.sign(open(sys.argv[2], "rb").read()))
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
# gains a column — it gained two while the generator was being rewritten.
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

PODUP="Glyndor/podup|podup|Podup|MIT|Docker-compose translator|podup-darwin-arm64|podup-darwin-x86_64|--version"

# --- the happy path ---------------------------------------------------------

publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
new_root "$WORK/r1"
generator_with "$WORK/r1/scripts/render-formulae.sh" "$PODUP"
rc=0; run "$WORK/r1/scripts/render-formulae.sh" "$WORK/r1" || rc=$?
check "a verified release renders and exits 0" "0" "$rc"

F="$WORK/r1/Formula/podup.rb"
contains "the version comes from the release tag" "$F" 'version "9.9.9"'
contains "the arm64 url points at the tagged asset" "$F" \
	'url "https://github.com/Glyndor/podup/releases/download/v9.9.9/podup-darwin-arm64"'
contains "the arm64 checksum is the one the signed manifest declares" "$F" \
	'sha256 "0000000000000000000000000000000000000000000000000000000000000001"'
contains "the x86_64 checksum is the one the signed manifest declares" "$F" \
	'sha256 "0000000000000000000000000000000000000000000000000000000000000002"'
contains "the licence comes from the table" "$F" 'license "MIT"'
contains "the version check comes from the table" "$F" 'system "#{bin}/podup", "--version"'
contains "install uses the asset name, not a glob" "$F" \
	'asset = Hardware::CPU.arm? ? "podup-darwin-arm64" : "podup-darwin-x86_64"'

# The table is the only place these come from, so prove they are not constants.
new_root "$WORK/r2"
generator_with "$WORK/r2/scripts/render-formulae.sh" \
	"Glyndor/podup|podup|Podup|Apache-2.0|d|podup-darwin-arm64|podup-darwin-x86_64|version"
run "$WORK/r2/scripts/render-formulae.sh" "$WORK/r2" || true
contains "a non-MIT licence in the table reaches the formula" \
	"$WORK/r2/Formula/podup.rb" 'license "Apache-2.0"'
contains "a different version check in the table reaches the formula" \
	"$WORK/r2/Formula/podup.rb" 'system "#{bin}/podup", "version"'

# --- fail closed ------------------------------------------------------------

# A signature made with the wrong key must not produce a formula.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
printf 'not a signature' > "$RELEASES/Glyndor__podup/SHA256SUMS.sig"
new_root "$WORK/r3"
generator_with "$WORK/r3/scripts/render-formulae.sh" "$PODUP"
rc=0; run "$WORK/r3/scripts/render-formulae.sh" "$WORK/r3" || rc=$?
check "an unverifiable signature skips the product" "3" "$rc"
check "and writes no formula" "0" "$(find "$WORK/r3/Formula" -name '*.rb' | wc -l)"

# An asset the table names but the verified manifest does not list.
publish Glyndor/podup v9.9.9 podup-darwin-arm64
new_root "$WORK/r4"
generator_with "$WORK/r4/scripts/render-formulae.sh" "$PODUP"
rc=0; run "$WORK/r4/scripts/render-formulae.sh" "$WORK/r4" || rc=$?
check "an asset missing from the manifest skips the product" "3" "$rc"
check "and writes no formula" "0" "$(find "$WORK/r4/Formula" -name '*.rb' | wc -l)"

# A product whose release cannot be read at all.
new_root "$WORK/r5"
generator_with "$WORK/r5/scripts/render-formulae.sh" \
	"Glyndor/nothing-here|nothing|Nothing|MIT|d|a-arm64|a-x86_64|--version"
rc=0; run "$WORK/r5/scripts/render-formulae.sh" "$WORK/r5" || rc=$?
check "an unreadable release skips the product" "3" "$rc"

# A table row with a field missing is named, not rendered from empty values.
new_root "$WORK/r6"
generator_with "$WORK/r6/scripts/render-formulae.sh" \
	"Glyndor/podup|podup|Podup|MIT|d|podup-darwin-arm64|podup-darwin-x86_64"
rc=0; run "$WORK/r6/scripts/render-formulae.sh" "$WORK/r6" || rc=$?
check "a short table row is rejected" "3" "$rc"
contains "and the missing field is named" "$WORK/out" "has no version_check"

# --- one product must not take down another ---------------------------------

publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
new_root "$WORK/r7"
generator_with "$WORK/r7/scripts/render-formulae.sh" \
	"Glyndor/nothing-here|ghostly|Ghostly|MIT|d|a-arm64|a-x86_64|--version" "$PODUP"
printf 'PRE-EXISTING\n' > "$WORK/r7/Formula/ghostly.rb"
rc=0; run "$WORK/r7/scripts/render-formulae.sh" "$WORK/r7" || rc=$?
check "a broken product does not stop a good one" "1" \
	"$(grep -c 'version "9.9.9"' "$WORK/r7/Formula/podup.rb")"
check "the run still fails, so the skip is not silent" "3" "$rc"
check "the skipped product keeps the formula it had" "PRE-EXISTING" \
	"$(cat "$WORK/r7/Formula/ghostly.rb")"

# --- pruning ----------------------------------------------------------------

new_root "$WORK/r8"
generator_with "$WORK/r8/scripts/render-formulae.sh" "$PODUP"
printf 'stale\n' > "$WORK/r8/Formula/gone.rb"
rc=0; run "$WORK/r8/scripts/render-formulae.sh" "$WORK/r8" || rc=$?
check "pruning a dropped product exits 0" "0" "$rc"
check "the dropped product's formula is gone" "0" \
	"$(find "$WORK/r8/Formula" -name 'gone.rb' | wc -l)"
check "the declared product's formula stays" "1" \
	"$(find "$WORK/r8/Formula" -name 'podup.rb' | wc -l)"

# --- the key is an argument, not an environment variable --------------------

rc=0
( cd "$WORK/r1" && "$WORK/r1/scripts/render-formulae.sh" --pubkey ) >/dev/null 2>&1 || rc=$?
check "--pubkey without a value is a usage error" "2" "$rc"
rc=0
( cd "$WORK/r1" && "$WORK/r1/scripts/render-formulae.sh" --wat ) >/dev/null 2>&1 || rc=$?
check "an unknown argument is a usage error" "2" "$rc"
rc=0
( cd "$WORK/r1" && RELEASE_PUBKEY_B64="$PUBKEY" "$WORK/r1/scripts/render-formulae.sh" ) >/dev/null 2>&1 || rc=$?
check "the environment cannot swap the trust anchor" "3" "$rc"

# --- a signed manifest can still be malformed --------------------------------

# A duplicated entry used to render BOTH hashes into one field and exit 0.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-arm64 podup-darwin-x86_64
new_root "$WORK/r9"
generator_with "$WORK/r9/scripts/render-formulae.sh" "$PODUP"
rc=0; run "$WORK/r9/scripts/render-formulae.sh" "$WORK/r9" || rc=$?
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
generator_with "$WORK/r10/scripts/render-formulae.sh" "$PODUP"
rc=0; run "$WORK/r10/scripts/render-formulae.sh" "$WORK/r10" || rc=$?
check "a non-hexadecimal checksum is rejected" "3" "$rc"
contains "and the error says why" "$WORK/out" "is not hexadecimal"

publish Glyndor/podup v9.9.9 podup-darwin-x86_64
{
	printf 'abcdef  podup-darwin-arm64\n'
	cat "$RELEASES/Glyndor__podup/SHA256SUMS"
} > "$WORK/tmpsums"
resign "$WORK/tmpsums" Glyndor/podup
new_root "$WORK/r11"
generator_with "$WORK/r11/scripts/render-formulae.sh" "$PODUP"
rc=0; run "$WORK/r11/scripts/render-formulae.sh" "$WORK/r11" || rc=$?
check "a short digest is rejected" "3" "$rc"
contains "and the error gives the length" "$WORK/out" "is 6 characters, not 64"

# --- two healthy products together -------------------------------------------
# The plain multi-product case: the suite otherwise only ever pairs a good
# product with a broken one, and this is the shape the second real product takes.

publish Glyndor/podup v1.2.3 podup-darwin-arm64 podup-darwin-x86_64
publish Glyndor/other v4.5.6 other-darwin-arm64 other-darwin-x86_64
new_root "$WORK/r12"
generator_with "$WORK/r12/scripts/render-formulae.sh" \
	"Glyndor/podup|podup|Podup|MIT|first|podup-darwin-arm64|podup-darwin-x86_64|--version" \
	"Glyndor/other|other|Other|Apache-2.0|second|other-darwin-arm64|other-darwin-x86_64|-V"
rc=0; run "$WORK/r12/scripts/render-formulae.sh" "$WORK/r12" || rc=$?
check "two healthy products both render, exit 0" "0" "$rc"
check "both formulae exist" "2" "$(find "$WORK/r12/Formula" -name '*.rb' | wc -l)"
contains "each gets its own version" "$WORK/r12/Formula/podup.rb" 'version "1.2.3"'
contains "including the second" "$WORK/r12/Formula/other.rb" 'version "4.5.6"'
contains "each gets its own licence" "$WORK/r12/Formula/other.rb" 'license "Apache-2.0"'
contains "and its own version check" "$WORK/r12/Formula/other.rb" 'system "#{bin}/other", "-V"'
contains "the first is untouched by the second" "$WORK/r12/Formula/podup.rb" 'license "MIT"'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
