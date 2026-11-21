#!/usr/bin/env bash
#
# What a roster row may say is written twice: scripts/release/render-formulae.sh
# refuses a row before it writes a formula, and scripts/artifacts/check-formulae.py
# refuses the same row before it reads one. The two rules are separate text, and
# only the checker's was pinned by a table; the renderer's had a handful of cases
# that never named the boundary, so a rule widened on that side alone passed every
# suite and made the renderer write what the checker then refused.
#
# This suite holds the two to one table. Each line plants one value in one field of
# the roster row and says what both must do with it: refuse it with a given
# message, or let the row through the rule that is under test. The renderer is run
# against a release it can read and the checker against the committed formula, so
# a row they both admit is not refused for some other reason first, and a refusal
# is asserted by the message of the rule and not by an exit status.
#
# The values that need a quote, a backslash or a dollar sign are not here: a roster
# row is a double-quoted bash string, so those characters are read differently by
# the renderer and by scripts/release/products.sh, and each side already has its own
# cases for them (render-formulae-products.test.sh, check-formulae-roster.test.sh).
#
# The fixture both this file and its siblings need lives in
# tests/fixtures/release/render-fixture.sh.
#
# Requires: python3.

set -euo pipefail

HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../fixtures/release" && pwd)"
# shellcheck disable=SC1091
. "$HERE_FIXTURE/render-fixture.sh"
pass=0
fail=0

publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64 podup-linux-arm64 podup-linux-x86_64

# Every message either side gives for a rule under test. A row that is admitted
# must produce none of them on either side.
RULES=(
	"invalid formula name"
	"invalid class name"
	"invalid repository"
	"outside the Glyndor organization"
	"invalid asset name"
	"would end or escape a Ruby string"
)

# The generator with its one roster row edited: field $2 (zero-based) set to $3.
plant_row() { # $1=target $2=field $3=value
	python3 -I - "$GENERATOR" "$1" "$2" "$3" <<'PY'
import re
import sys

source, target, field, value = sys.argv[1:]
text = open(source).read()
found = re.search(r'^\t"([^"\n]*)"$', text, re.M)
if found is None:
    sys.exit("the roster row was not found in the generator")
fields = found.group(1).split("|")
if len(fields) != 10:
    sys.exit("the roster row has %d fields, not 10" % len(fields))
fields[int(field)] = value
edited = text.replace(found.group(0), '\t"' + "|".join(fields) + '"', 1)
open(target, "w").write(edited)
PY
	chmod +x "$1"
}

# The renderer on a roster carrying that row. Its output lands in renderer_out.
render_with() { # $1=field $2=value
	new_root "$WORK/renderer"
	plant_row "$WORK/renderer/scripts/release/render-formulae.sh" "$1" "$2"
	renderer_rc=0
	run "$WORK/renderer/scripts/release/render-formulae.sh" "$WORK/renderer" || renderer_rc=$?
	renderer_out="$(cat "$WORK/out")"
}

# The checker on a tree whose roster carries that row and whose formula is the
# committed one. Its output lands in checker_out.
check_with() { # $1=field $2=value
	local t="$WORK/checker"
	rm -rf "$t"; mkdir -p "$t/scripts/artifacts" "$t/scripts/release" "$t/Formula"
	cp "$HERE/scripts/artifacts/check-formulae.sh" "$HERE/scripts/artifacts/check-formulae.py" "$t/scripts/artifacts/"
	cp "$HERE/scripts/release/products.sh" "$t/scripts/release/"
	cp "$HERE/Formula/podup.rb" "$t/Formula/podup.rb"
	plant_row "$t/scripts/release/render-formulae.sh" "$1" "$2"
	checker_rc=0
	"$t/scripts/artifacts/check-formulae.sh" "$t" >"$WORK/checker.out" 2>&1 || checker_rc=$?
	checker_out="$(cat "$WORK/checker.out")"
}

said() { # $1=output $2=fragment
	printf '%s\n' "$1" | grep -qF -- "$2" && echo 1 || echo 0
}

said_any_rule() { # $1=output
	local rule
	for rule in "${RULES[@]}"; do
		if [ "$(said "$1" "$rule")" = 1 ]; then
			printf '%s' "$rule"
			return
		fi
	done
	printf 'none'
}

# <label> <field> <value> <message of the rule, or - when the row is admitted>
policy() {
	local label="$1" field="$2" value="$3" want="$4"
	render_with "$field" "$value"
	check_with "$field" "$value"
	if [ "$want" = "-" ]; then
		check "the renderer lets $label through every rule" "none" "$(said_any_rule "$renderer_out")"
		check "the checker lets $label through every rule" "none" "$(said_any_rule "$checker_out")"
	else
		check "the renderer refuses $label" "3 1" "$renderer_rc $(said "$renderer_out" "$want")"
		check "the checker refuses $label" "1 1" "$checker_rc $(said "$checker_out" "$want")"
	fi
}

# A row the rules admit renders end to end, or every refusal below could be the
# harness failing and not the rule: the committed row with only its class changed.
render_with 2 PodUp
check "a row both rules admit renders" "0" "$renderer_rc"

# --- the formula name (field 1) ---------------------------------------------
for value in 'pod-up' 'pod_up' 'pod.up' 'a+b@c' '9lives'; do
	policy "the formula name [$value]" 1 "$value" -
done
for value in 'Podup' '-podup' '.podup' '_podup' 'pod up' 'pod/up' 'pod:up' 'pod~up' 'pódup'; do
	policy "the formula name [$value]" 1 "$value" "invalid formula name"
done

# --- the class name (field 2) -----------------------------------------------
for value in 'Podup2' 'P' 'PodUp'; do
	policy "the class name [$value]" 2 "$value" -
done
for value in 'Pod_up' 'podup' '2Podup' 'Pod-up' 'Pod up' 'Pod.Up' 'Pód'; do
	policy "the class name [$value]" 2 "$value" "invalid class name"
done

# --- the repository (field 0) -----------------------------------------------
policy "the repository [Glyndor/pod.up-x_y]" 0 "Glyndor/pod.up-x_y" -
for value in 'Glyndor' 'Glyndor/' '/podup' 'Glyndor/a/b' 'Glyndor/-podup' 'Glyndor/pod up' 'Glyndor/pod:up'; do
	policy "the repository [$value]" 0 "$value" "invalid repository"
done
for value in 'EvilCorp/podup' 'glyndor/podup' 'Glyndor-x/podup'; do
	policy "the repository [$value]" 0 "$value" "outside the Glyndor organization"
done

# --- the four asset names (fields 5 to 8) -----------------------------------
slots=(mac_arm mac_intel linux_arm linux_intel)
for index in 0 1 2 3; do
	field=$((index + 5))
	slot="${slots[$index]}"
	for value in '-' 'podup_x.y-1' 'a'; do
		policy "the asset [$value] in $slot" "$field" "$value" -
	done
	for value in 'a b' 'a/b' '..' '.hidden' '-leading' 'a:b' 'a#{x}'; do
		policy "the asset [$value] in $slot" "$field" "$value" "invalid asset name in $slot"
	done
done

# --- licence, description and version check (fields 3, 4 and 9) ------------
for field in 3 4 9; do
	for value in 'MIT' 'Run it (fast, simple) & go: 100%' 'a#b' 'a#' 'a{b}' 'a@b'; do
		policy "the text [$value] in field $field" "$field" "$value" -
	done
	for value in 'text#{1}' 'text#@name' 'text#@@name'; do
		policy "the text [$value] in field $field" "$field" "$value" "would end or escape a Ruby string"
	done
done

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
