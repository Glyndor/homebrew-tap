#!/usr/bin/env bash
#
# Tests for scripts/monitoring/check-render-drift.sh: a change inside one
# named unit is drift, and the report names that unit.
#
# The contract being tested:
#
#   * a unit whose logic differs from the sibling's is reported as drift, and
#     the report names the unit rather than the file;
#   * a change inside one unit does not drag the other units in with it;
#   * a relaxed download cap is drift, named as the limits unit;
#   * a key rotation that landed in only one channel is drift, and the
#     message says what the reader has to do about it.
#
# The units that are not there, the fetch failure and the two version units
# live in the sibling files next to this one.
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
echo "=== drift in one unit, every unit present, is a failure by itself ==="
# The other drift cases also leave a unit out of the remote file, so they exit 1
# for being absent; none proves that drift alone ends the run non-zero. Here all
# the units exist on both sides and exactly one line of hash_of differs.
run_with_remote "$(remote_with 's/matches=/matches2=/')"
expect_eq "$exit_code" "1" "exit 1 when a single unit differs and none is missing"
expect_contains "$err_body" "1 of 8 compared render unit(s) have drifted" "counts one drifted unit of eight"
expect_not_contains "$err_body" "could not be found" "and no unit is reported missing"

echo
echo "=== a change inside verify_sha256sums fails and names that unit ==="
# Change lives in the shell prelude, BEFORE <<'PY', so py_block itself is
# unaffected: only verify_sha256sums should drift.
run_with_remote "$(remote_with 's|--pattern SHA256SUMS --dir|--pattern SHA256SUMS --pattern SHA256SUMS.sig --dir|')"
expect_eq "$exit_code" "1" "exit 1 on drift in verify_sha256sums"
expect_contains "$err_body" "verify_sha256sums has drifted" "names verify_sha256sums"
expect_not_contains "$err_body" "py_block has drifted" "does not falsely name py_block"
expect_not_contains "$err_body" "hash_of has drifted" "does not falsely name hash_of"
expect_not_contains "$err_body" "verify_attestation has drifted" "does not falsely name verify_attestation"

echo
echo "=== a change inside the python block fails and names that unit ==="
# This change is INSIDE <<'PY'...PY. The py_block comparison must report drift.
run_with_remote "$(remote_with 's/b64 = b64.strip()/b64 = b64.lower()/')"
expect_eq "$exit_code" "1" "exit 1 on drift in py_block"
expect_contains "$err_body" "py_block has drifted" "names py_block"
expect_not_contains "$err_body" "verify_attestation has drifted" "does not falsely name verify_attestation"

echo
echo "=== a change inside verify_attestation fails and names that unit ==="
# verify_attestation is a function the drift script must compare: a change
# inside it that lands only on one side is the exact failure mode a
# provenance-verification edit would introduce.
# The $3 has to reach sed literally: it is the shell's own positional
# parameter in the synthetic script, and the shell that reads the case must
# not expand it here.
# shellcheck disable=SC2016
run_with_remote "$(remote_with 's|--source-ref "\$3"|--source-ref "\$3" --deny-self-hosted-runners|')"
expect_eq "$exit_code" "1" "exit 1 on drift in verify_attestation"
expect_contains "$err_body" "verify_attestation has drifted" "names verify_attestation"
expect_not_contains "$err_body" "verify_sha256sums has drifted" "does not falsely name verify_sha256sums"
expect_not_contains "$err_body" "py_block has drifted" "does not falsely name py_block"
expect_not_contains "$err_body" "hash_of has drifted" "does not falsely name hash_of"

echo
echo "=== a download cap relaxed on the remote is drift, named as limits ==="
# Derived from the baseline so only the cap differs and every unit is present.
run_with_remote "$(remote_with 's/^MAX_ASSET_BYTES=.*/MAX_ASSET_BYTES=999999999999/')"
expect_eq "$exit_code" "1" "exit 1 when a download cap differs"
expect_contains "$err_body" "limits has drifted" "names the limits unit"
expect_not_contains "$err_body" "release_keys has drifted" "does not blame the keys"

echo
echo "=== a different RELEASE_PUBKEY_B64 on the remote is drift, named as a rotation ==="
# RELEASE_PUBKEY_B64 differs on the remote side; everything else matches.
# The drift must be reported in release_keys, and the message must name the
# keys and the rotation -- not just the unit -- because the reader has to act
# on it: a rotation that landed in only one channel has to land in the other.
run_with_remote "$(remote_with 's|^RELEASE_PUBKEY_B64=.*|RELEASE_PUBKEY_B64="REMOTE-only-key-cccccccccccccccccccccccccccccc"|')"
expect_eq "$exit_code" "1" "exit 1 on key-only drift"
expect_contains "$err_body" "release_keys has drifted" "names the release_keys unit"
expect_contains "$err_body" "RELEASE_PUBKEY_B64" "the diff itself shows RELEASE_PUBKEY_B64"
expect_contains "$err_body" "trust different release keys" "the message explains the meaning of the mismatch"
expect_contains "$err_body" "rotation has to land in both" "the message tells the reader what to do"
expect_not_contains "$err_body" "verify_sha256sums has drifted" "does not falsely name the other units"
expect_not_contains "$err_body" "py_block has drifted" "does not falsely name the other units"
expect_not_contains "$err_body" "hash_of has drifted" "does not falsely name the other units"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
