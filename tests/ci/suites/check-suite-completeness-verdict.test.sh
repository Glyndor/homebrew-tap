#!/usr/bin/env bash
#
# The runner of the suites turns a red suite into a red job, and it does it in
# two lines: one compares the exit status of the suite with 0, the other
# compares the failure count in the suite's sentinel with 0. Nothing else in the
# repository makes `shell / test` red for a suite that failed, so a runner that
# lost either line would leave that required check green over a failing suite.
#
# The runner's own case (in check-suite-completeness.test.sh) feeds it two
# suites that both exit 0, so it can say nothing about the verdict. Here the
# real runner is given suites that end in each way, and each refusal has to name
# the check that made it, so a suite refused for another reason does not count:
#
#   * a suite that prints its sentinel with no failure and exits 1,
#   * a suite that prints its sentinel with one failure and exits 0,
#   * a suite that exits 0 and prints no sentinel at all.
#
# Each is paired with the honest suite, which has to be accepted: without it, a
# fixture refused for an unrelated reason would satisfy every rejection.
#
# The runner is run directly, with the nested-run switch its own fixture case
# uses, and with no pull request in the environment, so it does not read the
# history of the repository and runs every suite it is given.
set -u

cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit 1
ROOT="$(pwd)"
RUNNER="$ROOT/tests/ci/suites/check-suite-completeness.test.sh"

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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# <name> <sentinel pass count> <sentinel fail count> <exit status>
suite() {
	cat > "$WORK/$1" <<FIXTURE
#!/usr/bin/env bash
echo "ran $1"
printf 'DONE %s $2 $3\n' "\${BASH_SOURCE[0]##*/}"
exit $4
FIXTURE
	chmod +x "$WORK/$1"
}

suite honest.test.sh 3 0 0
suite bad-exit.test.sh 3 0 1
suite bad-count.test.sh 3 1 0

# Exits 0 and never prints a sentinel.
cat > "$WORK/no-sentinel.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
echo "ran no-sentinel.test.sh"
exit 0
FIXTURE
chmod +x "$WORK/no-sentinel.test.sh"

OUT=""
RC=0
run_runner() { # <suite names...>: runs the real runner over the fixtures
	local args=() n
	for n in "$@"; do args+=("$WORK/$n"); done
	OUT="$(env -u GITHUB_EVENT_NAME -u GITHUB_STEP_SUMMARY \
		CHECK_SUITE_COMPLETENESS_SKIP_FIXTURE_TEST=1 \
		bash "$RUNNER" "${args[@]}" 2>&1)"
	RC=$?
}

said() { # <fixed text> -> 1 when the runner's output holds it
	if printf '%s\n' "$OUT" | grep -qF -- "$1"; then echo 1; else echo 0; fi
}

# --- the accepted case ---------------------------------------------------------

run_runner honest.test.sh
check "a suite that reaches its end, reports no failure and exits 0 is accepted" "0" "$RC"
check "and the runner says it exited 0" "1" "$(said 'ok    honest.test.sh exited 0')"
check "and says it reported no failed check" "1" "$(said 'ok    honest.test.sh reported no failed check')"

# --- a suite that exits non-zero -----------------------------------------------

run_runner bad-exit.test.sh
check "a suite that exits 1 makes the runner exit 1" "1" "$RC"
check "and the refusal is for the exit status" "1" "$(said 'FAIL  bad-exit.test.sh exited 0')"
check "and not for a missing sentinel" "0" "$(said 'FAIL  bad-exit.test.sh reached its end')"
check "and not for the count its sentinel carries" "0" "$(said 'FAIL  bad-exit.test.sh reported no failed check')"

# --- a suite that reports a failed check but exits 0 ---------------------------

run_runner bad-count.test.sh
check "a suite whose sentinel counts a failure makes the runner exit 1" "1" "$RC"
check "and the refusal is for the count" "1" "$(said 'FAIL  bad-count.test.sh reported no failed check')"
check "and not for the exit status" "0" "$(said 'FAIL  bad-count.test.sh exited 0')"

# --- a suite that never reaches its end ----------------------------------------

run_runner no-sentinel.test.sh
check "a suite that prints no sentinel makes the runner exit 1" "1" "$RC"
check "and the refusal is for the missing sentinel" "1" "$(said 'FAIL  no-sentinel.test.sh reached its end')"
check "and not for the exit status" "0" "$(said 'FAIL  no-sentinel.test.sh exited 0')"

# --- one bad suite among good ones -----------------------------------------------

run_runner honest.test.sh bad-exit.test.sh
check "one failing suite among good ones still fails the run" "1" "$RC"
check "and the good one is still reported as passing" "1" "$(said 'ok    honest.test.sh exited 0')"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
