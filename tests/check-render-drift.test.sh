#!/usr/bin/env bash
#
# Tests for scripts/check-render-drift.sh.
#
# The contract being tested:
#
#   * three named units (verify_sha256sums, py_block, hash_of) inside the
#     local render script must stay byte-identical (after stripping comments
#     and blanks) to the same units inside the sibling's differently-named
#     render script;
#   * render_product is excluded on purpose, and a change inside it must not
#     turn the check red;
#   * comment-only changes are tolerated (comments legitimately describe each
#     repository);
#   * a unit renamed on the remote side fails loudly with the unit's name;
#   * a network failure is reported as a fetch failure, not as drift;
#   * the script refuses to pass having compared nothing.
#
# Network is stubbed: a fake `curl` reads $CURL_STUB_FILE and prints it (or
# fails, if $CURL_STUB_FAIL is set). Nothing here reaches GitHub.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../scripts/check-render-drift.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin" "$work/scripts"

# Fake curl. If CURL_STUB_FAIL is set, exit 22 (HTTP 4xx is what -f maps to).
# Otherwise print CURL_STUB_FILE, which the caller has populated.
cat > "$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
if [ "${CURL_STUB_FAIL:-}" = "1" ]; then
	echo "curl: stubbed network failure to GitHub" >&2
	exit 22
fi
cat "${CURL_STUB_FILE:-/dev/null}"
STUB
chmod +x "$work/bin/curl"

# Baseline local render script. All four named units are present; the local
# script carries NO comments so the comment-only test has to add them on the
# remote side.
cat > "$work/scripts/render-formulae.sh" <<'LOCAL'
#!/usr/bin/env bash
set -euo pipefail

verify_sha256sums() {
	rm -f "$work/SHA256SUMS"
	gh release download "$2" --repo "$1" --pattern SHA256SUMS --dir "$work"
	python3 - <<'PY'
import sys
def load(b64):
	b64 = b64.strip()
	return b64
msg = open(sys.argv[1], "rb").read()
print("verify", msg)
PY
}

hash_of() {
	local matches
	matches="$(awk -v a="$1" '$2 == a { print $1 }' "$work/SHA256SUMS")"
	echo "$matches"
}

render_product() {
	echo "ruby"
}
LOCAL

pass=0
fail=0

record_pass() { pass=$((pass + 1)); echo "  pass: $1"; }
record_fail() { fail=$((fail + 1)); echo "  FAIL: $1${2:-}"; }

expect_eq() { # $1 actual $2 expected $3 desc
	if [ "$1" = "$2" ]; then
		record_pass "$3 (got $1)"
	else
		record_fail "$3" " (expected $2, got $1)"
	fi
}

expect_contains() { # $1 haystack $2 needle $3 desc
	if printf '%s\n' "$1" | grep -qF -- "$2"; then
		record_pass "$3"
	else
		record_fail "$3" " (no match for: $2)"
	fi
}

expect_not_contains() { # $1 haystack $2 needle $3 desc
	if ! printf '%s\n' "$1" | grep -qF -- "$2"; then
		record_pass "$3"
	else
		record_fail "$3" " (unexpectedly contained: $2)"
	fi
}

expect_compare_count_gt_zero() { # $1 output $2 desc
	local n
	n=$(printf '%s\n' "$1" | grep -oE 'compared [0-9]+' | head -1 | grep -oE '[0-9]+' || true)
	if [ -n "$n" ] && [ "$n" -gt 0 ]; then
		record_pass "$2 (count=$n)"
	else
		record_fail "$2" " (no 'compared N' line with N > 0)"
	fi
}

# Run the check with the local temp repo and the given remote fixture file.
run_with_remote() { # $1 = remote file path
	cp "$1" "$work/remote"
	set +e
	CURL_STUB_FILE="$work/remote" PATH="$work/bin:$PATH" \
		bash "$script" "$work" >"$work/out" 2>"$work/err"
	echo $? >"$work/exit"
	set -e
}

# Run the check with curl failing entirely.
run_with_curl_fail() {
	set +e
	CURL_STUB_FAIL=1 PATH="$work/bin:$PATH" \
		bash "$script" "$work" >"$work/out" 2>"$work/err"
	echo $? >"$work/exit"
	set -e
}

# Read back the most recent run.
exit_code=$(cat "$work/exit" 2>/dev/null || echo 999)
out_body=$(cat "$work/out" 2>/dev/null || true)
err_body=$(cat "$work/err" 2>/dev/null || true)
combined="$out_body$err_body"

echo
echo "=== identical units pass and success line reports the compared count ==="
cp "$work/scripts/render-formulae.sh" "$work/remote.sh"
run_with_remote "$work/remote.sh"
exit_code=$(cat "$work/exit"); out_body=$(cat "$work/out"); err_body=$(cat "$work/err"); combined="$out_body$err_body"
expect_eq "$exit_code" "0" "exit 0 when units are identical"
expect_contains "$combined" "compared 3 render unit" "success line names compared 3"
expect_contains "$combined" "verification logic agrees" "success line says logic agrees"

echo
echo "=== a change inside verify_sha256sums fails and names that unit ==="
# Change lives in the shell prelude, BEFORE <<'PY', so py_block itself is
# unaffected: only verify_sha256sums should drift.
cat > "$work/remote.sh" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

verify_sha256sums() {
	rm -f "$work/SHA256SUMS"
	gh release download "$2" --repo "$1" --pattern SHA256SUMS --pattern SHA256SUMS.sig --dir "$work"
	python3 - <<'PY'
import sys
def load(b64):
	b64 = b64.strip()
	return b64
msg = open(sys.argv[1], "rb").read()
print("verify", msg)
PY
}

hash_of() {
	local matches
	matches="$(awk -v a="$1" '$2 == a { print $1 }' "$work/SHA256SUMS")"
	echo "$matches"
}

render_product() {
	echo "ruby"
}
REMOTE
run_with_remote "$work/remote.sh"
exit_code=$(cat "$work/exit"); out_body=$(cat "$work/out"); err_body=$(cat "$work/err"); combined="$out_body$err_body"
expect_eq "$exit_code" "1" "exit 1 on drift in verify_sha256sums"
expect_contains "$err_body" "verify_sha256sums has drifted" "names verify_sha256sums"
expect_not_contains "$err_body" "py_block has drifted" "does not falsely name py_block"
expect_not_contains "$err_body" "hash_of has drifted" "does not falsely name hash_of"

echo
echo "=== a change inside the python block fails and names that unit ==="
# This change is INSIDE <<'PY'...PY. The py_block comparison must report drift.
cat > "$work/remote.sh" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

verify_sha256sums() {
	rm -f "$work/SHA256SUMS"
	gh release download "$2" --repo "$1" --pattern SHA256SUMS --dir "$work"
	python3 - <<'PY'
import sys
def load(b64):
	b64 = b64.strip()
	b64 = b64.lower()
	return b64
msg = open(sys.argv[1], "rb").read()
print("verify", msg)
PY
}

hash_of() {
	local matches
	matches="$(awk -v a="$1" '$2 == a { print $1 }' "$work/SHA256SUMS")"
	echo "$matches"
}

render_product() {
	echo "ruby"
}
REMOTE
run_with_remote "$work/remote.sh"
exit_code=$(cat "$work/exit"); out_body=$(cat "$work/out"); err_body=$(cat "$work/err"); combined="$out_body$err_body"
expect_eq "$exit_code" "1" "exit 1 on drift in py_block"
expect_contains "$err_body" "py_block has drifted" "names py_block"

echo
echo "=== a change inside render_product passes, because that unit is excluded ==="
# render_product is the unit that legitimately differs across the two repos.
# The check must stay green and still report 3 compared units.
cat > "$work/remote.sh" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

verify_sha256sums() {
	rm -f "$work/SHA256SUMS"
	gh release download "$2" --repo "$1" --pattern SHA256SUMS --dir "$work"
	python3 - <<'PY'
import sys
def load(b64):
	b64 = b64.strip()
	return b64
msg = open(sys.argv[1], "rb").read()
print("verify", msg)
PY
}

hash_of() {
	local matches
	matches="$(awk -v a="$1" '$2 == a { print $1 }' "$work/SHA256SUMS")"
	echo "$matches"
}

render_product() {
	# This is TOTALLY different. It must NOT be compared.
	echo "json"
	echo "completely"
	echo "different"
}
REMOTE
run_with_remote "$work/remote.sh"
exit_code=$(cat "$work/exit"); out_body=$(cat "$work/out"); err_body=$(cat "$work/err"); combined="$out_body$err_body"
expect_eq "$exit_code" "0" "exit 0 when only render_product differs"
expect_contains "$combined" "compared 3 render unit" "still compares 3 units"
expect_not_contains "$err_body" "drifted" "no drift message"
expect_not_contains "$err_body" "render_product" "the excluded unit is not named as a missing unit either"

echo
echo "=== a comment-only change inside a compared unit passes ==="
# Same logic, extra comments on the remote side. Stripping must absorb them.
cat > "$work/remote.sh" <<'REMOTE'
#!/usr/bin/env bash
# This entire header comment is on the remote side only.
set -euo pipefail

verify_sha256sums() {
	# Inside the function: a remote-only comment
	rm -f "$work/SHA256SUMS"
	gh release download "$2" --repo "$1" --pattern SHA256SUMS --dir "$work"
	python3 - <<'PY'
import sys
# Comment inside the python block, remote-only.
def load(b64):
	b64 = b64.strip()
	return b64
msg = open(sys.argv[1], "rb").read()
print("verify", msg)
PY
	# Trailing comment in the function, remote-only.
}

hash_of() {
	# Remote-only comment in hash_of.
	local matches
	matches="$(awk -v a="$1" '$2 == a { print $1 }' "$work/SHA256SUMS")"
	echo "$matches"
}

render_product() {
	echo "ruby"
}
REMOTE
run_with_remote "$work/remote.sh"
exit_code=$(cat "$work/exit"); out_body=$(cat "$work/out"); err_body=$(cat "$work/err"); combined="$out_body$err_body"
expect_eq "$exit_code" "0" "exit 0 on comment-only diff"
expect_contains "$combined" "compared 3 render unit" "still compares 3 units"

echo
echo "=== a unit missing from the remote file fails and names which unit ==="
# verify_sha256sums is gone on the remote side.
cat > "$work/remote.sh" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

hash_of() {
	local matches
	matches="$(awk -v a="$1" '$2 == a { print $1 }' "$work/SHA256SUMS")"
	echo "$matches"
}

render_product() {
	echo "ruby"
}
REMOTE
run_with_remote "$work/remote.sh"
exit_code=$(cat "$work/exit"); out_body=$(cat "$work/out"); err_body=$(cat "$work/err"); combined="$out_body$err_body"
expect_eq "$exit_code" "1" "exit 1 when a unit is missing on the remote"
expect_contains "$err_body" "verify_sha256sums could not be found" "names the missing unit"
expect_contains "$err_body" "scripts/render-manifests.sh" "points at the remote file path"

echo
echo "=== a curl failure produces the fetch message, not the drift message ==="
run_with_curl_fail
exit_code=$(cat "$work/exit"); out_body=$(cat "$work/out"); err_body=$(cat "$work/err"); combined="$out_body$err_body"
expect_eq "$exit_code" "1" "exit 1 on curl failure"
expect_contains "$err_body" "fetch failure, not drift" "uses the fetch-failure wording"
expect_contains "$err_body" "could not fetch" "says the fetch failed"
expect_not_contains "$err_body" "verification logic agrees" "does not claim agreement"
expect_not_contains "$err_body" "has drifted" "does not conflate fetch failure with drift"

echo
echo "=== the compared count is greater than zero on success ==="
run_with_remote "$work/scripts/render-formulae.sh"
exit_code=$(cat "$work/exit"); out_body=$(cat "$work/out"); err_body=$(cat "$work/err"); combined="$out_body$err_body"
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
cp "$work/scripts/render-formulae.sh" "$work/local-backup.sh"
: > "$work/scripts/render-formulae.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\necho "no units at all"\n' \
	> "$work/scripts/render-formulae.sh"
cp "$work/local-backup.sh" "$work/remote.sh"
run_with_remote "$work/remote.sh"
exit_code=$(cat "$work/exit"); out_body=$(cat "$work/out"); err_body=$(cat "$work/err"); combined="$out_body$err_body"
expect_eq "$exit_code" "1" "a local file carrying no units fails"
expect_not_contains "$combined" "the verification logic agrees" \
	"and does not print the success line"
cp "$work/local-backup.sh" "$work/scripts/render-formulae.sh"

echo
echo "--- summary ---"
echo "passed: $pass"
echo "failed: $fail"

if [ "$fail" -ne 0 ]; then
	exit 1
fi
