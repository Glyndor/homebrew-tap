#!/usr/bin/env bash
# Print the rows of the PRODUCTS table a renderer declares, one per line, so the
# gates that need the roster read it with one grammar.
#
# Usage: products.sh <renderer>
#
# The renderer is scripts/release/render-formulae.sh in Glyndor/homebrew-tap and
# scripts/release/render-manifests.sh in Glyndor/scoop-bucket. Its PRODUCTS=(
# ... ) array is the only place a product is declared, and the gates that check
# what was published against it cannot run the renderer to ask: it reads the
# releases over the network. They used to read the array with an awk and a sed
# each, written apart, so a change of shape would have broken them apart, one
# reading an empty roster where the other read an error. They read it here now.
# Each consumer splits a row on `|` itself, since the columns differ by channel.
#
# The grammar is the one bash reads the array with, cut down to the shape the
# renderer writes: from the line that starts `PRODUCTS=(` to the first line that
# starts `)`, each line is one double-quoted row, a comment or blank. A backslash
# keeps the next character inside the row, so an escaped quote in a description
# is part of it, as it is for bash. A row is printed as it is written between the
# quotes. Anything else inside the table stops the read, because a roster read
# past a line it did not understand is a roster with a product missing, and
# every gate here refuses an empty roster but not a short one.
#
# Exit status: 0 with at least one row printed; 1 when there is no table, the
# table is not closed, a line in it is not a row, or it holds no row; 2 on a
# usage error. A failure prints one ::error:: line naming the file.
#
# The file is the same in both channels (scripts/monitoring/channel-shared-paths.txt).
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: products.sh <renderer>" >&2; exit 2; }
[ -r "$1" ] || { echo "::error::cannot read the PRODUCTS table: $1 is not a readable file" >&2; exit 1; }

LC_ALL=C awk -v file="$1" '
	function fail(message) { printf "::error::%s: %s\n", file, message > "/dev/stderr"; failed = 1; exit 1 }
	!inside && /^PRODUCTS=\(/ { inside = 1; found = 1; next }
	inside && /^\)/ { inside = 0; closed = 1; exit }
	inside && /^[[:space:]]*(#.*)?$/ { next }
	inside {
		if ($0 !~ /^[[:space:]]*"([^"\\]|\\.)*"[[:space:]]*$/) {
			fail("line " NR " of the PRODUCTS table is not one double-quoted row: " $0)
		}
		row = $0
		sub(/^[[:space:]]*"/, "", row)
		sub(/"[[:space:]]*$/, "", row)
		print row
		rows++
	}
	END {
		if (failed) exit 1
		if (!found) fail("no PRODUCTS=( table")
		if (!closed) fail("the PRODUCTS table is not closed by a line that starts with )")
		if (!rows) fail("the PRODUCTS table holds no row")
	}
' "$1"
