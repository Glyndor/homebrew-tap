#!/usr/bin/env bash
#
# Tests for scripts/monitoring/check-render-drift.sh: a fetch failure is not
# drift.
#
# The contract being tested:
#
#   * a network failure is reported as a fetch failure, not as drift;
#   * the run does not claim the two sides agree when it could not read one
#     of them;
#   * a fetch failure and a drift never share a message.
#
# Conflating the two teaches people that a red check means "try again later",
# which is exactly the habit that lets a genuine one through.
#
# Network is stubbed: a fake `curl` fails when $CURL_STUB_FAIL is set.
# Nothing here reaches GitHub.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$here/../../fixtures/monitoring/render-drift-fixture.sh"
# The linter cannot follow a sourced path built at run time, and the fixture
# is where the counters and the read-back of the last run live. The disable
# is on the source line alone; the variables are re-declared here so nothing
# downstream has to be excused for reading them.
pass=0
fail=0
exit_code=0
err_body=""

echo
echo "=== a curl failure produces the fetch message, not the drift message ==="
run_with_curl_fail
expect_eq "$exit_code" "1" "exit 1 on curl failure"
expect_contains "$err_body" "fetch failure, not drift" "uses the fetch-failure wording"
expect_contains "$err_body" "could not fetch" "says the fetch failed"
expect_not_contains "$err_body" "verification logic agrees" "does not claim agreement"
expect_not_contains "$err_body" "has drifted" "does not conflate fetch failure with drift"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
