#!/usr/bin/env bash
#
# Fail when this repository's render script has drifted from the equivalent
# script in the sibling repository.
#
# WHY THIS CHECK EXISTS
#
#   The homebrew-tap and scoop-bucket repositories each carry their own render
#   script. They are NOT copies of each other -- one renders Ruby formulae, the
#   other JSON manifests -- but the verification logic they share is what
#   decides whether a release is trusted. Nothing about what is signed, how the
#   signature is verified, or how the SHA256 is matched should ever depend on
#   which package manager is being targeted.
#
#   Until this script existed, the only thing keeping that shared logic in step
#   was somebody remembering to apply a fix in both places, which is care
#   rather than a mechanism, and care does not survive a busy week.
#
# WHAT IS COMPARED
#
#   Three named units inside the script:
#
#       verify_sha256sums  the function that fetches SHA256SUMS + .sig and
#                         verifies the Ed25519 signature against the
#                         configured release keys
#       py_block          the embedded python block, from <<'PY' to PY, that
#                         does the actual signature verification
#       hash_of           the function that pulls a single asset's hex digest
#                         out of the verified SHA256SUMS
#
#   render_product is EXCLUDED by name, with the reason given below. The two
#   repositories render to different formats, so the function legitimately
#   differs. A check that went red on it would be switched off within a week;
#   keeping it named below is the only thing that makes the exclusion legible
#   to whoever next looks at this script.
#
# HOW THE COMPARISON IS MADE, AND WHY IT IS NOT A BYTE COMPARISON
#
#   Comments and blank lines are stripped from both sides before the diff.
#   Comments in these files legitimately describe their own repository, and a
#   gate that goes red for a correct comment edit is a gate people learn to
#   click past.
#
# WHERE THE SIBLING IS READ FROM
#
#   Over HTTPS from raw.githubusercontent.com. The repositories are public, so
#   no token is needed; a token would give a drift reporter write reach it has
#   no business having.
#
# THREE OUTCOMES, KEPT DISTINCT ON PURPOSE
#
#   drift            a compared unit's logic differs; the diff is printed
#   fetch failure    GitHub could not be reached, or answered with nothing.
#                    This is NOT reported as drift. Conflating an unreachable
#                    network with a real disagreement teaches people that a
#                    red check means "try again later", which is exactly the
#                    habit that lets a genuine one through.
#   nothing compared refuse to pass having inspected nothing (see the bottom).
#
# Usage: check-render-drift.sh [repo-root]

set -euo pipefail

# The sibling that carries the other half of this comparison. Each repository's
# copy of this script names the other one, never itself.
SIBLING_REPO="Glyndor/scoop-bucket"

# The file each side renders from. The names are deliberately different: this
# repository renders Ruby formulae; the sibling renders JSON manifests.
LOCAL_FILE="scripts/render-formulae.sh"
REMOTE_FILE="scripts/render-manifests.sh"

# Units that MUST stay byte-identical (after stripping comments and blanks).
# Everything inside this array is the contract.
UNITS=(
	verify_sha256sums
	py_block
	hash_of
)

# render_product is intentionally excluded by name. It formats to Ruby formulae
# on this side and to JSON manifests on the sibling, so the function legitimately
# differs, and the difference is the whole point. If it is silently added to
# UNITS above, this check becomes permanently red and gets switched off; the
# most useful thing this comment can do is name the unit that is not compared,
# so the next reader sees the exclusion was deliberate. (No code reads this
# block; the comment is the contract.)
# EXCLUDED_UNITS=(
# 	render_product
# )

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
local_script="$root/$LOCAL_FILE"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Reduce a script to the lines that decide what it does: drop blank lines, drop
# trailing whitespace, and drop lines whose first non-space character starts a
# comment. This is the same recipe as check-reusable-drift.sh: an invisible
# byte must not masquerade as drift, and an honest comment edit must not.
strip_prose() { # $1=file
	sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*#/d' -e '/^$/d' "$1"
}

# Extract a named unit from a render script. Returns the unit's raw lines on
# stdout, or nothing if the unit's opening marker is absent. A partial match
# (opening marker present, closing marker absent) is reported separately by
# the caller: it is not the same as "found", because a half-extracted function
# would silently compare the wrong thing.
extract_unit() { # $1=file $2=unit
	local file="$1" unit="$2"
	case "$unit" in
		verify_sha256sums)
			sed -n '/^verify_sha256sums()/,/^}/p' "$file"
			;;
		hash_of)
			sed -n '/^hash_of()/,/^}/p' "$file"
			;;
		py_block)
			# From the line containing <<'PY' (with optional tab-stripping
			# hyphen, optional quoting, anything reasonable) to the next line
			# that is exactly PY. awk's range pattern stops on first exit
			# condition, which is what we want.
			awk '/<<.*PY/{found=1} found{print; if(/^PY$/){exit}}' "$file"
			;;
		*)
			echo "::error::internal: unknown unit '$unit'" >&2
			return 1
			;;
	esac
}

# Does the extracted unit end with its expected closer? $1 is the last line of
# the extracted text; $2 is the unit name. Returns 0 if the closer matches,
# 1 otherwise (partial match: opening marker was found but closing was not).
unit_is_complete() { # $1=last-line $2=unit
	local last="$1" unit="$2"
	case "$unit" in
		verify_sha256sums|hash_of)
			[[ "$last" =~ ^}[[:space:]]*$ ]]
			;;
		py_block)
			[[ "$last" == "PY" ]]
			;;
	esac
}

compared=0
drifted=0
unreachable=0
absent=0

if [ ! -f "$local_script" ]; then
	echo "::error::$LOCAL_FILE is not present in $root; this repository should carry its own copy" >&2
	absent=1
else
	remote_url="https://raw.githubusercontent.com/$SIBLING_REPO/main/$REMOTE_FILE"

	if ! curl -fsSL "$remote_url" > "$tmp/remote" 2>"$tmp/curl.err"; then
		echo "::error::could not fetch $REMOTE_FILE from $SIBLING_REPO: the request to GitHub failed" >&2
		echo "  $remote_url" >&2
		if [ -s "$tmp/curl.err" ]; then
			sed 's/^/  curl: /' "$tmp/curl.err" >&2
		fi
		echo "  This is a fetch failure, not drift: nothing is known about whether $REMOTE_FILE agrees." >&2
		unreachable=1
	elif [ ! -s "$tmp/remote" ]; then
		echo "::error::$SIBLING_REPO answered with an empty body for $REMOTE_FILE" >&2
		echo "  $remote_url" >&2
		echo "  This is a fetch failure, not drift: an empty file cannot be compared." >&2
		unreachable=1
	else
		for unit in "${UNITS[@]}"; do
			mine_text=$(extract_unit "$local_script" "$unit")
			remote_text=$(extract_unit "$tmp/remote" "$unit")

			if [ -z "$mine_text" ]; then
				echo "::error::$unit could not be found in $LOCAL_FILE" >&2
				echo "  the opening marker was absent; renaming $unit on this side will break the contract" >&2
				absent=1
				continue
			fi
			if [ -z "$remote_text" ]; then
				echo "::error::$unit could not be found in $REMOTE_FILE (from $SIBLING_REPO)" >&2
				echo "  the opening marker was absent on the sibling side; renaming $unit there will break the contract" >&2
				absent=1
				continue
			fi

			# A partial match (opening marker present, closing marker absent)
			# means the extraction stopped early. Treat it as "not found"
			# rather than comparing a half unit: the diff would be meaningless.
			mine_last=$(printf '%s\n' "$mine_text" | tail -1)
			remote_last=$(printf '%s\n' "$remote_text" | tail -1)
			if ! unit_is_complete "$mine_last" "$unit"; then
				echo "::error::$unit in $LOCAL_FILE opens but never closes (expected marker at end)" >&2
				absent=1
				continue
			fi
			if ! unit_is_complete "$remote_last" "$unit"; then
				echo "::error::$unit in $REMOTE_FILE (from $SIBLING_REPO) opens but never closes (expected marker at end)" >&2
				absent=1
				continue
			fi

			printf '%s\n' "$mine_text" > "$tmp/mine.unit"
			printf '%s\n' "$remote_text" > "$tmp/remote.unit"
			strip_prose "$tmp/mine.unit" > "$tmp/mine.stripped"
			strip_prose "$tmp/remote.unit" > "$tmp/remote.stripped"
			compared=$((compared + 1))

			if ! diff -u \
				--label "this repository: $LOCAL_FILE ($unit)" \
				--label "$SIBLING_REPO: $REMOTE_FILE ($unit)" \
				"$tmp/mine.stripped" "$tmp/remote.stripped" > "$tmp/diff"; then
				echo "::error file=$LOCAL_FILE::$unit has drifted from $SIBLING_REPO" >&2
				echo "  the difference is in the logic, not in the comments:" >&2
				sed 's/^/  /' "$tmp/diff" >&2
				drifted=$((drifted + 1))
			fi
		done
	fi
fi

# A checker that inspected nothing prints the same success line as one that
# inspected everything, so refuse to be that. This has happened here before:
# the previous version of this class of check reported success on files it had
# never opened. Naming nothing-compared as its own failure mode is the only
# honest response.
if [ "$compared" -eq 0 ]; then
	echo "::error::no render unit was compared; the unit list, the script, or every fetch is broken" >&2
	exit 1
fi

if [ "$unreachable" -ne 0 ] || [ "$absent" -ne 0 ]; then
	echo "Compared $compared render unit(s), but some could not be read; see the errors above." >&2
	exit 1
fi

if [ "$drifted" -ne 0 ]; then
	echo "$drifted of $compared compared render unit(s) have drifted." >&2
	echo "Apply the same change in both repositories, or record in the pull request why they now differ." >&2
	exit 1
fi

echo "compared $compared render unit(s) against $SIBLING_REPO; the verification logic agrees."
