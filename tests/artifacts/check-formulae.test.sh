#!/usr/bin/env bash
#
# Tests for scripts/artifacts/check-formulae.sh (homebrew-tap#297).
#
# `brew audit` accepts a formula that is well formed and wrong. This check
# holds every formula to what the generator writes for the roster row it names:
# the repository, one tag on every url, the declared assets, the digest shape,
# and no statement the generator does not emit. Each case plants one violation
# in a copy of the committed formula. Then the same planted formulae go to a
# copy of the check whose verdict has been removed, and they must pass there:
# the refusal was the check's, not something else's.
#
# Requires: python3.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
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

# A violation is a python one-liner over the formula text, so the planted file
# differs from the committed one in exactly the way the case names.
plant() { # $1=tree $2=python expression over s
	python3 -I - "$1/Formula/podup.rb" "$2" <<'PY'
import sys
p, expr = sys.argv[1], sys.argv[2]
s = open(p).read()
t = eval(expr)
assert t != s, "the planted formula is identical to the committed one"
open(p, "w").write(t)
PY
}

T="$(mktree good)"
rc=0; gate "$T" || rc=$?
check "the committed formula is accepted" "0" "$rc"

CASES=(
	"another repository|s.replace('Glyndor/podup/releases', 'Glyndor/other-product/releases', 1)|the url names the repository Glyndor/other-product"
	"a second tag|__import__('re').sub(r'/v[0-9][^/]*/podup-linux-arm64', '/v0.0.1/podup-linux-arm64', s)|tag"
	"an asset the row does not declare|s.replace('podup-linux-arm64\"', 'podup-linux-riscv\"', 1)|the url names the asset podup-linux-riscv"
	"an upper-case digest|__import__('re').sub(r'(sha256 .)([0-9a-f]{64})', lambda m: m.group(1) + m.group(2).upper(), s, count=1)|sha256"
	"a short digest|__import__('re').sub(r'(sha256 .)[0-9a-f]{64}', r'\g<1>e73e3a0f', s, count=1)|sha256"
	"a post_install block|s.replace('  def install', '  def post_install\n    system \"sh\", \"-c\", \"id\"\n  end\n\n  def install')|post_install"
	"a depends_on line|s.replace('  on_macos do', '  depends_on \"curl\"\n\n  on_macos do', 1)|depends_on"
	"a resource block|s.replace('  def install', '  resource \"x\" do\n    url \"https://x.example/x.tgz\"\n  end\n\n  def install')|resource"
	"a comment that opens no block, then a swapped asset|s.replace('    on_intel do', '    # do\n    on_intel do', 1).replace('podup-darwin-x86_64\"\n', 'podup-linux-x86_64\"\n', 1)|slot"
	"CRLF line endings|s.replace('\n', '\r\n')|CRLF"
	"a backtick command|s.replace('bin.install asset', '\`id\`; bin.install asset')|\`"
)
for entry in "${CASES[@]}"; do
	IFS='|' read -r label expr text <<<"$entry"
	T="$(mktree "bad-$(echo "$label" | tr -c 'a-z\n' _)")"; plant "$T" "$expr"
	rc=0; gate "$T" || rc=$?
	check "$label is refused" "1" "$rc"
	check "  and the error says why ($text)" "1" "$(said "$text")"
	check "  and the error names Formula/podup.rb" "1" "$(said 'podup.rb')"
done

T="$(mktree ghost)"; cp "$T/Formula/podup.rb" "$T/Formula/ghost.rb"
rc=0; gate "$T" || rc=$?
check "a formula no roster row declares is refused" "1" "$rc"

T="$(mktree nested)"; mkdir -p "$T/Formula/p"; cp "$T/Formula/podup.rb" "$T/Formula/p/extra.rb"
rc=0; gate "$T" || rc=$?
check "a formula one folder down is checked too" "1" "$rc"

# A file name is attacker-controlled text. One carrying a newline and a tab
# must not forge an "ok" record for itself nor hide its own error.
T="$(mktree forged)"; cp "$T/Formula/podup.rb" "$T/Formula/ghost.rb"
cp "$T/Formula/podup.rb" "$T/Formula/$(printf 'x.rb\nok\tpodup.rb')"
rc=0; gate "$T" || rc=$?
check "a file name that forges an ok record is refused" "1" "$rc"
check "  and its name is printed escaped" "1" "$(said 'x.rb\nok\tpodup.rb')"

T="$(mktree link)"; rm "$T/Formula/podup.rb"; ln -s /etc/hostname "$T/Formula/podup.rb"
rc=0; gate "$T" || rc=$?
check "a symlink named like a formula is refused" "1" "$rc"

T="$(mktree empty)"; rm "$T/Formula/podup.rb"
rc=0; gate "$T" || rc=$?
check "an empty tap is an error, not a pass" "1" "$rc"

T="$(mktree no-roster)"; printf '#!/usr/bin/env bash\n' > "$T/scripts/release/render-formulae.sh"
rc=0; gate "$T" || rc=$?
check "a renderer with no roster is an error" "1" "$rc"

# --- one definition of a formula file, shared with check-products-consistent ---
T="$(mktree subdir)"; mkdir "$T/Formula/e"; cp "$T/Formula/podup.rb" "$T/Formula/e/podup.rb"
rc=0; gate "$T" || rc=$?
check "a copy of a valid formula in a subdirectory is refused" "1" "$rc"
check "and the message says where a formula lives" "1" "$(said 'directly in Formula/')"

T="$(mktree upper)"; mv "$T/Formula/podup.rb" "$T/Formula/podup.RB"
rc=0; gate "$T" || rc=$?
check "a valid formula with an upper-case extension is refused" "1" "$rc"

D="$(mktree defsab)"; mkdir "$D/Formula/e"; cp "$D/Formula/podup.rb" "$D/Formula/e/podup.rb"
sed 's/if not re.fullmatch(r"\[^\/\]+\\.rb", inside):/if False:/' "$HERE/scripts/artifacts/check-formulae.py" > "$D/scripts/artifacts/check-formulae.py"
check "the definition control changed the check" "1" \
	"$(cmp -s "$HERE/scripts/artifacts/check-formulae.py" "$D/scripts/artifacts/check-formulae.py" && echo 0 || echo 1)"
rc=0; gate "$D" || rc=$?
check "without the definition, the subdirectory copy passes" "0" "$rc"

# --- the control: the verdict removed -----------------------------------------
# found = check_formula(...) replaced by an empty list. If the edit changed
# nothing the flip below would prove nothing, so the difference is required.
S="$(mktree sabotaged)"
sed 's/found = check_formula(path, row)/found = []/' "$HERE/scripts/artifacts/check-formulae.py" \
	> "$S/scripts/artifacts/check-formulae.py"
check "the sabotage changed the check" "1" \
	"$(cmp -s "$HERE/scripts/artifacts/check-formulae.py" "$S/scripts/artifacts/check-formulae.py" && echo 0 || echo 1)"
for entry in "${CASES[@]}"; do
	IFS='|' read -r label expr _ <<<"$entry"
	cp "$HERE/Formula/podup.rb" "$S/Formula/podup.rb"; plant "$S" "$expr"
	rc=0; gate "$S" || rc=$?
	check "without the verdict, $label passes (the refusal was the check's)" "0" "$rc"
done

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
