#!/usr/bin/env bash
# Behaviour tests for scripts/monitoring/check-channel-drift.sh.
#
# The script is the only thing between two deliberately duplicated sets of
# files and a silent divergence. Its failure mode is passing: a checker that
# fetches nothing, or compares a file against itself, prints the same green
# line as one that did the work. So most cases plant a condition and require
# red; the green cases only mean something because the red ones prove the
# script can tell.
#
# The only dependency on the outside world is curl. A fake curl on PATH serves
# prepared files out of a directory, so the real shell runs against a
# deterministic GitHub and no case touches the network.
#
# Requires: bash, diff, sed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$HERE/scripts/monitoring/check-channel-drift.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

# The fake curl: STUB_DIR/<path under the sibling's main> is the body served;
# a file named <path>.status holds an exit code to simulate (22 = HTTP error
# with the code in <path>.http, anything else = a transport failure).
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'CURL'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-w|--connect-timeout|--max-time) shift 2 ;;
		-*) shift ;;
		*) url="$1"; shift ;;
	esac
done
path="${url#*/main/}"
if [ -f "$STUB_DIR/$path.status" ]; then
	code="$(cat "$STUB_DIR/$path.status")"
	[ "$code" = 22 ] && printf '%s' "$(cat "$STUB_DIR/$path.http")"
	echo "curl: simulated failure $code" >&2
	exit "$code"
fi
if [ ! -f "$STUB_DIR/$path" ]; then
	printf '404'; echo "curl: (22) 404" >&2; exit 22
fi
cp "$STUB_DIR/$path" "$out"
printf '200'
CURL
chmod +x "$WORK/bin/curl"

# scenario <name> <path>...: a repository root and a sibling stub that start
# identical, and a list naming the given paths.
scenario() {
	local name="$1"; shift
	ROOT="$WORK/$name/root"; STUB="$WORK/$name/stub"; LIST="$WORK/$name/list.txt"
	rm -rf "${WORK:?}/$name"; mkdir -p "$ROOT" "$STUB"
	: > "$LIST"
	local p
	for p in "$@"; do
		mkdir -p "$ROOT/$(dirname "$p")" "$STUB/$(dirname "$p")"
		printf 'line one\nline two\nline three\n' > "$ROOT/$p"
		cp "$ROOT/$p" "$STUB/$p"
		echo "$p" >> "$LIST"
	done
}
run() { PATH="$WORK/bin:$PATH" STUB_DIR="$STUB" "$SCRIPT" "$ROOT" "$LIST" > "$WORK/out" 2>&1; }
rc_of() { local rc=0; run || rc=$?; echo "$rc"; }
said() { grep -qF -- "$1" "$WORK/out" && echo 1 || echo 0; }

scenario ok scripts/a.sh tests/b.test.sh
check "control: identical copies pass" "0" "$(rc_of)"
check "and the success line counts the files compared" "1" "$(said 'compared 2 shared file(s)')"

scenario drift scripts/a.sh tests/b.test.sh
printf 'line one\nCHANGED\nline three\n' > "$STUB/scripts/a.sh"
check "a changed line is drift" "1" "$(rc_of)"
check "and the message names the path" "1" "$(said 'scripts/a.sh differs from Glyndor/')"
check "and the first differing line" "1" "$(said 'first difference at line 2')"
check "and both texts" "1" "$(said 'CHANGED')"
check "and says one file of two drifted" "1" "$(said '1 of 2 compared')"

scenario longer scripts/a.sh
printf 'line one\nline two\nline three\nline four\n' > "$STUB/scripts/a.sh"
check "a sibling that gained a line at the end is drift" "1" "$(rc_of)"
check "and the end of file is named on this side" "1" "$(said 'this repository: <end of file>')"

scenario ws scripts/a.sh
printf 'line one  \r\nline two\t\r\nline three\r\n' > "$STUB/scripts/a.sh"
check "trailing whitespace and CRLF alone are not drift" "0" "$(rc_of)"

scenario comment scripts/a.sh
printf 'line one\nline two\nline three\n# only a comment\n' > "$STUB/scripts/a.sh"
check "a comment added on one side only IS drift" "1" "$(rc_of)"

scenario gone scripts/a.sh scripts/c.sh
rm "$STUB/scripts/c.sh"
check "a path the sibling does not serve fails" "1" "$(rc_of)"
check "and says so, not drift" "1" "$(said 'does not serve scripts/c.sh')"

scenario net scripts/a.sh scripts/c.sh
echo 6 > "$STUB/scripts/c.sh.status"
check "an unreachable sibling fails" "1" "$(rc_of)"
check "and is called a fetch failure, not drift" "1" "$(said 'This is a fetch failure, not drift')"

scenario empty scripts/a.sh scripts/c.sh
: > "$STUB/scripts/c.sh"
check "an empty body fails" "1" "$(rc_of)"
check "and is called a fetch failure" "1" "$(said 'empty body for scripts/c.sh')"

scenario local scripts/a.sh scripts/c.sh
rm "$ROOT/scripts/c.sh"
check "a listed file missing here fails" "1" "$(rc_of)"
check "and says this repository should carry it" "1" "$(said 'is not present in')"

scenario climb scripts/a.sh
echo "../outside" >> "$LIST"
check "a path that climbs out of the repository is refused" "1" "$(rc_of)"
check "and the message says it is not usable" "1" "$(said 'not a usable repository-relative path')"

scenario none
check "an empty list is refused, not passed" "1" "$(rc_of)"
check "and says there is nothing to compare" "1" "$(said 'names no file')"

scenario all scripts/a.sh scripts/c.sh
echo 6 > "$STUB/scripts/a.sh.status"; echo 6 > "$STUB/scripts/c.sh.status"
check "when every fetch fails nothing is compared and it fails" "1" "$(rc_of)"
check "and it says no shared file was compared, not that the copies agree" "1" "$(said 'no shared file was compared')"

scenario nolist scripts/a.sh
rm "$LIST"
check "a missing path list fails" "1" "$(rc_of)"

check "the real list names files that exist in this repository" "0" \
	"$(missing=0; while IFS= read -r p; do case "$p" in ''|'#'*) continue;; esac; [ -f "$HERE/$p" ] || missing=$((missing + 1)); done < "$HERE/scripts/monitoring/channel-shared-paths.txt"; echo "$missing")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
