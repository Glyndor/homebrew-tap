#!/usr/bin/env bash
#
# The shellcheck line of the command CONTRIBUTING.md documents has to reach the
# files the shellcheck job of CI collects by extension: every `.sh` and every
# `.bash`, anywhere in the tree but .git. The documented line once listed only
# scripts/ and tests/, and the text beside it said it was the command the
# workflow runs, so a file outside those two folders was linted by CI and
# skipped by anyone who followed the document.
#
# The line is read out of the document and run over a small tree, with a stub
# standing in for shellcheck that records the files it is given. The tree holds
# the shapes the collector reaches and the ones it never does, so the cases that
# must be skipped show the line is not simply listing everything.
#
# Requires: bash, find, xargs, awk, grep.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
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

# The documented shellcheck line, as written, from the first sh block under "Tests".
line_of() { # $1 = document
	awk '/^## Tests/{t=1;next} /^## /{t=0} t&&/^```sh/{f=1;next} t&&/^```/{f=0} t&&f' "$1" \
		| grep -E 'xargs -0 shellcheck'
}

# Which files the line hands to shellcheck, one per line, run inside the toy tree.
reached() { # $1 = document
	local line
	line="$(line_of "$1")"
	rm -f "$WORK/args"
	(cd "$WORK/t" && PATH="$WORK/bin:$PATH" bash -c "fail=0; $line") > /dev/null 2>&1
	sort "$WORK/args" 2>/dev/null
}

mkdir -p "$WORK/bin" "$WORK/t/scripts/x" "$WORK/t/tests/a" "$WORK/t/.github/hooks" \
	"$WORK/t/.git/hooks" "$WORK/t/tools"
: > "$WORK/t/scripts/x/tool.sh"
: > "$WORK/t/tests/a/case.test.sh"
: > "$WORK/t/tools/helper.bash"
: > "$WORK/t/.github/hooks/check.sh"
: > "$WORK/t/root.sh"
: > "$WORK/t/.git/hooks/pre-commit.sh"
: > "$WORK/t/notes.txt"
# shellcheck disable=SC2016 # the stub reads this variable when it runs
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "%s/args"\n' "$WORK" > "$WORK/bin/shellcheck"
chmod +x "$WORK/bin/shellcheck"

check "CONTRIBUTING.md documents a shellcheck line" "1" "$(line_of "$HERE/CONTRIBUTING.md" | grep -c .)"

got="$(reached "$HERE/CONTRIBUTING.md")"
reach() { # $1 = path suffix; 1 when the line handed it to shellcheck
	grep -c -- "$1\$" <<<"$got" || true
}
check "a script under scripts/ is linted" "1" "$(reach 'scripts/x/tool.sh')"
check "a test under tests/ is linted" "1" "$(reach 'tests/a/case.test.sh')"
check "a .bash file is linted" "1" "$(reach 'tools/helper.bash')"
check "a script under a dot directory of the repository is linted" "1" "$(reach '.github/hooks/check.sh')"
check "a script at the root of the repository is linted" "1" "$(reach 'root.sh')"
check "what lives under .git is not linted" "0" "$(reach '.git/hooks/pre-commit.sh')"
check "a file that is not shell is not linted" "0" "$(reach 'notes.txt')"

# The same tree through the narrow line this document used to carry: the cases
# above must be able to fail, so the old line is run through the same reader.
narrow="$WORK/narrow.md"
printf '## Tests\n\n```sh\nfind scripts tests -name '"'"'*.sh'"'"' -print0 | xargs -0 shellcheck || fail=1\n```\n' > "$narrow"
got="$(reached "$narrow")"
check "control: the narrow line does lint scripts/" "1" "$(reach 'scripts/x/tool.sh')"
check "control: and does not lint a .bash file" "0" "$(reach 'tools/helper.bash')"
check "control: and does not lint a script at the root" "0" "$(reach 'root.sh')"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
