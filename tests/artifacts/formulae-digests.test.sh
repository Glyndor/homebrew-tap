#!/usr/bin/env bash
#
# Tests for scripts/artifacts/formulae-digests.sh, the manifest that lets the
# commit job of update.yml refuse bytes the render job did not produce.
#
# The commit job is the only job holding the updater app's key, and the
# validation job between it and the render runs Homebrew's gems. What this
# script decides is whether the files about to be committed are the rendered
# ones, so every case that must be refused is planted here and has to fail with
# its own message, and a refused `place` has to leave the checkout untouched.
#
# Requires: coreutils.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
DIGESTS="$HERE/scripts/artifacts/formulae-digests.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# A tree with two formulae, written so that bytewise order and the order a
# locale would pick can differ (an upper-case name sorts first in C).
tree() { # $1=dir
	rm -rf "$1"; mkdir -p "$1/Formula"
	printf 'class Podup < Formula\nend\n' > "$1/Formula/podup.rb"
	printf 'class Bbb < Formula\nend\n' > "$1/Formula/B-tool.rb"
}

run() { # <args...>; sets rc and leaves the output in $WORK/out
	rc=0
	bash "$DIGESTS" "$@" > "$WORK/out" 2>&1 || rc=$?
}

said() { # <text>
	grep -cF -- "$1" "$WORK/out"
}

# --- list ---------------------------------------------------------------------

tree "$WORK/a"
run list "$WORK/a"
check "a tree with two formulae lists" "0" "$rc"
check "one line per file" "2" "$(wc -l < "$WORK/out" | tr -d ' ')"
check "in bytewise order" "Formula/B-tool.rb Formula/podup.rb" "$(awk '{print $2}' "$WORK/out" | tr '\n' ' ' | sed 's/ $//')"
check "each line is the file's SHA-256 and its path" \
	"$(cd "$WORK/a" && sha256sum Formula/podup.rb)" "$(grep -F 'Formula/podup.rb' "$WORK/out")"
cp "$WORK/out" "$WORK/a.sha256"
check "and sha256sum -c accepts the manifest" "0" \
	"$(cd "$WORK/a" && sha256sum --quiet -c "$WORK/a.sha256" >/dev/null 2>&1; echo $?)"

mkdir -p "$WORK/a/Formula/nested"
printf 'x\n' > "$WORK/a/Formula/nested/deep.rb"
run list "$WORK/a"
check "a file at any depth is listed" "1" "$(said 'Formula/nested/deep.rb')"
rm -rf "$WORK/a/Formula/nested"

run list "$WORK/missing"
check "a root with no Formula/ is refused" "1" "$rc"
check "and the message says so" "1" "$(said 'is missing or is not a directory')"

mkdir -p "$WORK/link/real"
ln -s real "$WORK/link/Formula"
run list "$WORK/link"
check "a Formula/ that is a symlink is refused" "1" "$rc"
check "and the message names it" "1" "$(said 'Formula is a symlink')"

tree "$WORK/sym"
ln -s podup.rb "$WORK/sym/Formula/alias.rb"
run list "$WORK/sym"
check "a symlink inside Formula/ is refused" "1" "$rc"
check "and the message names the entry" "1" "$(said 'Formula/alias.rb is neither a regular file nor a directory')"

tree "$WORK/nl"
printf 'x\n' > "$WORK/nl/Formula/two
lines.rb"
run list "$WORK/nl"
check "a path with a newline is refused" "1" "$rc"
check "and the message names the character set" "1" "$(said 'outside [A-Za-z0-9._+@/-]')"

tree "$WORK/sp"
printf 'x\n' > "$WORK/sp/Formula/a b.rb"
run list "$WORK/sp"
check "a path with a space is refused" "1" "$rc"

mkdir -p "$WORK/empty/Formula/sub"
run list "$WORK/empty"
check "a Formula/ with no file is refused" "1" "$rc"
check "and the message says an empty tap is not recorded" "1" "$(said 'refusing to record an empty tap')"

# --- check --------------------------------------------------------------------

tree "$WORK/c"
bash "$DIGESTS" list "$WORK/c" > "$WORK/c.sha256"
run check "$WORK/c" "$WORK/c.sha256"
check "the tree that was recorded passes" "0" "$rc"
check "and says how many files matched" "1" "$(said '2 file(s) under')"

printf '# one more byte\n' >> "$WORK/c/Formula/podup.rb"
run check "$WORK/c" "$WORK/c.sha256"
check "a changed byte is refused" "1" "$rc"
check "and the message says the files are not the recorded ones" "1" \
	"$(said 'are not the ones the render job recorded')"
check "and the difference names the file" "1" "$(grep -c 'Formula/podup.rb' "$WORK/out" | awk '{print ($1 >= 1)}')"

tree "$WORK/c"
printf 'class Extra < Formula\nend\n' > "$WORK/c/Formula/extra.rb"
run check "$WORK/c" "$WORK/c.sha256"
check "a file added after the record is refused" "1" "$rc"

tree "$WORK/c"
rm "$WORK/c/Formula/B-tool.rb"
run check "$WORK/c" "$WORK/c.sha256"
check "a file missing from the tree is refused" "1" "$rc"

tree "$WORK/c"
: > "$WORK/empty.sha256"
run check "$WORK/c" "$WORK/empty.sha256"
check "an empty expected manifest is refused" "1" "$rc"
check "and the message names the manifest" "1" "$(said 'is missing or empty')"
run check "$WORK/c" "$WORK/nowhere.sha256"
check "a missing expected manifest is refused" "1" "$rc"

# --- place --------------------------------------------------------------------

tree "$WORK/from"
bash "$DIGESTS" list "$WORK/from" > "$WORK/from.sha256"
mkdir -p "$WORK/root/Formula"
printf 'stale\n' > "$WORK/root/Formula/stale.rb"
run place "$WORK/from" "$WORK/root" "$WORK/from.sha256"
check "placing a recorded tree succeeds" "0" "$rc"
check "and the root now holds exactly the recorded files" "" \
	"$(diff -r "$WORK/from/Formula" "$WORK/root/Formula" 2>&1)"
check "so a file the render removed is gone" "no" "$([ -e "$WORK/root/Formula/stale.rb" ] && echo yes || echo no)"

printf 'class Podup < Formula\n  # tampered\nend\n' > "$WORK/from/Formula/podup.rb"
printf 'mine\n' > "$WORK/root/Formula/keep.rb"
before="$(cd "$WORK/root" && find Formula -type f | sort | xargs sha256sum)"
run place "$WORK/from" "$WORK/root" "$WORK/from.sha256"
check "placing a tampered tree is refused" "1" "$rc"
check "and the checkout is left as it was" "$before" \
	"$(cd "$WORK/root" && find Formula -type f | sort | xargs sha256sum)"

# --- usage ----------------------------------------------------------------------

run frobnicate
check "an unknown mode is refused" "1" "$rc"
run check "$WORK/c"
check "a check without a manifest is refused" "1" "$rc"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
