#!/usr/bin/env bash
# Every script under scripts/ is broken on purpose by at least one entry of
# tests/mutation/catalog.txt, or it says why it cannot be.
#
# The catalogue is what turns "this guard is tested" into a fact measured every
# week, and it only covers what somebody remembered to add. Nothing stopped a
# script from arriving with refusals and no entry at all, so a whole file of
# guards could sit outside the sweep while the catalogue looked complete. This
# is the floor: a script no entry mutates is a failure here, on every pull
# request.
#
# It is a floor and not the rule. The rule is that a change which adds a guard
# adds the entry that breaks it, in the same change, naming the suite that
# notices. A count per file cannot tell one new guard from another, so that half
# stays a rule for the author and the reviewer, written in the catalogue and in
# CONTRIBUTING.md.
#
# The one way out is the premise the sweep itself states: a script whose suite
# the runner excludes cannot be measured there, because that suite fails in the
# sweep's copy of the tree whatever the mutant is. Such a script passes only
# while its suite is in the runner's excluded list, so the exemption ends on the
# day the suite can run in the sweep.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
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

# unmutated <root>: one line per script under <root>/scripts that no entry of
# the catalogue mutates and whose suite the runner does not exclude, and one
# line naming the script that is exempt, prefixed "exempt".
unmutated() {
	local root="$1" script area name suite
	local catalogue="$root/tests/mutation/catalog.txt" runner="$root/tests/mutation/run-mutations.sh"
	local mutated excluded
	mutated="$(awk -F'\t' '!/^[[:space:]]*#/ && NF == 5 { print $2 }' "$catalogue" | LC_ALL=C sort -u)"
	excluded="$(awk '
		/^EXCLUDED(_SUITES)?=\(/ { inside = 1; next }
		inside && /^\)/ { inside = 0 }
		inside { gsub(/[[:space:]"]/, ""); if ($0 != "") print }
	' "$runner")"
	while IFS= read -r script; do
		if grep -Fxq -- "$script" <<<"$mutated"; then
			continue
		fi
		area="$(dirname "${script#scripts/}")"
		name="$(basename "$script")"
		suite="tests/$area/${name%.*}.test.sh"
		if [ -n "$excluded" ] && grep -Fxq -- "$suite" <<<"$excluded"; then
			echo "exempt $script ($suite is excluded from the sweep)"
		else
			echo "$script"
		fi
	done < <(cd "$root" && find scripts -type f \( -name '*.sh' -o -name '*.py' \) | LC_ALL=C sort)
}

# --- this repository ------------------------------------------------------------
unmutated "$HERE" > "$WORK/here"
while IFS= read -r line; do
	case "$line" in
		exempt\ *) echo "      ${line}" ;;
		*) echo "      a script no catalogue entry mutates: $line" ;;
	esac
done < "$WORK/here"
check "every script under scripts/ is mutated by the catalogue, or its suite cannot run in the sweep" "0" \
	"$(grep -vc '^exempt ' "$WORK/here")"
check "and the catalogue mutates at least one script, so the walk read something" "1" \
	"$(awk -F'\t' '!/^[[:space:]]*#/ && NF == 5 && $2 ~ /^scripts\// { found = 1 } END { print found + 0 }' "$HERE/tests/mutation/catalog.txt")"

# --- a planted tree, so the walk is seen to find what it is for ------------------
toy() { # <name>: a tree with two scripts, a catalogue that mutates the first and a runner excluding nothing
	T="$WORK/$1"
	mkdir -p "$T/scripts/area" "$T/tests/mutation"
	printf 'exit 1\n' > "$T/scripts/area/kept.sh"
	printf 'exit 1\n' > "$T/scripts/area/bare.py"
	printf '# a comment naming scripts/area/bare.py is not an entry\n' > "$T/tests/mutation/catalog.txt"
	printf 'kept\tscripts/area/kept.sh\texit 1\texit 0\ttests/area/kept.test.sh\n' >> "$T/tests/mutation/catalog.txt"
	printf 'EXCLUDED=(\n)\n' > "$T/tests/mutation/run-mutations.sh"
}
toy bare
check "a script no entry mutates is reported, and a comment naming it is not an entry" "scripts/area/bare.py" "$(unmutated "$T")"
toy excluded
printf 'EXCLUDED=(\n\t"tests/area/bare.test.sh"\n)\n' > "$T/tests/mutation/run-mutations.sh"
check "a script whose suite the runner excludes is exempt, and said to be" \
	"exempt scripts/area/bare.py (tests/area/bare.test.sh is excluded from the sweep)" "$(unmutated "$T")"
toy other-excluded
printf 'EXCLUDED_SUITES=(\n\ttests/area/kept.test.sh\n)\n' > "$T/tests/mutation/run-mutations.sh"
check "and the exemption is for the excluded suite's own script, not for any script" "scripts/area/bare.py" "$(unmutated "$T")"
toy covered
printf 'bare\tscripts/area/bare.py\texit 1\texit 0\ttests/area/bare.test.sh\n' >> "$T/tests/mutation/catalog.txt"
check "a tree whose every script is mutated reports nothing" "" "$(unmutated "$T")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
