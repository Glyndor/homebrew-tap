#!/usr/bin/env bash
#
# Shared fixture for the check-render-drift tests. Sourced, never run: it
# stands up a stub `curl` that serves a fixture file instead of reaching
# GitHub, writes a synthetic render script carrying every named unit the
# drift check compares, and provides the helpers that run the check and read
# back what it said.
#
# It exists because the cases outgrew one file. tests/monitoring/check-render-drift.test.sh
# was 478 code lines before the two version units joined the contract, against
# a 300-line soft limit and a 500-line hard one. Splitting the cases and
# duplicating the fixture would have left two copies of a stub to keep in
# step, which is the shape that has bitten this organisation before, so the
# fixture moved here and every file sources it.
#
# The two render scripts have different names on the two sides -- one renders
# Ruby formulae, the other JSON manifests -- so the fixture reads the two
# names out of the check itself rather than repeating them. The same fixture
# therefore serves both channels unchanged.
#
# Not named *.test.sh on purpose: tests/ci/suites/ci-runs-every-test.test.sh requires
# every test file to be invoked by a workflow, and this one is not a test.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$HERE/scripts/monitoring/check-render-drift.sh"
WORK="$(mktemp -d)"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

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

# --- the two files the check names ------------------------------------------
#
# The check declares which render script it reads on this side and which one
# it fetches from the sibling. The tests read those two names out of the
# script rather than repeating them, so the same fixture serves both
# channels: this repository reads render-formulae.sh and the sibling serves
# render-manifests.sh, and the other way round.
LOCAL_FILE="$(sed -n 's/^LOCAL_FILE="\(.*\)"$/\1/p' "$SCRIPT")"
# REMOTE_FILE is read by the test files that source this fixture, not by the
# fixture. The linter cannot see across the source, so it calls it unused.
# shellcheck disable=SC2034
REMOTE_FILE="$(sed -n 's/^REMOTE_FILE="\(.*\)"$/\1/p' "$SCRIPT")"

# --- the stub that replaces the network -------------------------------------
#
# If CURL_STUB_FAIL is set, exit 22 (HTTP 4xx is what -f maps to). Otherwise
# print CURL_STUB_FILE, which the caller has populated.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
if [ "${CURL_STUB_FAIL:-}" = "1" ]; then
	echo "curl: stubbed network failure to GitHub" >&2
	exit 22
fi
cat "${CURL_STUB_FILE:-/dev/null}"
STUB
chmod +x "$WORK/bin/curl"

# --- the synthetic render script the check reads ----------------------------
#
# Every named unit the check compares is present: verify_sha256sums, py_block,
# hash_of, release_keys, verify_attestation, limits, release_order,
# version_guard and digest_case_guard. The script carries NO comments, so the comment-only case has
# to add them on the remote side.
mkdir -p "$WORK/$(dirname "$LOCAL_FILE")"

write_synthetic() {
cat > "$WORK/$LOCAL_FILE" <<'LOCAL'
#!/usr/bin/env bash
set -euo pipefail

RELEASE_PUBKEY_B64="local-key-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
RELEASE_PUBKEY2_B64="local-key-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
MAX_SUMS_BYTES=4096
MAX_SIG_BYTES=64
MAX_ASSET_BYTES=104857600

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

verify_attestation() {
	gh attestation verify "$1" --repo "$2" --source-ref "$3"
}

release_order() {
	python3 - "$1" "$2" <<'SEMVER'
import re, sys
served, candidate = sys.argv[1:]
print("lower" if candidate < served else "higher")
SEMVER
}

version_guard() {
	case "$3" in
		"" | *[!0-9A-Za-z.+-]* | .* | *.)
			return 1
			;;
	esac
}

digest_case_guard() {
	case "$4" in
		*[A-F]*)
			return 1
			;;
	esac
}

render_product() {
	echo "ruby"
}
LOCAL
}

write_synthetic

# The synthetic script, byte for byte, is what the check reads on this side.
synthetic_local() {
	write_synthetic
	printf '%s\n' "$WORK/$LOCAL_FILE"
}

# The repository's own render script, copied in. The cases that sabotage a
# unit use this one rather than the synthetic script: the sabotage has to be
# a real edit to the code that decides whether a release is trusted, not an
# edit to a stand-in.
real_local() {
	cp "$HERE/$LOCAL_FILE" "$WORK/$LOCAL_FILE"
	printf '%s\n' "$WORK/$LOCAL_FILE"
}

# Replace the local script with one carrying none of the units, and put the
# original back afterwards.
local_without_units() {
	cp "$WORK/$LOCAL_FILE" "$WORK/local-backup.sh"
	printf '#!/usr/bin/env bash\nset -euo pipefail\necho "no units at all"\n' \
		>"$WORK/$LOCAL_FILE"
}

restore_local() {
	cp "$WORK/local-backup.sh" "$WORK/$LOCAL_FILE"
}

# --- running the check ------------------------------------------------------
#
# run_with_remote <file> runs the check against the given file as the
# sibling's copy. run_with_curl_fail runs it with the network gone.
run_with_remote() { # $1 = remote file path
	cp "$1" "$WORK/remote"
	set +e
	CURL_STUB_FILE="$WORK/remote" PATH="$WORK/bin:$PATH" \
		bash "$SCRIPT" "$WORK" >"$WORK/out" 2>"$WORK/err"
	echo $? >"$WORK/exit"
	set -e
	read_run
}

run_with_curl_fail() {
	set +e
	CURL_STUB_FAIL=1 PATH="$WORK/bin:$PATH" \
		bash "$SCRIPT" "$WORK" >"$WORK/out" 2>"$WORK/err"
	echo $? >"$WORK/exit"
	set -e
	read_run
}

# Read back the most recent run. The four variables are read by the test
# files that source this fixture, not by the fixture; the linter cannot see
# across the source.
# shellcheck disable=SC2034
read_run() {
	exit_code=$(cat "$WORK/exit" 2>/dev/null || echo 999)
	out_body=$(cat "$WORK/out" 2>/dev/null || true)
	err_body=$(cat "$WORK/err" 2>/dev/null || true)
	combined="$out_body$err_body"
}

# A copy of the local script with one edit applied, used as the sibling's
# copy. The edit is a sed expression: the drift is produced by the script
# itself, so a case cannot differ from the code in more ways than the one
# under test.
remote_with() { # $1 = sed expression
	sed "$1" "$WORK/$LOCAL_FILE" >"$WORK/remote-edited.sh"
	printf '%s\n' "$WORK/remote-edited.sh"
}

# A copy of the local script with one piece of text replaced, used as the
# sibling's copy. The text is given literally, so a line holding quotes and
# brackets does not have to be escaped for sed. The replacement must match
# exactly once: a case that edits more than the line under test is not a case
# about that line.
remote_replacing() { # $1 = old text $2 = new text
	OLD="$1" NEW="$2" python3 - "$WORK/$LOCAL_FILE" >"$WORK/remote-edited.sh" <<'PY'
import os, sys

old = os.environ["OLD"]
new = os.environ["NEW"]
text = open(sys.argv[1]).read()
if text.count(old) != 1:
    sys.exit(f"the replacement matched {text.count(old)} times, expected 1")
sys.stdout.write(text.replace(old, new))
PY
	printf '%s\n' "$WORK/remote-edited.sh"
}

# A copy of the local script with a comment inserted before the line matching
# the given pattern, used as the sibling's copy.
remote_with_comment() { # $1 = awk pattern
	awk -v pat="$1" '{print} $0 ~ pat {print "\t# a remote-only comment"}' \
		"$WORK/$LOCAL_FILE" >"$WORK/remote-commented.sh"
	printf '%s\n' "$WORK/remote-commented.sh"
}

# The local script, unchanged, used as the sibling's copy.
remote_asis() { printf '%s\n' "$WORK/$LOCAL_FILE"; }
