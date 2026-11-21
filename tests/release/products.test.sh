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

# --- no second reader of the file -----------------------------------------------
# The reader is the one place that finds the table in the renderer's text. A gate
# that cuts or parses it with a pattern of its own is a second grammar, and the
# first change of shape breaks the two apart. The renderer declares the array and
# bash reads it, so the renderer and the files it sources do not count: they never
# search the file for the table.
#
# A second reader can spell its search many ways, so the scan does not look for one
# anchor. Over every file of scripts/ and .github/ it reads the lines that are not
# comments and flags four shapes: PRODUCTS assigned or appended in any spelling
# (`PRODUCTS=(`, `PRODUCTS =`, `^PRODUCTS=`, `PRODUCTS+=`), a declaration of it
# (`declare -a PRODUCTS`), PRODUCTS on a line that also runs a text search (sed,
# grep, awk, perl, rg, a Python `re.` call, a `/pattern/` range), and a search of
# the renderer's own file for an array opening or a range. A message that names the
# reader's refusal (`no PRODUCTS=( table`) is the one phrase the consumers match, so
# it is not a search. Reading the array as bash does (`"${PRODUCTS[@]}"`) is not one
# either.
second_readers() { # <root> <exempt path>...: the files under <root> that look for the table
	local root="$1" file rel keep
	shift
	while IFS= read -r file; do
		rel="${file#"$root"/}"
		keep=1
		for exempt in "$@"; do [ "$rel" = "$exempt" ] && keep=0; done
		[ "$keep" -eq 1 ] || continue
		if grep -v '^[[:space:]]*#' "$file" | sed 's/no PRODUCTS=( table//' | grep -qE \
			-e 'PRODUCTS[[:space:]]*\+?=' \
			-e '(declare|typeset|local|readonly)[[:space:]]+-[A-Za-z]+[[:space:]]+PRODUCTS' \
			-e 'PRODUCTS.*(\<(sed|grep|egrep|fgrep|awk|gawk|perl|rg)\>|re\.[a-z]+\()' \
			-e '(\<(sed|grep|egrep|fgrep|awk|gawk|perl|rg)\>|re\.[a-z]+\().*PRODUCTS' \
			-e '/[^/ ]*PRODUCTS' \
			-e 'render-[a-z]+\.sh.*(=\(|,/)' \
			-e '(=\(|,/).*render-[a-z]+\.sh'; then
			echo "$rel"
		fi
	done < <(find "$root/scripts" "$root/.github" -type f 2> /dev/null | sort)
}
joined() { tr '\n' ' '; }
EXEMPT=(scripts/release/products.sh "${RENDERER#"$HERE"/}")

readers="$(second_readers "$HERE" "${EXEMPT[@]}" | joined)"
check "the table is found in the renderer's text by scripts/release/products.sh and by no other file" "" "$readers"

# The scan has to see each way of writing a second reader, and has to leave the
# honest files alone; a scan that flags nothing would pass the check above anyway.
FX="$WORK/fx"
mkdir -p "$FX/scripts/gates" "$FX/scripts/release" "$FX/.github/workflows"
cp "$RENDERER" "$FX/${RENDERER#"$HERE"/}"
cp "$READER" "$FX/scripts/release/products.sh"
plant() { # <path> <line>: a file under the fixture holding the line
	mkdir -p "$(dirname "$FX/$1")"
	printf '#!/usr/bin/env bash\n%s\n' "$2" > "$FX/$1"
}
plant scripts/gates/caret.sh "grep -rlF '^PRODUCTS=' scripts"
plant scripts/gates/spaced.sh "sed -n '/^PRODUCTS =/,/^)/p' \"\$1\""
plant scripts/gates/window.sh "grep -A 20 'PRODUCTS=' \"\$1\" | sed -n 's/^[[:space:]]*\"\\(.*\\)\"\$/\\1/p'"
plant scripts/gates/declare.sh 'declare -a PRODUCTS'
# shellcheck disable=SC2016 # the planted readers are literal shell text
plant scripts/gates/table-first.sh 'table=PRODUCTS; grep -A 20 "$table" "$1"'
plant scripts/gates/renderer-first.sh "perl -ne 'print' scripts/release/${RENDERER##*/} '^[A-Z]*=('"
plant scripts/gates/ruby.sh "ruby -ne 'print if /PRODUCTS/../^\\)/' \"\$1\""
plant scripts/gates/append.sh 'PRODUCTS+=("x|y|z")'
# shellcheck disable=SC2016 # the planted readers are literal shell text
plant scripts/gates/name-only.sh 'awk "/PRODUCTS/ { on = 1 } on" "$1"'
plant scripts/gates/python.sh "python3 -c \"import re,sys; re.search(r'PRODUCTS', open(sys.argv[1]).read())\" \"\$1\""
plant scripts/gates/renderer-range.sh "sed -n '/^[A-Z]*=(/,/^)/p' scripts/release/${RENDERER##*/}"
plant .github/workflows/inline.yml "        run: awk '/^PRODUCTS=\\(/' scripts/release/${RENDERER##*/}"
plant scripts/gates/comment.sh '# the PRODUCTS= table is read by scripts/release/products.sh with sed'
# shellcheck disable=SC2016 # the planted readers are literal shell text
plant scripts/gates/array.sh 'for entry in "${PRODUCTS[@]}"; do echo "$entry"; done'
plant scripts/gates/message.sh 'echo "::error::the PRODUCTS roster has no row for x"'
# shellcheck disable=SC2016 # the planted readers are literal shell text
plant scripts/gates/refusal.sh '[[ "$reason" == *"no PRODUCTS=( table"* ]] && echo missing'
plant scripts/gates/runs-renderer.sh 'bash ./scripts/release/'"${RENDERER##*/}"' || rc=$?'
plant scripts/gates/other-grep.sh "grep -qE '^RELEASE_KEY=\"x\"\$' scripts/release/${RENDERER##*/}"
found="$(second_readers "$FX" "${EXEMPT[@]}" | joined)"
check "the scan flags every spelling of a second reader, and only those" \
	".github/workflows/inline.yml scripts/gates/append.sh scripts/gates/caret.sh scripts/gates/declare.sh scripts/gates/name-only.sh scripts/gates/python.sh scripts/gates/renderer-first.sh scripts/gates/renderer-range.sh scripts/gates/ruby.sh scripts/gates/spaced.sh scripts/gates/table-first.sh scripts/gates/window.sh " "$found"
unexempted="$(second_readers "$FX" | grep -c '^scripts/release/')"
check "and the reader and the renderer would be flagged without their exemption" "2" "$unexempted"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
