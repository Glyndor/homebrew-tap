#!/usr/bin/env bash
#
# Tests for scripts/monitoring/check-render-drift.sh: the refusal of an
# upper-case digest is one of the units the two channels must agree on.
#
# The renderer compares the digest the verified SHA256SUMS gives with the
# lowercase digest of the download, so a channel that stops refusing an
# upper-case one publishes a release the other channel refuses. Before the unit
# joined the contract, a change to it in one channel left the drift check green.
#
#   * a change inside digest_case_guard, applied to one channel only, is
#     reported as drift and names that unit;
#   * a digest_case_guard that is gone on the sibling's side is reported as
#     absent, not as drift.
#
# The sabotage is a real edit to this repository's own render script. Network
# is stubbed: a fake `curl` reads $CURL_STUB_FILE and prints it.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$here/../../fixtures/monitoring/render-drift-fixture.sh"
pass=0
fail=0
exit_code=0
err_body=""
combined=""

echo
echo "=== an untouched copy agrees, and the unit is among those compared ==="
real_local >/dev/null
run_with_remote "$(remote_asis)"
expect_eq "$exit_code" "0" "exit 0 when the two copies are the same script"
expect_contains "$combined" "compared 9 render unit" "and all nine units were compared"

echo
echo "=== a guard that stops refusing upper case is drift, named as digest_case_guard ==="
real_local >/dev/null
run_with_remote "$(remote_replacing '*[A-F]*)' '*[Z]*)')"
expect_eq "$exit_code" "1" "exit 1 when the guard is sabotaged in one channel"
expect_contains "$err_body" "digest_case_guard has drifted" "names the digest_case_guard unit"
expect_contains "$err_body" "1 of 9 compared render unit(s) have drifted" "counts one drifted unit of nine"
expect_not_contains "$err_body" "could not be found" "and no unit is reported missing"

echo
echo "=== a missing digest_case_guard on the sibling side is absent, not drift ==="
synthetic_local >/dev/null
run_with_remote "$(remote_with '/^digest_case_guard() {/,/^}/d')"
expect_eq "$exit_code" "1" "exit 1 when digest_case_guard is missing on the remote"
expect_contains "$err_body" "digest_case_guard could not be found" "names digest_case_guard as missing"
expect_not_contains "$err_body" "digest_case_guard has drifted" "does not call a missing unit a drift"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
