#!/usr/bin/env bash
#
# Install a formula from the published tap with Homebrew, as a user does, and upgrade it from the version before.
#
# Usage: install-from-the-tap.sh <formula>      (run at the root of a checkout with the history of main)
#
# `brew style` and `brew audit` read the formula as text. This runs it:
#   1. the tap is added, the formula installed, the version it installed is the one `brew info` reports, the
#      program prints that version, and `brew test` of the formula passes;
#   2. the formula is put back to the commit before (the commit found by previous-formula.sh, copied over the
#      file of the tap clone, which is what a machine that had not run `brew update` yet holds), installed, and
#      the version it installed is that commit's;
#   3. the current formula is put back and `brew upgrade` is run, which has to leave the current version
#      installed, the program printing it, and `brew test` passing again.
# With no earlier version in the history there is nothing to upgrade from: the script exits 3, which is not a
# pass. Any other failure exits 1.
#
# Environment: TAP (default glyndor/tap), and Homebrew's own HOMEBREW_NO_AUTO_UPDATE and HOMEBREW_NO_ANALYTICS,
# which the workflow sets so that nothing updates the tap under the test.
set -euo pipefail

formula="${1:?usage: install-from-the-tap.sh <formula>}"
tap="${TAP:-glyndor/tap}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
file="Formula/$formula.rb"

fail() {
	echo "::error::install-from-the-tap: $*" >&2
	exit 1
}

installed() { brew list --versions "$formula" 2>/dev/null | awk '{ print $NF }' | head -n 1; }
starts() { # the program prints the version it was asked for
	local want="$1" out
	out="$("$formula" --version 2>&1)" || fail "$formula does not start: $out"
	case "$out" in *"$want"*) ;; *) fail "$formula prints \"$out\", which does not hold $want" ;; esac
}

brew tap "$tap" || fail "the tap $tap cannot be added"
# Homebrew loads the formulae of a tap that is not its own only once the tap is trusted ("Refusing to load formula
# from untrusted tap"), and `brew trust` is the command it documents for that. It names this tap and nothing else,
# in the trust store of the runner, which is a machine that is thrown away; no global check is turned off.
brew trust --tap "$tap" || fail "the tap $tap cannot be trusted, so brew would refuse to load its formulae"
dir="$(brew --repository "$tap")" || fail "the clone of $tap cannot be found"
[ -d "$dir" ] || fail "the clone of $tap is not a folder: $dir"
current="$(git -C "$dir" rev-parse HEAD)" || fail "the clone of $tap has no HEAD"

want="$(brew info --json=v2 "$tap/$formula" | jq -r '.formulae[0].versions.stable // empty')" || want=""
[ -n "$want" ] || fail "brew does not report a stable version of $tap/$formula"

brew install "$tap/$formula" || fail "brew install $tap/$formula failed"
[ "$(installed)" = "$want" ] || fail "brew installed $formula $(installed), not the $want its formula declares"
starts "$want"
brew test "$tap/$formula" || fail "brew test $tap/$formula failed"
echo "install-from-the-tap: $formula $want installs from $tap, starts and passes its test"

if ! prev="$(bash "$here/previous-formula.sh" "$file")"; then
	echo "install-from-the-tap: NOT VERIFIED: no earlier version of $file in the history, so an upgrade cannot be tried" >&2
	exit 3
fi
sha="${prev%% *}"
before="${prev##* }"
git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null || git -C "$dir" fetch --quiet origin "$sha" || fail "the commit $sha of $file is not in the clone of $tap"

brew uninstall --formula "$formula" || fail "brew uninstall $formula failed"
git -C "$dir" checkout --quiet "$sha" -- "$file" || fail "the formula of $sha cannot be put in the clone of $tap"
brew install "$tap/$formula" || fail "brew install of the formula of $sha failed"
[ "$(installed)" = "$before" ] || fail "the formula of $sha installed $formula $(installed), not its $before"
starts "$before"
echo "install-from-the-tap: $formula $before installed from the formula of ${sha:0:7}"

git -C "$dir" checkout --quiet "$current" -- "$file" || fail "the current formula cannot be put back in the clone of $tap"
brew upgrade "$tap/$formula" || fail "brew upgrade $tap/$formula failed"
[ "$(installed)" = "$want" ] || fail "after brew upgrade $formula is $(installed), not $want"
starts "$want"
brew test "$tap/$formula" || fail "brew test $tap/$formula failed after the upgrade"
echo "install-from-the-tap: $formula went from $before to $want with brew upgrade, starts and passes its test"
