#!/usr/bin/env bash
#
# Fail when a file this repository shares with Glyndor/scoop-bucket has drifted
# from the copy the tap publishes on its main branch.
#
# WHY THIS CHECK EXISTS
#
#   Thirty-five scripts and tests under scripts/ and tests/ are byte-identical
#   in both channel repositories: the same shell, the same CI policy, the same
#   tests. They are copies, and the duplication is deliberate -- it keeps every
#   repository in the publication path self-contained, so no outside repository
#   can change what a release does.
#
#   Nothing watched them. A fix applied to this repository's copy of a shared
#   check left the sibling's copy behind, and from then on the two repositories
#   answered the same question differently: one refusing a manifest the other
#   published, one linting what the other let through. The reusable workflows
#   have their own watcher (check-reusable-drift.sh) and the render scripts
#   have theirs (check-render-drift.sh). These thirty-five files had none.
#
# WHAT IS COMPARED
#
#   The paths listed in scripts/monitoring/channel-shared-paths.txt, one per
#   line. The list is a data file rather than an array in this script, so that
#   adding or removing a shared file is a one-line change in the file whose
#   whole job is to be that list, and so that the list can be read without
#   reading this script.
#
# HOW THE COMPARISON IS MADE, and why it is a byte comparison
#
#   These files are copies, not two implementations of one idea, so the whole
#   text is the contract: a comment changed on one side only is a copy that
#   has stopped being a copy. The sibling checks are looser on purpose -- the
#   reusable workflows' comments legitimately name their own repository, and
#   the renderers share units rather than a whole file -- and a byte
#   comparison here would not misfire, because none of the thirty-five files
#   carries prose that belongs to one repository and not the other.
#
#   Two things are normalised before the comparison. Both are invisible to a
#   reader, and neither can hide a change in behaviour:
#
#     CRLF line endings    a checkout on Windows has CRLF files unless the
#                          repository says otherwise, and reporting thirty-five
#                          files as drifted because of the reader's line
#                          endings is a red nobody can act on.
#     trailing whitespace  an invisible byte at the end of a line must not
#                          masquerade as drift, and the diff of two lines that
#                          look the same is unreadable.
#
#   Comments and blank lines are NOT normalised away. They are part of the
#   copy.
#
# WHERE THE SIBLING COPY IS READ FROM
#
#   Over HTTPS from raw.githubusercontent.com, the same mechanism
#   check-reusable-drift.sh uses. The repository is public, so this needs no
#   token, no secret and no second checkout -- which matters, because handing
#   a drift reporter write reach it has no business having.
#
# FOUR OUTCOMES, KEPT DISTINCT ON PURPOSE
#
#   drift            a listed file's text differs; the path and the first
#                    differing line are named
#   absent           the file is missing on one side: not present here, or not
#                    served by the sibling (HTTP 404)
#   fetch failure    GitHub could not be reached, or answered with nothing.
#                    This is NOT reported as drift. Conflating an unreachable
#                    network with a real disagreement teaches people that a
#                    red check means "try again later", which is exactly the
#                    habit that lets a genuine one through.
#   nothing compared refuse to pass having inspected nothing (see the bottom)
#
# Usage: check-channel-drift.sh [repo-root] [path-list]
#        (defaults: the repo this lives in, and the list beside it)

set -euo pipefail

# The sibling channel that carries the other half of these copies. Each
# repository's copy of this script names the other one, never itself.
SIBLING_REPO="Glyndor/scoop-bucket"

# The data file that names the shared paths, relative to the repository root.
PATHS_FILE="scripts/monitoring/channel-shared-paths.txt"

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
paths_file="${2:-$root/$PATHS_FILE}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Reduce a file to the text that decides what it does: turn CRLF into LF and
# drop the whitespace at the end of a line. Nothing else is removed, so a
# comment or a blank line is still part of the copy.
normalise() { # $1=file
	sed -e 's/\r$//' -e 's/[[:space:]]*$//' "$1"
}

# The paths to compare, one per line. Whole-line comments and blank lines are
# ignored; every other line is a path.
read_paths() { # $1=path-list
	awk '
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*$/ { next }
		{
			sub(/^[[:space:]]+/, "")
			sub(/[[:space:]]+$/, "")
			print
		}
	' "$1"
}

# Is this a path this repository could carry? The list is a versioned file that
# somebody can edit, and the path goes into a URL, so a path that climbs out of
# the repository is refused rather than fetched.
usable_path() { # $1=path
	case "$1" in
		'' | /* | *..*) return 1 ;;
	esac
	[[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
	return 0
}

# Name the first line that differs. The line number is the one in the file the
# reader has open: normalising strips characters from the end of a line and
# never removes a line, so the count is the same in both files.
#
# The first line is compared by CONTENT and not by byte offset. The two are
# not the same thing: a file that gained a line at its end differs from byte
# one of the last line it has in common, and naming that line would print the
# same text on both sides and send the reader looking for a difference that
# is not there.
report_difference() { # $1=path  $2=mine  $3=remote
	local path="$1" mine="$2" remote="$3"
	local first line mine_present remote_present

	first="$(awk '
		FILENAME == ARGV[1] { a[FNR] = $0; na = FNR; next }
		{ b[FNR] = $0; nb = FNR }
		END {
			n = (na > nb) ? na : nb
			for (i = 1; i <= n; i++) {
				if (i > na || i > nb || a[i] != b[i]) {
					printf "%d\t%d\t%d\n", i, (i <= na ? 1 : 0), (i <= nb ? 1 : 0)
					exit
				}
			}
		}
	' "$mine" "$remote")"

	line="$(printf '%s' "$first" | cut -f1)"
	mine_present="$(printf '%s' "$first" | cut -f2)"
	remote_present="$(printf '%s' "$first" | cut -f3)"

	echo "::error file=$path::$path differs from $SIBLING_REPO" >&2
	if [ -z "$line" ]; then
		# The two files differ but no line was found to blame, which means the
		# difference is not in their lines at all. Say that instead of
		# pointing at line 0.
		echo "  the two copies differ, and the difference is not in any line of either." >&2
		echo "  trailing whitespace and CRLF line endings are ignored; everything else is compared." >&2
		return
	fi
	echo "  first difference at line $line:" >&2
	if [ "$mine_present" = "1" ]; then
		echo "    this repository: $(sed -n "${line}p" "$mine")" >&2
	else
		echo "    this repository: <end of file>" >&2
	fi
	if [ "$remote_present" = "1" ]; then
		echo "    $SIBLING_REPO: $(sed -n "${line}p" "$remote")" >&2
	else
		echo "    $SIBLING_REPO: <end of file>" >&2
	fi
	echo "  trailing whitespace and CRLF line endings are ignored; everything else is compared." >&2
}

if [ ! -f "$paths_file" ]; then
	echo "::error::the path list $paths_file is not present; this repository should carry its own copy" >&2
	exit 1
fi

listed=0
compared=0
drifted=0
unreachable=0
absent=0

while IFS= read -r path; do
	listed=$((listed + 1))

	if ! usable_path "$path"; then
		echo "::error::$path is not a usable repository-relative path in the path list" >&2
		echo "  A path that climbs out of the repository, or names something else, cannot be compared." >&2
		absent=1
		continue
	fi

	mine="$root/$path"
	if [ ! -f "$mine" ]; then
		echo "::error::$path is not present in $root; this repository should carry its own copy" >&2
		absent=1
		continue
	fi

	url="https://raw.githubusercontent.com/$SIBLING_REPO/main/$path"
	# curl is a simple statement of its own, with its status read afterwards,
	# so the test that reads every curl in scripts/ can parse its arguments.
	: > "$tmp/code"
	curl_rc=0
	curl -fsSL --connect-timeout 10 --max-time 60 -o "$tmp/remote" -w '%{http_code}' "$url" > "$tmp/code" 2> "$tmp/curl.err" || curl_rc=$?
	http_code="$(cat "$tmp/code")"

	if [ "$curl_rc" -ne 0 ]; then
		if [ "$http_code" = "404" ]; then
			echo "::error::$SIBLING_REPO does not serve $path" >&2
			echo "  $url" >&2
			echo "  The path is listed as shared but the sibling does not carry it: it was renamed or removed there." >&2
			absent=1
		else
			echo "::error::could not fetch $path from $SIBLING_REPO: the request to GitHub failed" >&2
			echo "  $url" >&2
			if [ -s "$tmp/curl.err" ]; then
				sed 's/^/  curl: /' "$tmp/curl.err" >&2
			fi
			echo "  This is a fetch failure, not drift: nothing is known about whether $path agrees." >&2
			unreachable=1
		fi
		continue
	fi

	if [ ! -s "$tmp/remote" ]; then
		echo "::error::$SIBLING_REPO answered with an empty body for $path" >&2
		echo "  $url" >&2
		echo "  This is a fetch failure, not drift: an empty file cannot be compared." >&2
		unreachable=1
		continue
	fi

	normalise "$mine" > "$tmp/mine.normalised"
	normalise "$tmp/remote" > "$tmp/remote.normalised"
	compared=$((compared + 1))

	if ! diff -u \
		--label "this repository: $path" \
		--label "$SIBLING_REPO: $path" \
		"$tmp/mine.normalised" "$tmp/remote.normalised" > "$tmp/diff"; then
		report_difference "$path" "$tmp/mine.normalised" "$tmp/remote.normalised"
		sed 's/^/  /' "$tmp/diff" >&2
		drifted=$((drifted + 1))
	fi
done < <(read_paths "$paths_file")

# A checker that inspected nothing prints the same success line as one that
# inspected everything, so refuse to be that. This has happened here before:
# line-limit reported every file within the limit on every pull request while
# never opening a workflow, because `yml` was absent from its extension list.
if [ "$listed" -eq 0 ]; then
	echo "::error::the path list $paths_file names no file; there is nothing to compare" >&2
	exit 1
fi

if [ "$compared" -eq 0 ]; then
	echo "::error::no shared file was compared; the path list, the copies, or every fetch is broken" >&2
	exit 1
fi

if [ "$unreachable" -ne 0 ] || [ "$absent" -ne 0 ]; then
	echo "Compared $compared shared file(s), but some could not be read; see the errors above." >&2
	exit 1
fi

if [ "$drifted" -ne 0 ]; then
	echo "$drifted of $compared compared shared file(s) have drifted." >&2
	echo "Apply the same change in every channel repository, or record in the pull request why they now differ." >&2
	exit 1
fi

echo "compared $compared shared file(s) against $SIBLING_REPO; the copies agree."
