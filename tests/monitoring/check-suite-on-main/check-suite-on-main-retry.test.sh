#!/usr/bin/env bash
#
# Behaviour tests for the schedule and pull_request path of
# scripts/monitoring/check-suite-on-main.sh: a transient gh failure is asked
# again, and one that never clears ends red. The push path always did this
# (check-suite-on-main-push.test.sh); this path made a single call, so one 502
# turned the twice-daily check red for nothing.
#
# The fake `gh`, the builders and the runners come from
# tests/fixtures/monitoring/check-suite-on-main-fixture.sh.
#
# Requires: jq (same as the script itself).
set -uo pipefail

# shellcheck source=tests/fixtures/monitoring/check-suite-on-main-fixture.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/fixtures/monitoring/check-suite-on-main-fixture.sh"

pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

ok_page() {
	push_page "$(push_run_obj b completed success 2026-09-19T15:22:53Z 200)"
}
three_pages() { write_responses "$(ok_page)" "$(ok_page)" "$(ok_page)"; }

three_pages
run_env schedule b
check "control: a scheduled run with no failing call is green" "0" "$rc"
check "control: and asked the API once" "1" "$(count_log "$WORK/gh.log")"

three_pages
STUB_FAIL_FIRST=1 run_env schedule b
check "one failing gh call is survived" "0" "$rc"
check "and it says it is asking again" "1" "$(said 'asking again')"
check "and waited before asking again" "1" "$(count_log "$WORK/sleep.log")"

three_pages
STUB_FAIL_FIRST=2 run_env schedule b
check "two failing gh calls are survived" "0" "$rc"

three_pages
STUB_FAIL_FIRST=99 run_env schedule b
check "a gh failure that never clears ends red" "1" "$rc"
check "and says there was no verdict" "1" "$(said 'no verdict on')"
check "and asked exactly three times" "3" "$(count_log "$WORK/gh.log")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
