#!/usr/bin/env bash
#
# Tests for scripts/quality/check-doc-anchors.sh -- the gate that fails when a
# reference under docs/ does not resolve, and when one of them is still a line
# coordinate.
#
# The gate lives in scripts/, so it appears in its own input set: that is the
# whole design, and it is the same shape as tests/quality/check-test-coverage.test.sh.
# Exempting it, or deleting this file, turns the coverage gate red.
#
# The cases below are the failures the gate exists for, each asserted on the
# message it prints and not only on the exit status: a gate that fails for the
# wrong reason teaches the next reader to look somewhere else.
#
# Requires: nothing beyond coreutils.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$HERE/scripts/quality/check-doc-anchors.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0

assert() { # <want-exit> <desc> -- <cmd...>
	local want="$1" desc="$2"
	shift 3
	local got=0
	"$@" >/dev/null 2>&1 || got=$?
	if [ "$got" -eq "$want" ]; then
		echo "ok   - $desc (exit $got)"
		pass=$((pass + 1))
	else
		echo "FAIL - $desc (want exit $want, got $got)"
		fail=$((fail + 1))
	fi
}

assert_error() { # <want-exit> <needle> <desc> -- <cmd...>
	local want="$1" needle="$2" desc="$3"
	shift 4
	local got=0 out
	out="$("$@" 2>&1)" || got=$?
	if [ "$got" -eq "$want" ] && printf '%s' "$out" | grep -qF -- "$needle"; then
		echo "ok   - $desc (exit $got)"
		pass=$((pass + 1))
	else
		echo "FAIL - $desc (want exit $want containing '$needle', got exit $got: $out)"
		fail=$((fail + 1))
	fi
}

# A tree whose document cites a name the script declares.
mkref() { # <dir> <document line>
	mkdir -p "$1/docs" "$1/scripts/release"
	printf '%s\n' "$2" > "$1/docs/threat-model.md"
	{
		printf '#!/usr/bin/env bash\n'
		printf 'verify_sha256sums() { # one repo, one tag\n'
		printf '\t:\n'
		printf '}\n'
		printf 'RELEASE_PUBKEY_B64="abc"\n'
	} > "$1/scripts/release/render.sh"
}

# --- a reference that resolves ----------------------------------------------
mkref "$WORK/ok" "The signature gate is \`scripts/release/render.sh#verify_sha256sums\`."
assert 0 "a reference whose name the file declares passes" \
	-- "$GATE" "$WORK/ok"

mkref "$WORK/okconst" "The trust anchor is \`scripts/release/render.sh#RELEASE_PUBKEY_B64\`."
assert 0 "a reference to a constant the file declares passes" \
	-- "$GATE" "$WORK/okconst"

# --- a name the file does not declare ---------------------------------------
#
# The message must name the anchor, or the reader has to open every file the
# document cites to find out which one moved.
mkref "$WORK/badname" "The signature gate is \`scripts/release/render.sh#verify_sha256sums_OLD\`."
assert_error 1 "verify_sha256sums_OLD" \
	"a name the file does not declare is named, not merely counted" \
	-- "$GATE" "$WORK/badname"

# --- a file that does not exist ---------------------------------------------
#
# The other failure. A renamed or moved file leaves the reference pointing at
# nothing, and a gate that only checked the name would pass it.
mkref "$WORK/badfile" "The signature gate is \`scripts/release/render-gone.sh#verify_sha256sums\`."
assert_error 1 "render-gone.sh" \
	" a reference to a file that does not exist names the file" \
	-- "$GATE" "$WORK/badfile"

# --- a line coordinate -------------------------------------------------------
#
# The reason this gate exists. The coordinate was true when it was written and
# false the next time the file moved, and nothing noticed.
mkref "$WORK/coords" "The signature gate is \`scripts/release/render.sh:102-164\`."
assert_error 1 "render.sh:102-164" \
	"a reference by line number is refused" \
	-- "$GATE" "$WORK/coords"

# A coordinate outside backticks is still a coordinate.
mkref "$WORK/barecoord" "The signature gate lives in scripts/release/render.sh:102-164 today."
assert_error 1 "render.sh:102-164" \
	"a line coordinate is refused even when it is not backticked" \
	-- "$GATE" "$WORK/barecoord"

# A bare `:37` is the same failure in the shorthand the documents use.
mkref "$WORK/bareshorthand" "The second slot is \`:37\` of the renderer."
assert_error 1 ":37" \
	"a bare line coordinate is refused" \
	-- "$GATE" "$WORK/bareshorthand"

# --- prose that is not a reference ------------------------------------------
#
# The gate reads backticked spans, and a hash in prose is not a path. Without
# this case a gate that flagged every hash would look like it worked.
mkref "$WORK/prose" "Written in C#, tracked as issue#42, and \`scripts/release/render.sh#verify_sha256sums\` still resolves."
assert 0 "a hash in prose is not mistaken for a reference" \
	-- "$GATE" "$WORK/prose"

# --- a tree without docs/ ---------------------------------------------------
mkdir -p "$WORK/nodocs/scripts"
assert_error 1 "no docs/ directory" \
	"a tree without docs/ is refused rather than silently passing" \
	-- "$GATE" "$WORK/nodocs"

# --- the gate is inside its own input set ------------------------------------
assert 0 "the gate has a test of its own here" \
	-- test -f "$HERE/tests/quality/check-doc-anchors.test.sh"

assert 0 "the gate passes against this repository" \
	-- "$GATE" "$HERE"

echo
echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
