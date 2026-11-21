#!/usr/bin/env bash
# scripts/release/products.sh, the one reader of the PRODUCTS table: it reads
# the committed table as bash reads it, prints each row as written, and refuses
# a table it does not understand instead of reading it short.
#
# The file is the same in Glyndor/homebrew-tap and Glyndor/scoop-bucket
# (scripts/monitoring/channel-shared-paths.txt); the renderer it reads is the
# one this repository carries.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
READER="$HERE/scripts/release/products.sh"
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
read_table() { # <file>: rc, rows in $WORK/out, errors in $WORK/err
	rc=0
	bash "$READER" "$1" > "$WORK/out" 2> "$WORK/err" || rc=$?
}
said() { if grep -qF -- "$1" "$WORK/err"; then echo 1; else echo 0; fi; }
table() { # <name> <lines...>: a file whose PRODUCTS table holds the lines
	T="$WORK/$1.sh"; shift
	{
		echo '#!/usr/bin/env bash'
		echo 'PRODUCTS=('
		printf '%s\n' "$@"
		echo ')'
		echo 'echo after'
	} > "$T"
}

# --- the committed table, read as bash reads it --------------------------------
RENDERER="$(find "$HERE/scripts/release" -maxdepth 1 -name 'render-*.sh' | head -1)"
read_table "$RENDERER"
check "the committed table is read" "0" "$rc"
bash -c 'eval "$(awk "/^PRODUCTS=\\(/ { inside = 1 } inside { print } inside && /^\\)/ { exit }" "$1")"; printf "%s\n" "${PRODUCTS[@]}"' _ "$RENDERER" > "$WORK/bash"
check "and its rows are the ones bash declares, in order" "" "$(diff "$WORK/bash" "$WORK/out")"
check "and there is at least one" "1" "$([ -s "$WORK/out" ] && echo 1 || echo 0)"

# --- what the table may hold -----------------------------------------------------
table ok '	"Glyndor/a|a|first"' '' '	# a comment line' '	"Glyndor/b|b|a \"quoted\" word"'
read_table "$T"
check "rows around a blank and a comment line are read" "0 2" "$rc $(wc -l < "$WORK/out" | tr -d ' ')"
check "and a row is printed as written between its quotes" 'Glyndor/b|b|a \"quoted\" word' "$(sed -n 2p "$WORK/out")"
check "and the table ends at its closing line" "0" "$(grep -c after "$WORK/out")"

# --- what it refuses, each by its reason ---------------------------------------
table bare '	"Glyndor/a|a|first"' '	Glyndor/b|b|unquoted'
read_table "$T"
check "a line that is not a quoted row stops the read" "1 1" \
	"$rc $(said 'line 4 of the PRODUCTS table is not one double-quoted row')"
table trailing '	"Glyndor/a|a|first" "Glyndor/b|b|second"'
read_table "$T"
check "and so do two rows on one line" "1 1" "$rc $(said 'is not one double-quoted row')"
table open '	"Glyndor/a|a|first'
read_table "$T"
check "and so does a row whose quote is never closed" "1 1" "$rc $(said 'is not one double-quoted row')"
table empty '	# nothing declared'
read_table "$T"
check "a table with no row is refused" "1 1" "$rc $(said 'the PRODUCTS table holds no row')"
printf 'PRODUCTS=(\n\t"Glyndor/a|a|first"\n' > "$WORK/unclosed.sh"
read_table "$WORK/unclosed.sh"
check "a table that is never closed is refused" "1 1" "$rc $(said 'the PRODUCTS table is not closed')"
printf '# no table here\n' > "$WORK/none.sh"
read_table "$WORK/none.sh"
check "a file with no table is refused, and named" "1 1 1" \
	"$rc $(said 'no PRODUCTS=( table') $(said "$WORK/none.sh")"
read_table "$WORK/absent.sh"
check "a file that is not there is refused" "1 1" "$rc $(said 'is not a readable file')"
rc=0; bash "$READER" > /dev/null 2>&1 || rc=$?
check "and a call with no file is a usage error" "2" "$rc"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
