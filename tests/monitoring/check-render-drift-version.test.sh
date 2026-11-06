#!/usr/bin/env bash
#
# Tests for scripts/monitoring/check-render-drift.sh: the two units that
# decide whether a release is admitted, and what a channel does to the other.
#
# The contract being tested:
#
#   * release_order -- the SemVer comparison and the refusal of a rollback --
#     and version_guard -- the character set the release tag is held to --
#     are compared between the channels;
#   * a change inside either of them, applied to one channel only, is
#     reported as drift and names that unit;
#   * a unit whose opening marker is gone on the sibling's side is reported
#     as absent, not as drift.
#
# The sabotage here is a real edit to this repository's own render script,
# not to a stand-in: the control these cases protect is the one that decides
# whether a release older than the served one is published, and whether a tag
# carrying code reaches the generated artifact. Editing a fixture would
# prove the check reacts to a fixture.
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
combined=""

echo
echo "=== this repository's render script agrees with an untouched copy of itself ==="
# The baseline: the units are compared, and the two copies are the same file,
# so nothing has drifted. Without this, every case below would pass on a
# check that compares nothing at all.
real_local >/dev/null
run_with_remote "$(remote_asis)"
expect_eq "$exit_code" "0" "exit 0 when the two copies are the same script"
expect_contains "$combined" "compared 8 render unit" "and all eight units were compared"

echo
echo "=== a comparison that never reports a rollback is drift, named as release_order ==="
# The sabotage: the SemVer comparison always answers "higher", so an older
# release is never refused and the channel would move backwards. Before
# release_order joined the contract this edit was invisible to the drift
# check: each channel's own suite caught it, and the check stayed green.
real_local >/dev/null
run_with_remote "$(remote_replacing \
	'print("lower" if new < old else "higher" if new > old else "equal")' \
	'print("higher")')"
expect_eq "$exit_code" "1" "exit 1 when the comparison is sabotaged in one channel"
expect_contains "$err_body" "release_order has drifted" "names the release_order unit"
expect_contains "$err_body" "1 of 8 compared render unit(s) have drifted" "counts one drifted unit of eight"
expect_not_contains "$err_body" "could not be found" "and no unit is reported missing"

echo
echo "=== a tag guard that accepts anything is drift, named as version_guard ==="
# The sabotage: the character set the release tag is held to collapses to
# "anything", so a tag carrying code reaches the generated artifact. Before
# version_guard joined the contract this edit was invisible to the drift
# check in exactly the same way.
real_local >/dev/null
run_with_remote "$(remote_replacing \
	$'"" | *[!0-9A-Za-z.+-]* | .* | *.)' \
	$'"" | .* | *.)')"
expect_eq "$exit_code" "1" "exit 1 when the tag guard is sabotaged in one channel"
expect_contains "$err_body" "version_guard has drifted" "names the version_guard unit"
expect_contains "$err_body" "1 of 8 compared render unit(s) have drifted" "counts one drifted unit of eight"
expect_not_contains "$err_body" "could not be found" "and no unit is reported missing"

echo
echo "=== a renamed release_order on the sibling side is absent, not drift ==="
# The opening marker is gone on the sibling's side, so the extraction finds
# nothing. A renamed unit is a contract break, not a diff.
real_local >/dev/null
run_with_remote "$(remote_with 's/^release_order()/release_order_renamed()/')"
expect_eq "$exit_code" "1" "exit 1 when release_order is renamed on the remote"
expect_contains "$err_body" "release_order could not be found" "names release_order as missing"
expect_not_contains "$err_body" "release_order has drifted" "does not call a missing unit a drift"

echo
echo "=== a missing version_guard on the sibling side is absent, not drift ==="
synthetic_local >/dev/null
run_with_remote "$(remote_with '/^version_guard() {/,/^}/d')"
expect_eq "$exit_code" "1" "exit 1 when version_guard is missing on the remote"
expect_contains "$err_body" "version_guard could not be found" "names version_guard as missing"
expect_not_contains "$err_body" "version_guard has drifted" "does not call a missing unit a drift"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
