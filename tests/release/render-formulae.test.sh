#!/usr/bin/env bash
#
# Tests for scripts/release/render-formulae.sh, the generator that turns a product's
# signed release into the formula `brew install` uses.
#
# Why this is worth testing at all: update.yml commits this generator's output
# straight to `main`, so there is no pull request between a bug here and a user
# installing its result. The properties below are the ones that keep that safe:
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

HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../fixtures/release" && pwd)"
# The linter cannot follow a sourced path built at run time, and the fixture
# is where check() and the counters live. The disable is on the source line
# alone; the counters are re-declared here so nothing downstream has to be
# excused for reading them.
# shellcheck disable=SC1091
. "$HERE_FIXTURE/render-fixture.sh"
pass=0
fail=0


# --- the happy path ---------------------------------------------------------

publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
new_root "$WORK/r1"
generator_with "$WORK/r1/scripts/release/render-formulae.sh" "$PODUP"
rc=0; run "$WORK/r1/scripts/release/render-formulae.sh" "$WORK/r1" || rc=$?
check "a verified release renders and exits 0" "0" "$rc"

F="$WORK/r1/Formula/podup.rb"
# The version is not declared: Homebrew scans it from the url, and `brew audit
# --strict` refuses a declared one as redundant with the scan. The url
# assertion below is where the tag reaching the formula is checked now, so
# both halves of that property have a case here.
check "no version is declared" "0" "$(grep -c '^  version ' "$F")"
contains "the arm64 url points at the tagged asset" "$F" \
	'url "https://github.com/Glyndor/podup/releases/download/v9.9.9/podup-darwin-arm64"'
contains "the arm64 checksum is the one the signed manifest declares" "$F" \
	'sha256 "9c4c120a44c601243afdf38fb1a8f45bc86b1e74121aac78902f1c3f8b489a62"'
contains "the x86_64 checksum is the one the signed manifest declares" "$F" \
	'sha256 "3ec08322a9c9e8489b8510a6237291217621af1683eac70147e61995cfc947ea"'
contains "the licence comes from the table" "$F" 'license "MIT"'
contains "the version check comes from the table" "$F" 'system "#{bin}/podup", "--version"'
contains "install uses the asset name, not a glob" "$F" \
	'asset = Hardware::CPU.arm? ? "podup-darwin-arm64" : "podup-darwin-x86_64"'

# The table is the only place these come from, so prove they are not constants.
new_root "$WORK/r2"
generator_with "$WORK/r2/scripts/release/render-formulae.sh" \
	"Glyndor/podup|podup|Podup|Apache-2.0|d|podup-darwin-arm64|podup-darwin-x86_64|-|-|version"
run "$WORK/r2/scripts/release/render-formulae.sh" "$WORK/r2" || true
contains "a non-MIT licence in the table reaches the formula" \
	"$WORK/r2/Formula/podup.rb" 'license "Apache-2.0"'
contains "a different version check in the table reaches the formula" \
	"$WORK/r2/Formula/podup.rb" 'system "#{bin}/podup", "version"'

# --- fail closed ------------------------------------------------------------

# A signature made with the wrong key must not produce a formula.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
# Exactly 64 bytes of garbage: the size check passes and the python verify
# actually fires, so the test exercises the signature path rather than being
# short-circuited by the resource bound.
head -c 64 /dev/zero | tr '\0' X > "$RELEASES/Glyndor__podup/SHA256SUMS.sig"
new_root "$WORK/r3"
generator_with "$WORK/r3/scripts/release/render-formulae.sh" "$PODUP"
rc=0; run "$WORK/r3/scripts/release/render-formulae.sh" "$WORK/r3" || rc=$?
check "an unverifiable signature skips the product" "3" "$rc"
check "and writes no formula" "0" "$(find "$WORK/r3/Formula" -name '*.rb' | wc -l)"

# An asset the table names but the verified manifest does not list.
publish Glyndor/podup v9.9.9 podup-darwin-arm64
new_root "$WORK/r4"
generator_with "$WORK/r4/scripts/release/render-formulae.sh" "$PODUP"
rc=0; run "$WORK/r4/scripts/release/render-formulae.sh" "$WORK/r4" || rc=$?
check "an asset missing from the manifest skips the product" "3" "$rc"
check "and writes no formula" "0" "$(find "$WORK/r4/Formula" -name '*.rb' | wc -l)"

# A product whose release cannot be read at all.
new_root "$WORK/r5"
generator_with "$WORK/r5/scripts/release/render-formulae.sh" \
	"Glyndor/nothing-here|nothing|Nothing|MIT|d|a-arm64|a-x86_64|-|-|--version"
rc=0; run "$WORK/r5/scripts/release/render-formulae.sh" "$WORK/r5" || rc=$?
check "an unreadable release skips the product" "3" "$rc"

# A table row with a field missing is named, not rendered from empty values.
new_root "$WORK/r6"
generator_with "$WORK/r6/scripts/release/render-formulae.sh" \
	"Glyndor/podup|podup|Podup|MIT|d|podup-darwin-arm64|podup-darwin-x86_64|-|-"
rc=0; run "$WORK/r6/scripts/release/render-formulae.sh" "$WORK/r6" || rc=$?
check "a short table row is rejected" "3" "$rc"
contains "and the missing field is named" "$WORK/out" "has no version_check"

# --- one product must not take down another ---------------------------------

publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
new_root "$WORK/r7"
generator_with "$WORK/r7/scripts/release/render-formulae.sh" \
	"Glyndor/nothing-here|ghostly|Ghostly|MIT|d|a-arm64|a-x86_64|-|-|--version" "$PODUP"
printf 'PRE-EXISTING\n' > "$WORK/r7/Formula/ghostly.rb"
rc=0; run "$WORK/r7/scripts/release/render-formulae.sh" "$WORK/r7" || rc=$?
check "a broken product does not stop a good one" "1" \
	"$(grep -c 'download/v9.9.9/podup-darwin-arm64' "$WORK/r7/Formula/podup.rb")"
check "the run still fails, so the skip is not silent" "3" "$rc"
check "the skipped product keeps the formula it had" "PRE-EXISTING" \
	"$(cat "$WORK/r7/Formula/ghostly.rb")"

# --- pruning ----------------------------------------------------------------

new_root "$WORK/r8"
generator_with "$WORK/r8/scripts/release/render-formulae.sh" "$PODUP"
printf 'stale\n' > "$WORK/r8/Formula/gone.rb"
rc=0; run "$WORK/r8/scripts/release/render-formulae.sh" "$WORK/r8" || rc=$?
check "pruning a dropped product exits 0" "0" "$rc"
check "the dropped product's formula is gone" "0" \
	"$(find "$WORK/r8/Formula" -name 'gone.rb' | wc -l)"
check "the declared product's formula stays" "1" \
	"$(find "$WORK/r8/Formula" -name 'podup.rb' | wc -l)"

# --- two healthy products together -------------------------------------------
# The plain multi-product case: the suite otherwise only ever pairs a good
# product with a broken one, and this is the shape the second real product takes.

publish Glyndor/podup v1.2.3 podup-darwin-arm64 podup-darwin-x86_64
publish Glyndor/other v4.5.6 other-darwin-arm64 other-darwin-x86_64
new_root "$WORK/r12"
generator_with "$WORK/r12/scripts/release/render-formulae.sh" \
	"Glyndor/podup|podup|Podup|MIT|first|podup-darwin-arm64|podup-darwin-x86_64|-|-|--version" \
	"Glyndor/other|other|Other|Apache-2.0|second|other-darwin-arm64|other-darwin-x86_64|-|-|-V"
rc=0; run "$WORK/r12/scripts/release/render-formulae.sh" "$WORK/r12" || rc=$?
check "two healthy products both render, exit 0" "0" "$rc"
check "both formulae exist" "2" "$(find "$WORK/r12/Formula" -name '*.rb' | wc -l)"
contains "each gets its own version, through its url" "$WORK/r12/Formula/podup.rb" \
	'url "https://github.com/Glyndor/podup/releases/download/v1.2.3/podup-darwin-arm64"'
contains "including the second" "$WORK/r12/Formula/other.rb" \
	'url "https://github.com/Glyndor/other/releases/download/v4.5.6/other-darwin-arm64"'
contains "each gets its own licence" "$WORK/r12/Formula/other.rb" 'license "Apache-2.0"'
contains "and its own version check" "$WORK/r12/Formula/other.rb" 'system "#{bin}/other", "-V"'
contains "the first is untouched by the second" "$WORK/r12/Formula/podup.rb" 'license "MIT"'

# --- a product that ships one architecture ----------------------------------
# klyradb publishes a single Windows build and a single macOS one; before this,
# a row had to name both assets, so such a product could not be carried at all.

publish Glyndor/single v2.0.0 single-darwin-x86_64
new_root "$WORK/r13"
generator_with "$WORK/r13/scripts/release/render-formulae.sh" \
	"Glyndor/single|single|Single|MIT|intel only|-|single-darwin-x86_64|-|-|--version"
rc=0; run "$WORK/r13/scripts/release/render-formulae.sh" "$WORK/r13" || rc=$?
check "an intel-only product renders, exit 0" "0" "$rc"
S="$WORK/r13/Formula/single.rb"
contains "the intel block is present" "$S" 'url "https://github.com/Glyndor/single/releases/download/v2.0.0/single-darwin-x86_64"'
check "and no arm block is emitted" "0" "$(grep -c 'on_arm' "$S")"
contains "install names the one asset" "$S" 'asset = "single-darwin-x86_64"'
check "with no Hardware::CPU branch" "0" "$(grep -c 'Hardware::CPU' "$S")"

publish Glyndor/single v2.0.0 single-darwin-arm64
new_root "$WORK/r14"
generator_with "$WORK/r14/scripts/release/render-formulae.sh" \
	"Glyndor/single|single|Single|MIT|arm only|single-darwin-arm64|-|-|-|--version"
rc=0; run "$WORK/r14/scripts/release/render-formulae.sh" "$WORK/r14" || rc=$?
check "an arm-only product renders, exit 0" "0" "$rc"
S="$WORK/r14/Formula/single.rb"
check "and no intel block is emitted" "0" "$(grep -c 'on_intel' "$S")"
contains "install names the one asset" "$S" 'asset = "single-darwin-arm64"'

# "-" must not become a way to publish nothing at all.
new_root "$WORK/r15"
generator_with "$WORK/r15/scripts/release/render-formulae.sh" \
	"Glyndor/single|single|Single|MIT|neither|-|-|-|-|--version"
rc=0; run "$WORK/r15/scripts/release/render-formulae.sh" "$WORK/r15" || rc=$?
check "a row publishing neither architecture is rejected" "3" "$rc"
contains "and says so" "$WORK/out" "publishes no asset for any platform"

# An empty field is a dropped column, not a declaration.
new_root "$WORK/r16"
generator_with "$WORK/r16/scripts/release/render-formulae.sh" \
	"Glyndor/single|single|Single|MIT|empty arm||single-darwin-x86_64|-|-|--version"
rc=0; run "$WORK/r16/scripts/release/render-formulae.sh" "$WORK/r16" || rc=$?
check "an EMPTY field is still an error, not a declaration" "3" "$rc"
contains "and names the field" "$WORK/out" "has no mac_arm"

# A declared architecture that does not arrive stays a hard error.
publish Glyndor/single v2.0.0 single-darwin-x86_64
new_root "$WORK/r17"
generator_with "$WORK/r17/scripts/release/render-formulae.sh" \
	"Glyndor/single|single|Single|MIT|arm declared|single-darwin-arm64|single-darwin-x86_64|-|-|--version"
rc=0; run "$WORK/r17/scripts/release/render-formulae.sh" "$WORK/r17" || rc=$?
check "a DECLARED architecture that is missing still fails" "3" "$rc"

# --- Linux -------------------------------------------------------------------
#
# Everything above this line passed while the generator could only render
# macOS, so none of it says anything about Linux.

publish Glyndor/both v3.0.0 \
	both-darwin-arm64 both-darwin-x86_64 both-linux-arm64 both-linux-x86_64
new_root "$WORK/r18"
generator_with "$WORK/r18/scripts/release/render-formulae.sh" \
	"Glyndor/both|both|Both|MIT|two platforms|both-darwin-arm64|both-darwin-x86_64|both-linux-arm64|both-linux-x86_64|--version"
rc=0; run "$WORK/r18/scripts/release/render-formulae.sh" "$WORK/r18" || rc=$?
check "a product shipping both platforms renders, exit 0" "0" "$rc"
B="$WORK/r18/Formula/both.rb"
check "an on_macos block is emitted" "1" "$(grep -c 'on_macos do' "$B")"
check "an on_linux block is emitted" "1" "$(grep -c 'on_linux do' "$B")"
contains "the linux arm url points at the linux asset" "$B" \
	'url "https://github.com/Glyndor/both/releases/download/v3.0.0/both-linux-arm64"'
contains "the linux intel url points at the linux asset" "$B" \
	'url "https://github.com/Glyndor/both/releases/download/v3.0.0/both-linux-x86_64"'

# The bug this section exists for. Before Linux was rendered, install picked on
# architecture alone and BOTH arms of the ternary named a darwin asset. A Linux
# machine would have downloaded the correct binary from the on_linux url and
# then looked on disk for a file called both-darwin-*, which is not there --
# `brew install` failing after a successful download, on the platform the whole
# change exists to serve.
contains "install branches on the operating system" "$B" 'asset = if OS.mac?'
check "and the linux arm names no darwin asset" "0" \
	"$(sed -n '/else/,/end/p' "$B" | grep -c 'darwin')"
check "and the macos arm names no linux asset" "0" \
	"$(sed -n '/asset = if OS.mac?/,/else/p' "$B" | grep -c 'linux')"

# Linux-only: the mirror of the macOS-only case every other test covers. A
# product with no macOS build must not emit an empty on_macos block, and must
# not ask OS.mac? when there is only one answer.
publish Glyndor/lin v1.2.3 lin-linux-x86_64
new_root "$WORK/r19"
generator_with "$WORK/r19/scripts/release/render-formulae.sh" \
	"Glyndor/lin|lin|Lin|MIT|linux only|-|-|-|lin-linux-x86_64|--version"
rc=0; run "$WORK/r19/scripts/release/render-formulae.sh" "$WORK/r19" || rc=$?
check "a linux-only product renders, exit 0" "0" "$rc"
L="$WORK/r19/Formula/lin.rb"
check "no on_macos block is emitted" "0" "$(grep -c 'on_macos' "$L")"
check "an on_linux block is emitted" "1" "$(grep -c 'on_linux do' "$L")"
check "and no OS branch, since there is one platform" "0" "$(grep -c 'OS.mac?' "$L")"
check "and no architecture branch, since there is one arch" "0" \
	"$(grep -c 'Hardware::CPU' "$L")"
contains "install names the one asset" "$L" 'asset = "lin-linux-x86_64"'

# A declared Linux asset that the signed SHA256SUMS does not list is the same
# hard error as a declared macOS one. Asserted separately because the check is
# a separate call: the platform helper is invoked twice, and a guard that was
# only wired into the first call would pass everything above.
publish Glyndor/lin v1.2.3 lin-linux-x86_64
new_root "$WORK/r20"
generator_with "$WORK/r20/scripts/release/render-formulae.sh" \
	"Glyndor/lin|lin|Lin|MIT|missing arm|-|-|lin-linux-arm64|lin-linux-x86_64|--version"
rc=0; run "$WORK/r20/scripts/release/render-formulae.sh" "$WORK/r20" || rc=$?
check "a DECLARED linux asset that is missing fails" "3" "$rc"
contains "and names the asset it could not find" "$WORK/out" "lin-linux-arm64"
check "and no formula is written" "0" \
	"$([ -f "$WORK/r20/Formula/lin.rb" ] && echo 1 || echo 0)"

# The single-architecture shape is one CI's `brew style` never sees: that job
# runs over Formula/ in the repository, which carries only the two-architecture
# podup. Validate it here when a validator exists, and say so when none does:
# skipping silently would leave the new shape unchecked everywhere.
if command -v brew >/dev/null 2>&1; then
	rc=0
	brew style "$WORK/r18/Formula/both.rb" >"$WORK/style" 2>&1 || rc=$?
	check "brew style accepts a two-platform formula" "0" "$rc"
	rc=0
	brew style "$WORK/r19/Formula/lin.rb" >>"$WORK/style" 2>&1 || rc=$?
	check "brew style accepts a linux-only formula" "0" "$rc"
	rc=0
	brew style "$WORK/r13/Formula/single.rb" >>"$WORK/style" 2>&1 || rc=$?
	check "brew style accepts an intel-only formula" "0" "$rc"
	rc=0
	brew style "$WORK/r14/Formula/single.rb" >>"$WORK/style" 2>&1 || rc=$?
	check "brew style accepts an arm-only formula" "0" "$rc"
elif command -v ruby >/dev/null 2>&1; then
	rc=0; ruby -c "$WORK/r18/Formula/both.rb" >/dev/null 2>&1 || rc=$?
	check "the two-platform formula is syntactically valid Ruby" "0" "$rc"
	rc=0; ruby -c "$WORK/r19/Formula/lin.rb" >/dev/null 2>&1 || rc=$?
	check "the linux-only formula is syntactically valid Ruby" "0" "$rc"
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
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
