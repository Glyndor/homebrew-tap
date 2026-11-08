#!/usr/bin/env bash
#
# Fail when a reference under docs/ does not resolve, and when one of them is
# still a line coordinate.
#
# WHY THIS EXISTS
#
# docs/threat-model.md cites the code it describes. It used to cite it by
# `path:line`, and every one of those coordinates was true on the day it was
# written and false the next time the file moved. The renderer grew by hundreds of
# lines and changed directory; the citations kept their numbers and started
# pointing at unrelated code. Nothing failed, because a line number in a
# Markdown document is not a link and nothing resolves it.
#
# The fix is not to re-derive the numbers. A number is not a name and it goes
# stale the next time a line is added above it. A name does not move:
# `verify_sha256sums` is the same function before and after the file grows
# around it. So a reference is now `path#name`, and this check resolves it.
#
# WHAT IT CHECKS
#
#   1. Every `path#name` under docs/ resolves: the file exists, and that file
#      declares that name.
#   2. No `path:line` coordinate survives anywhere under docs/.
#
# A reference is a backticked span. A `path#name` inside backticks is a
# reference; a `#` in prose is not, and the path has to look like a path -- it
# carries a `/` or a dot -- so `C#` and an issue number are not mistaken for
# one.
#
# WHAT COUNTS AS A NAME
#
# The name a file declares depends on what the file is:
#
#   shell     a function (`verify_sha256sums`), a top-level variable
#             (`RELEASE_PUBKEY_B64`), a test case description, or the script's
#             own name -- for the scripts whose whole body is the control and
#             that declare no function of their own.
#   markdown  a heading.
#   yaml      a job id, or a `name:` value (a workflow, a job or a step).
#   json      an object key.
#   ruby      a class, a module or a method.
#   other     the first word of each line that is not a comment, which is how
#             CODEOWNERS declares its rules.
#
# Usage: check-doc-anchors.sh [repo-root]   (default: the repo this lives in)

set -euo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
if [ ! -d "$root/docs" ]; then
	echo "no docs/ directory under $root" >&2
	exit 1
fi

fail=0
documents=0
references=0

# The names a file declares, one per line on stdout. A file that declares
# nothing yields nothing, and that is a legitimate answer: the caller then
# reports the reference as unresolvable.
definitions_of() { # <path>
	local file="$1"
	case "$file" in
	*.md)
		grep -E '^#{1,6}[[:space:]]' "$file" \
			| sed -E 's/^#{1,6}[[:space:]]+//; s/[[:space:]]+$//' || true
		;;
	*.sh | *.bash)
		# A function definition: `name() {`. The brace is what makes it a
		# definition and not a call.
		grep -E '^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*[{]' "$file" \
			| sed -E 's/^[[:space:]]*//; s/^function[[:space:]]+//; s/[[:space:]]*\(.*$//' || true
		# A top-level variable or constant: `RELEASE_PUBKEY_B64="..."`.
		grep -E '^[[:space:]]*(export[[:space:]]+|readonly[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$file" \
			| sed -E 's/^[[:space:]]*//; s/^(export|readonly)[[:space:]]+//; s/=.*$//' || true
		# A test case: the description it asserts under.
		grep -E '^[[:space:]]*(check|contains|assert|assert_error)[[:space:]]+"' "$file" \
			| sed -E 's/^[[:space:]]*//; s/^(check|contains|assert|assert_error)[[:space:]]+"([^"]*)".*$/\2/' || true
		# A script whose whole body is the control declares no function and
		# no constant, so the file names itself.
		printf '%s\n' "${file##*/}" | sed -E 's/\.sh$//; s/\.test$//'
		;;
	*.yml | *.yaml)
		# The job ids under `jobs:`.
		sed -n '/^jobs:/,/^[^[:space:]]/p' "$file" \
			| grep -E '^  [A-Za-z0-9_.-]+:[[:space:]]*$' \
			| sed -E 's/^  //; s/:[[:space:]]*$//' || true
		# Every `name:` value: a workflow, a job or a step.
		grep -E '^[[:space:]]*(-[[:space:]]+)?name:[[:space:]]*' "$file" \
			| sed -E 's/^[[:space:]]*(-[[:space:]]+)?name:[[:space:]]*//; s/[[:space:]]+$//; s/^"(.*)"$/\1/' || true
		;;
	*.json)
		grep -oE '"[^"]+"[[:space:]]*:' "$file" | sed -E 's/^"(.*)"[[:space:]]*:$/\1/' || true
		;;
	*.rb)
		grep -E '^[[:space:]]*(class|module|def)[[:space:]]+[A-Za-z_]' "$file" \
			| sed -E 's/^[[:space:]]*def[[:space:]]+self\.//; s/^[[:space:]]*(class|module|def)[[:space:]]+//; s/[^A-Za-z0-9_].*$//' || true
		;;
	*)
		grep -vE '^[[:space:]]*(#|$)' "$file" | awk '{print $1}' || true
		;;
	esac
}

# Every backticked span outside a fenced code block, one per line, prefixed
# with the line it was found on. A fenced block holds commands, not references.
spans_of() { # <path>
	awk '
		/^[[:space:]]*```/ { infence = !infence; next }
		infence { next }
		{
			line = $0
			while (match(line, /`[^`]+`/)) {
				printf "%d\t%s\n", NR, substr(line, RSTART + 1, RLENGTH - 2)
				line = substr(line, RSTART + RLENGTH)
			}
		}
	' "$1"
}

# Every `path:line` coordinate anywhere in the document, including outside
# backticks: a coordinate is wrong wherever it is written. Each hit carries the
# line it was found on, so the report can point at the place to fix.
coordinates_of() { # <path>
	grep -n -oE '[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*:[0-9][0-9,-]*' "$1" || true
}

while IFS= read -r -d '' document; do
	rel="${document#"$root"/}"
	documents=$((documents + 1))

	# 1. no line coordinate survives
	while IFS= read -r hit; do
		[ -n "$hit" ] || continue
		line="${hit%%:*}"
		rest="${hit#*:}"
		path="${rest%%:*}"
		case "$path" in
		*/* | *.*) ;;
		*) continue ;;
		esac
		echo "::error file=$rel::$rel:$line cites $rest by line. Cite the name instead: $path#<name>" >&2
		fail=1
	done < <(coordinates_of "$document")

	# 2. every reference resolves
	while IFS=$'\t' read -r line span; do
		[ -n "$span" ] || continue
		case "$span" in
		:[0-9]*)
			echo "::error file=$rel::$rel:$line cites $span by line. Cite the name instead." >&2
			fail=1
			continue
			;;
		*#*) ;;
		*) continue ;;
		esac
		path="${span%%#*}"
		name="${span#*#}"
		case "$path" in
		*/* | *.*) ;;
		*) continue ;;
		esac
		[ -n "$name" ] || continue
		references=$((references + 1))
		if [ ! -e "$root/$path" ]; then
			echo "::error file=$rel::$rel:$line cites $span but there is no $path in this repository" >&2
			fail=1
			continue
		fi
		declared="$(definitions_of "$root/$path")"
		if ! grep -Fxq -- "$name" <<<"$declared"; then
			echo "::error file=$rel::$rel:$line cites $span but $path declares no '$name'" >&2
			fail=1
		fi
	done < <(spans_of "$document")
done < <(find "$root/docs" -type f -name '*.md' -print0 | LC_ALL=C sort -z)

# A checker that inspected nothing prints the same success line as one that
# inspected everything, so refuse to be that.
if [ "$documents" -eq 0 ]; then
	echo "::error::no document under $root/docs was checked; the walk is empty or broken" >&2
	exit 1
fi

if [ "$fail" -ne 0 ]; then
	echo "Some reference under docs/ does not resolve, or is still a line coordinate." >&2
	exit 1
fi

echo "doc anchors: $references reference(s) under docs/ resolve; no line coordinate survives."
