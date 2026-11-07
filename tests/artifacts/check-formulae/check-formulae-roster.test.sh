#!/usr/bin/env bash
#
# Tests for the roster shapes of scripts/artifacts/check-formulae.py.
#
# render-formulae.sh refuses a roster row whose repository is outside the
# organization or whose names would write outside Formula/ or add Ruby. The
# check used to compare the formula with the row without asking whether the row
# itself was admissible, so a row naming another organization passed both gates
# the renderer refuses it at. Each case plants one such row in a copy of the
# renderer and the check must say what is wrong with it. Then the same rows go
# to a copy of the check with those tests removed, and the messages must be
# absent there: the refusal was the check's.
#
# Requires: python3.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
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

mktree() { # $1=name -> a tree with the real check, renderer and formula
	local t="$WORK/$1"
	mkdir -p "$t/scripts/artifacts" "$t/scripts/release" "$t/Formula"
	cp "$HERE/scripts/artifacts/check-formulae.sh" "$HERE/scripts/artifacts/check-formulae.py" "$t/scripts/artifacts/"
	cp "$HERE/scripts/release/render-formulae.sh" "$t/scripts/release/"
	cp "$HERE/Formula/podup.rb" "$t/Formula/podup.rb"
	echo "$t"
}
gate() { "$1/scripts/artifacts/check-formulae.sh" "$1" >"$WORK/out" 2>&1; }
said() { grep -qF "$1" "$WORK/out" && echo 1 || echo 0; }

# The roster row is edited in the renderer copy; the formula stays as committed.
plant() { # $1=tree $2=old $3=new
	python3 -I - "$1/scripts/release/render-formulae.sh" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert old in s, "the roster row does not contain " + old
open(p, "w").write(s.replace(old, new, 1))
PY
}

T="$(mktree good)"
rc=0; gate "$T" || rc=$?
check "the committed roster is accepted" "0" "$rc"

CASES=(
	$'a repository outside the organization\t"Glyndor/podup\t"EvilCorp/podup\toutside the Glyndor organization'
	$'a repository with a space in it\t"Glyndor/podup\t"Glyndor/pod up\tan invalid repository'
	$'an upper-case formula name\tGlyndor/podup|podup|Podup\tGlyndor/podup|Podup|Podup\tan invalid formula name'
	$'a class name with an underscore\t|podup|Podup|MIT\t|podup|Podup_2|MIT\tan invalid class name'
	$'an asset name with a slash\tpodup-darwin-arm64\tpodup/darwin-arm64\tan invalid asset name in mac_arm'
)
for entry in "${CASES[@]}"; do
	IFS=$'\t' read -r label old new text <<<"$entry"
	T="$(mktree "bad-$(echo "$label" | tr -c 'a-z\n' _)")"; plant "$T" "$old" "$new"
	rc=0; gate "$T" || rc=$?
	check "$label is refused" "1" "$rc"
	check "  and the error says why ($text)" "1" "$(said "$text")"
done

# The control: the same rows, the shape tests removed. Each message must be
# gone, or the cases above were passing on something else.
S="$(mktree sabotaged)"
python3 -I - "$HERE/scripts/artifacts/check-formulae.py" "$S/scripts/artifacts/check-formulae.py" <<'PY'
import sys
s = open(sys.argv[1]).read()
for old, new in (("if not shape.fullmatch(row[name]):", "if False:"),
                 ('if not row["repo"].startswith("Glyndor/"):', "if False:"),
                 ('if row[name] != "-" and not ASSET_RE.fullmatch(row[name]):', "if False:")):
    assert old in s, old
    s = s.replace(old, new, 1)
open(sys.argv[2], "w").write(s)
PY
for entry in "${CASES[@]}"; do
	IFS=$'\t' read -r label old new text <<<"$entry"
	cp "$HERE/scripts/release/render-formulae.sh" "$S/scripts/release/render-formulae.sh"; plant "$S" "$old" "$new"
	rc=0; gate "$S" || rc=$?
	check "without the shape tests, $label no longer says why" "0" "$(said "$text")"
done

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
