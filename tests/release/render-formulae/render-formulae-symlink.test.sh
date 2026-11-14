#!/usr/bin/env bash
#
# The renderer never writes a formula where it does not belong. Three shapes
# reached the same outcome -- a render that said "rendered" while the tap
# stayed exactly as it was, and not one red check to say so:
#
#   * a symlink in Formula/. Redirecting straight into Formula/<name>.rb
#     followed the link: Formula/ kept only the link, update.yml saw no
#     change to commit, and the tap stayed frozen. The renderer refuses the
#     link, names it, skips that product (exit 3) and leaves what the link
#     points at untouched.
#
#   * a directory where a formula belongs. `mv` reads a directory destination
#     as a place to put the file inside, so the rendered formula was moved to
#     Formula/<name>.rb/.render.XXXXXX and the run reported success. The
#     renderer refuses the directory, names it and skips that product.
#
#   * a Formula/ that is a symlink. Every write then lands outside the
#     repository, and `mkdir -p` is happy with a link to a directory, so
#     nothing else in the run would have noticed. The renderer refuses
#     before it writes anything.
#
# The temporary the formula is written through is not left inside Formula/
# either: update.yml commits every untracked file under Formula/, so one left
# there by an interrupted run would be published as part of the tap.
#
# Each case has its control: the same setup against a generator with that one
# guard removed, which has to show the failure the guard prevents.
#
# The fixture both this file and its siblings need lives in
# tests/fixtures/release/render-fixture.sh.

set -euo pipefail

HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../fixtures/release" && pwd)"
# shellcheck disable=SC1091
. "$HERE_FIXTURE/render-fixture.sh"
pass=0
fail=0

unset ATTEST_STUB_OUTCOME

# render <root>: the ordinary product row rendered into an existing root, exit
# status in $rc and output in $out.
render() {
	local root="$1"
	generator_with "$root/scripts/release/render-formulae.sh" "$PODUP"
	rc=0
	out="$( cd "$root" && "$root/scripts/release/render-formulae.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
}

# run_directly <root>: the generator already in that root, run as it is. The
# controls below patch the generator first, and render() would copy the
# pristine one over the patch before running it.
run_directly() {
	local root="$1"
	rc=0
	out="$( cd "$root" && "$root/scripts/release/render-formulae.sh" --pubkey "$PUBKEY" 2>&1 )" || rc=$?
}

publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64

# --- the control: a regular formula is replaced in place ----------------------

new_root "$WORK/plain"
render "$WORK/plain"
check "control: an ordinary release renders" "0" "$rc"
check "control: and leaves no temporary file behind" "0" "$(find "$WORK/plain/Formula" -name '.render.*' | wc -l)"
render "$WORK/plain"
check "control: and renders over its own formula" "0" "$rc"

# --- a formula that is a symlink ----------------------------------------------

new_root "$WORK/link"
render "$WORK/link"
mv "$WORK/link/Formula/podup.rb" "$WORK/outside.rb"
echo '# kept as it was' >> "$WORK/outside.rb"
ln -s "$WORK/outside.rb" "$WORK/link/Formula/podup.rb"
before="$(cksum <"$WORK/outside.rb")"
render "$WORK/link"
check "a symlinked formula skips the product (exit 3)" "3" "$rc"
check "and the message names the symlink" "1" "$(grep -c 'Formula/podup.rb is a symlink' <<<"$out")"
check "and the file the link points at is untouched" "$before" "$(cksum <"$WORK/outside.rb")"
check "and Formula/ still holds the link, not a rendered file" "1" "$([ -L "$WORK/link/Formula/podup.rb" ] && echo 1 || echo 0)"
check "and no temporary file is left" "0" "$(find "$WORK/link/Formula" -name '.render.*' | wc -l)"

# --- a write that fails --------------------------------------------------------
#
# render_product runs under `if !`, which turns errexit off for its whole body,
# so an unchecked `cat >"$tmp"` left a truncated file that `mv` then installed
# while the run said "rendered". The scoop renderer already checked its write.
# A `cat` that fails when it is given no file (the heredoc case) stands in for a
# full disk; any other use of cat passes through to the real one.
mkdir -p "$WORK/failcat"
REAL_CAT="$(command -v cat)"
cat > "$WORK/failcat/cat" <<SHIM
#!/bin/sh
[ "\$#" -eq 0 ] && exit 1
exec "$REAL_CAT" "\$@"
SHIM
chmod +x "$WORK/failcat/cat"
new_root "$WORK/full"
PATH="$WORK/failcat:$PATH" render "$WORK/full"
check "a failed write stops the product" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and the message says the formula could not be written" "1" "$(grep -c 'could not write the rendered Formula/podup.rb' <<<"$out")"
check "and no formula is installed" "0" "$(find "$WORK/full/Formula" -name 'podup.rb' | wc -l)"
check "and no temporary file is left" "0" "$(find "$WORK/full/Formula" -name '.render.*' | wc -l)"

# The control: with the unchecked write the same failure installs an empty formula.
new_root "$WORK/unguarded"
generator_with "$WORK/unguarded/scripts/release/render-formulae.sh" "$PODUP"
python3 - "$WORK/unguarded/scripts/release/render-formulae.sh" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s, n = re.subn(r'<<RB \|\| \{[^\n]*\}', '<<RB', s, count=1)
assert n == 1
open(p, 'w').write(s)
PY
rc=0
( cd "$WORK/unguarded" && PATH="$WORK/failcat:$PATH" "$WORK/unguarded/scripts/release/render-formulae.sh" --pubkey "$PUBKEY" >/dev/null 2>&1 ) || rc=$?
check "control: without the check the failure installs an empty formula" "0 1" \
	"$rc $([ -e "$WORK/unguarded/Formula/podup.rb" ] && [ ! -s "$WORK/unguarded/Formula/podup.rb" ] && echo 1 || echo 0)"

# --- a formula that is a directory ---------------------------------------------
#
# `mv` reads a directory destination as a place to put the file inside, so the
# rendered formula was moved to Formula/podup.rb/.render.XXXXXX and the run
# said "rendered". The tap kept a directory where a formula belongs, update.yml
# saw no change to commit, and the formula the tap served was the one that was
# already there.
new_root "$WORK/dir"
render "$WORK/dir"
rm "$WORK/dir/Formula/podup.rb"
mkdir "$WORK/dir/Formula/podup.rb"
render "$WORK/dir"
check "a formula that is a directory skips the product (exit 3)" "3" "$rc"
check "and the message names the directory" "1" "$(grep -c 'Formula/podup.rb is a directory' <<<"$out")"
check "and the directory is still there, holding nothing" "1 0" \
	"$([ -d "$WORK/dir/Formula/podup.rb" ] && echo 1 || echo 0) $(find "$WORK/dir/Formula/podup.rb" -mindepth 1 | wc -l)"
check "and no temporary file is left" "0" "$(find "$WORK/dir/Formula" -name '.render.*' | wc -l)"

# The control: without the check the formula is moved inside the directory and
# the run reports success.
new_root "$WORK/dirnoguard"
mkdir "$WORK/dirnoguard/Formula/podup.rb"
generator_with "$WORK/dirnoguard/scripts/release/render-formulae.sh" "$PODUP"
python3 - "$WORK/dirnoguard/scripts/release/render-formulae.sh" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s, n = re.subn(r'\n\tif \[ -d "\$target" \]; then\n\t\techo [^\n]*\n\t\treturn 1\n\tfi', '', s, count=1)
assert n == 1
open(p, 'w').write(s)
PY
run_directly "$WORK/dirnoguard"
check "control: without the check the run reports success" "0" "$rc"
check "control: and the rendered formula lands inside the directory" "1" \
	"$(find "$WORK/dirnoguard/Formula/podup.rb" -mindepth 1 | wc -l)"

# --- a Formula/ that is a symlink ----------------------------------------------
#
# Every formula is written under Formula/. If that directory is a symlink, all
# of those writes land outside the repository: the render reported success,
# the tap never changed, and the formula the tap served was whatever the link
# pointed at. `mkdir -p` is happy with a link to a directory, so nothing else
# in the run would have noticed.
new_root "$WORK/linkdir"
rmdir "$WORK/linkdir/Formula"
mkdir -p "$WORK/outside"
ln -s "$WORK/outside" "$WORK/linkdir/Formula"
render "$WORK/linkdir"
check "a symlinked Formula/ stops the run (exit 1)" "1" "$rc"
check "and the message names the symlink" "1" "$(grep -c 'Formula/ is a symlink' <<<"$out")"
check "and nothing is written outside the repository" "0" "$(find "$WORK/outside" -mindepth 1 | wc -l)"
check "and Formula/ is still the link" "1" "$([ -L "$WORK/linkdir/Formula" ] && echo 1 || echo 0)"

# The control: without the check the formula is written through the link.
new_root "$WORK/linkdirnoguard"
rmdir "$WORK/linkdirnoguard/Formula"
mkdir -p "$WORK/outside2"
ln -s "$WORK/outside2" "$WORK/linkdirnoguard/Formula"
generator_with "$WORK/linkdirnoguard/scripts/release/render-formulae.sh" "$PODUP"
python3 - "$WORK/linkdirnoguard/scripts/release/render-formulae.sh" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s, n = re.subn(r'\nif \[ -L "\$root/Formula" \]; then\n\techo [^\n]*\n\texit 1\nfi', '', s, count=1)
assert n == 1
open(p, 'w').write(s)
PY
run_directly "$WORK/linkdirnoguard"
check "control: without the check the formula is written outside the repository" "1" \
	"$([ -f "$WORK/outside2/podup.rb" ] && echo 1 || echo 0)"

# --- the temporary is not created inside Formula/ --------------------------------
#
# update.yml commits every untracked file under Formula/, so a temporary left
# there by an interrupted run would be published as part of the tap, and
# `brew style` would read it. The template handed to mktemp is watched here,
# so the case says where the temporary is asked for and not only that the run
# ended clean.
mkdir -p "$WORK/mktemplog"
REAL_MKTEMP="$(command -v mktemp)"
cat > "$WORK/mktemplog/mktemp" <<SHIM
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/mktemplog/calls"
exec "$REAL_MKTEMP" "\$@"
SHIM
chmod +x "$WORK/mktemplog/mktemp"
new_root "$WORK/temp"
PATH="$WORK/mktemplog:$PATH" render "$WORK/temp"
check "a render with the temporary watched succeeds" "0" "$rc"
check "and no temporary is asked for inside Formula/" "0" \
	"$(grep -c '/Formula/' "$WORK/mktemplog/calls" || true)"

# The control: without the change the temporary is asked for inside Formula/.
new_root "$WORK/tempnoguard"
generator_with "$WORK/tempnoguard/scripts/release/render-formulae.sh" "$PODUP"
python3 - "$WORK/tempnoguard/scripts/release/render-formulae.sh" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s, n = re.subn(r'mktemp "\$root/\.render\.XXXXXX"', 'mktemp "$root/Formula/.render.XXXXXX"', s, count=1)
assert n == 1
open(p, 'w').write(s)
PY
: > "$WORK/mktemplog/calls"
PATH="$WORK/mktemplog:$PATH" run_directly "$WORK/tempnoguard"
check "control: without the change the temporary is asked for inside Formula/" "1" \
	"$(grep -c '/Formula/' "$WORK/mktemplog/calls" || true)"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
