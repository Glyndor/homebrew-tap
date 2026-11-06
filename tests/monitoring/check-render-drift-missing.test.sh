#!/usr/bin/env bash
#
# Tests for scripts/monitoring/check-render-drift.sh: a unit that is not
# there is reported as absent, not as drift.
#
# The contract being tested:
#
#   * a unit whose opening marker is absent on the sibling's side is named,
#     and the run fails: renaming a unit breaks the contract, and a check
#     that compared a half unit would be comparing the wrong thing;
#   * a renamed key declaration is absent rather than drift, and the rotation
#     message is not invoked either;
#   * the report points at the sibling's file, not at this repository's.
#
# The units that do differ, the fetch failure and the two version units live
# in the sibling files next to this one.
#
# Network is stubbed: a fake `curl` reads $CURL_STUB_FILE and prints it.
# Nothing here reaches GitHub.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$here/../fixtures/monitoring/render-drift-fixture.sh"
# The linter cannot follow a sourced path built at run time, and the fixture
# is where the counters and the read-back of the last run live. The disable
# is on the source line alone; the variables are re-declared here so nothing
# downstream has to be excused for reading them.
pass=0
fail=0
exit_code=0
err_body=""

echo
echo "=== a unit missing from the remote file fails and names which unit ==="
# verify_sha256sums is gone on the remote side. release_keys and hash_of are
# still present so the absent count is exactly one and the message names that
# one without naming the others.
run_with_remote "$(remote_with '/^verify_sha256sums() {/,/^}/d')"
expect_eq "$exit_code" "1" "exit 1 when a unit is missing on the remote"
expect_contains "$err_body" "verify_sha256sums could not be found" "names the missing unit"
expect_contains "$err_body" "$REMOTE_FILE" "points at the remote file path"

echo
echo "=== verify_attestation missing on the remote side is reported by name ==="
# The unit is gone on the remote side. The drift script must name it the
# same way it names the older units when they are missing.
run_with_remote "$(remote_with '/^verify_attestation() {/,/^}/d')"
expect_eq "$exit_code" "1" "exit 1 when verify_attestation is missing on the remote"
expect_contains "$err_body" "verify_attestation could not be found" "names the missing unit"

echo
echo "=== a renamed key declaration on the remote is absent, not drift ==="
# The opening marker (RELEASE_PUBKEY_B64=) is gone from the remote. The
# extraction returns nothing, so the unit is reported as missing rather than
# compared as drift. This is the same distinction the script already keeps
# for the function-style units: a renamed unit is a contract break, not a
# diff.
run_with_remote "$(remote_with 's/^RELEASE_PUBKEY_B64=/RELEASE_PUBKEY_B64_OLD=/')"
expect_eq "$exit_code" "1" "exit 1 when a key declaration is renamed on the remote"
expect_contains "$err_body" "release_keys could not be found" "names release_keys as missing"
expect_not_contains "$err_body" "release_keys has drifted" "does not call a missing unit a drift"
expect_not_contains "$err_body" "trust different release keys" "does not invoke the rotation message either"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
