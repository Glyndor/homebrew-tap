#!/usr/bin/env bash
#
# CONTRIBUTING.md tells contributors how to run every suite and shellcheck
# before pushing. The suites live in subfolders, so a flat glob such as
# tests/*.test.sh stays literal, matches nothing and fails (or worse, passes
# having run nothing). This runs the command as documented, over a small tree
# with a nested passing and a nested failing suite, and requires it to find both
# and to report the failure in its exit status. The pull request template must
# not carry the flat globs either.
#
# Requires: bash, find, xargs, sort, awk.
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

# The first sh fenced block under the "Tests" heading, as written.
block="$(awk '/^## Tests/{t=1;next} /^## /{t=0} t&&/^```sh/{f=1;next} t&&/^```/{f=0} t&&f' "$HERE/CONTRIBUTING.md")"
check "CONTRIBUTING.md has a documented test command" "1" "$([ -n "$block" ] && echo 1 || echo 0)"

mkdir -p "$WORK/bin" "$WORK/t/tests/a/b" "$WORK/t/scripts/x"
printf '#!/usr/bin/env bash\necho ran-good\nexit 0\n' > "$WORK/t/tests/a/good.test.sh"
printf '#!/usr/bin/env bash\necho ran-bad\nexit 1\n' > "$WORK/t/tests/a/b/bad.test.sh"
printf '#!/usr/bin/env bash\n: ok\n' > "$WORK/t/scripts/x/tool.sh"
chmod +x "$WORK/t/tests/a/good.test.sh" "$WORK/t/tests/a/b/bad.test.sh"
# The documented shellcheck line must reach nested files: the stub records them.
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "%s/shellcheck.args"\n' "$WORK" > "$WORK/bin/shellcheck"
chmod +x "$WORK/bin/shellcheck"

out="$(cd "$WORK/t" && PATH="$WORK/bin:$PATH" bash -c "$block" 2>&1)"
rc=$?
check "a nested failing suite makes the documented command fail" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "the nested passing suite is run" "1" "$(printf '%s' "$out" | grep -c ran-good)"
check "the nested failing suite is run, not skipped after the first failure" "1" "$(printf '%s' "$out" | grep -c ran-bad)"
check "and the failure is named" "1" "$(printf '%s' "$out" | grep -c 'bad.test.sh')"
check "shellcheck is given a nested script" "1" "$(grep -c 'scripts/x/tool.sh' "$WORK/shellcheck.args" 2>/dev/null)"
check "shellcheck is given a nested test" "1" "$(grep -c 'tests/a/good.test.sh' "$WORK/shellcheck.args" 2>/dev/null)"

rm -f "$WORK/t/tests/a/b/bad.test.sh"
out="$(cd "$WORK/t" && PATH="$WORK/bin:$PATH" bash -c "$block" 2>&1)"
rc=$?
check "with every suite passing the documented command succeeds" "0" "$rc"

flat="$(cat "$HERE/CONTRIBUTING.md" "$HERE/.github/PULL_REQUEST_TEMPLATE.md" | grep -cE 'tests/\*\.(test\.)?sh|scripts/\*\.sh')"
check "no flat glob over tests/ or scripts/ is documented" "0" "$flat"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
