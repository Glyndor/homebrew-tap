#!/usr/bin/env bash
#
# Tests for scripts/monitoring/check-render-drift.sh: the named units are
# extracted, compared and counted.
#
# The contract being tested:
#
#   * every named unit inside the local render script must stay
#     byte-identical (after stripping comments and blanks) to the same unit
#     inside the sibling's differently-named render script;
#   * render_product is excluded on purpose, and a change inside it must not
#     turn the check red;
#   * comment-only changes are tolerated (comments legitimately describe each
#     repository);
#   * the script refuses to pass having compared nothing;
#   * an unknown unit name passed to unit_is_complete is refused rather than
#     silently treated as complete.
#
# The cases that pin a change to one unit, the cases that pin a unit that is
# not there, the fetch-failure case and the two version units live in the
# sibling files next to this one.
#
# Network is stubbed: a fake `curl` reads $CURL_STUB_FILE and prints it (or
# fails, if $CURL_STUB_FAIL is set). Nothing here reaches GitHub.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The fixture lives one folder up and holds the stub, the synthetic render
# script and the helpers. The linter cannot follow a sourced path built at
# run time.
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
echo "=== identical units pass and success line reports the compared count ==="
run_with_remote "$(remote_asis)"
expect_eq "$exit_code" "0" "exit 0 when units are identical"
expect_contains "$combined" "compared 8 render unit" "success line names compared 8"
expect_contains "$combined" "verification logic agrees" "success line says logic agrees"

echo
echo "=== a change inside render_product passes, because that unit is excluded ==="
# render_product is the unit that legitimately differs across the two repos.
# The check must stay green and still report every unit compared.
run_with_remote "$(remote_with 's/echo "ruby"/echo "json"/')"
expect_eq "$exit_code" "0" "exit 0 when only render_product differs"
expect_contains "$combined" "compared 8 render unit" "still compares 8 units"
expect_not_contains "$err_body" "drifted" "no drift message"
expect_not_contains "$err_body" "render_product" "the excluded unit is not named as a missing unit either"

echo
echo "=== a comment-only change inside a compared unit passes ==="
# Same logic, extra comments on the remote side. Stripping must absorb them.
run_with_remote "$(remote_with_comment '^hash_of\(\) \{$')"
expect_eq "$exit_code" "0" "exit 0 on comment-only diff"
expect_contains "$combined" "compared 8 render unit" "still compares 8 units"

echo
echo "=== unit_is_complete refuses an unknown unit ==="
# This is the piece that was silently passing. In bash, a case statement with
# no matching branch returns success; without the default branch added to
# unit_is_complete, any unit name not listed there would be declared complete.
# That meant a partial extraction of an unwired unit would be accepted as a
# whole one. Source the function in isolation and call it directly.
if bash -c "$(sed -n '/^unit_is_complete()/,/^}/p' "$SCRIPT")
	unit_is_complete 'anything' 'totally-unknown-unit-name'"; then
	record_fail "unit_is_complete refuses an unknown unit" " (returned 0)"
else
	record_pass "unit_is_complete refuses an unknown unit"
fi

echo
echo "=== the compared count is greater than zero on success ==="
run_with_remote "$(remote_asis)"
expect_eq "$exit_code" "0" "exit 0 on identical run"
expect_compare_count_gt_zero "$combined" "the compared count reported on success is > 0"

echo
echo "=== a local file with none of the units fails rather than comparing nothing ==="
#
# A checker that inspected nothing prints what one that inspected everything
# prints, and that is not hypothetical here: line-limit reported every file
# within its limit on every pull request while never opening a workflow.
#
# What this case pins is that a file carrying none of the units is a failure
# rather than a quiet pass. What it does NOT pin, and cannot, is the
# `compared -eq 0` branch on its own. Measured: emptying the local file sets
# the absent counter as well, because each unit is separately reported as not
# found, so both branches fire together and removing either one still leaves
# the run red. That guard is a backstop for a future edit that empties the
# unit list, where nothing would be absent because nothing was looked for. It
# is correct to keep and it is not independently testable from out here.
local_without_units
run_with_remote "$(remote_asis)"
expect_eq "$exit_code" "1" "a local file carrying no units fails"
expect_not_contains "$combined" "the verification logic agrees" \
	"and does not print the success line"
restore_local

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
