#!/usr/bin/env bash
#
# scripts/monitoring/check-published-formulae.sh reads every formula of the tap against the bytes behind its urls.
# It runs daily and after each push of the updater app, where nobody watches, so each way it could say "verified"
# on a formula that does not match is shown here to say no: a digest that is not the one of the asset, a download
# that fails or leaves no file, an asset over the cap, a url that is not a plain asset of a Glyndor release, a digest
# that is missing or in capitals, a formula that names nothing, and a tap with nothing to read.
#
# The script is run as it ships, with curl replaced by a stub that serves files of a folder. No network.
# Requires: bash, sha256sum.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$HERE/scripts/monitoring/check-published-formulae.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

ASSETS="$WORK/assets"; R="$WORK/tap"; mkdir -p "$ASSETS" "$WORK/bin"
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""; url=""; prev=""
for arg in "$@"; do [ "$prev" = "-o" ] && out="$arg"; prev="$arg"; url="$arg"; done
n=$(( $(cat "$ASSETS/.calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$ASSETS/.calls"; echo "$*" > "$ASSETS/.args"
[ "${STUB_FAIL_UNTIL:-0}" -lt "$n" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
[ -z "${STUB_ALWAYS_FAIL:-}" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
[ -z "${STUB_NO_FILE:-}" ] || exit 0
cp "$ASSETS/$(basename "$url")" "$out"
STUB
chmod +x "$WORK/bin/curl"

printf 'binary one\n' > "$ASSETS/probe-linux-x86_64"; printf 'binary two\n' > "$ASSETS/probe-linux-arm64"
sum() { sha256sum "$ASSETS/$1" | cut -d' ' -f1; }
URL="https://github.com/Glyndor/probe/releases/download/v1.0.0"
formula() { # <name> <url line> <digest line>...  a formula of the shape the updater writes
	local name="$1"; shift
	mkdir -p "$R/Formula"; printf 'class X < Formula\n' > "$R/Formula/$name.rb"
	while [ $# -gt 0 ]; do printf '  %s\n  %s\n' "$1" "$2" >> "$R/Formula/$name.rb"; shift 2; done
	printf 'end\n' >> "$R/Formula/$name.rb"
}
fresh() { rm -rf "$R" "$ASSETS/.calls"; mkdir -p "$R"; }
run() { ASSETS="$ASSETS" RETRY_DELAY_SECONDS=0 PATH="$WORK/bin:$PATH" bash "$SCRIPT" "$R" >"$WORK/out" 2>&1; echo $?; }
said() { grep -c -- "$1" "$WORK/out"; }
calls() { cat "$ASSETS/.calls" 2>/dev/null || echo 0; }

fresh; formula probe "url \"$URL/probe-linux-x86_64\"" "sha256 \"$(sum probe-linux-x86_64)\"" "url \"$URL/probe-linux-arm64\"" "sha256 \"$(sum probe-linux-arm64)\""
check "a formula whose digests are those of its assets passes" "0" "$(run)"
check "the transfer is HTTPS only, with redirects too, and bounded in time and size" "1" "$(grep -c -- '--proto =https --proto-redir =https .*--max-time 120 --max-filesize 104857600' "$ASSETS/.args")"
check "and says how many it verified" "1" "$(said 'verified 2 published asset(s) across 1 formula')"

fresh; formula probe "url \"$URL/probe-linux-x86_64\"" "sha256 \"$(sum probe-linux-x86_64)\"" "url \"$URL/probe-linux-arm64\"" "sha256 \"$(printf '%064d' 7)\""
check "a digest that is not the one of the asset fails" "1" "$(run)"
check "and names both digests" "1" "$(said 'declares digest 0000000000000000000000000000000000000000000000000000000000000007 but the downloaded asset has digest')"
check "and the one that matched is still counted" "1" "$(said 'verified 1 of 2 published asset(s); 1 failure')"

fresh; formula probe "url \"$URL/probe-linux-x86_64\"" "sha256 \"$(sum probe-linux-x86_64)\""; formula zzz "url \"$URL/probe-linux-arm64\"" "sha256 \"$(printf '%064d' 7)\""
check "a bad formula does not hide a good one next to it, nor the other way" "1" "$(run)"
check "and the count is of the two" "1" "$(said 'verified 1 of 2')"

fresh; formula probe "url \"$URL/probe-linux-x86_64\"" "sha256 \"$(sum probe-linux-x86_64)\""
export STUB_FAIL_UNTIL=2; check "a download that fails twice and then works passes: three attempts" "0" "$(run)"; unset STUB_FAIL_UNTIL
check "and made three" "3" "$(calls)"
fresh; formula probe "url \"$URL/probe-linux-x86_64\"" "sha256 \"$(sum probe-linux-x86_64)\""
export STUB_ALWAYS_FAIL=1; check "a download that always fails fails after three attempts" "1" "$(run)"; unset STUB_ALWAYS_FAIL
check "and made three" "3" "$(calls)"
check "and says what curl said" "1" "$(said 'curl: (22)')"
fresh; formula probe "url \"$URL/probe-linux-x86_64\"" "sha256 \"$(sum probe-linux-x86_64)\""
export STUB_NO_FILE=1; check "a download that reports success and leaves no file fails" "1" "$(run)"; unset STUB_NO_FILE
check "and says so" "1" "$(said 'reported success without a file')"

fresh; truncate -s 104857601 "$ASSETS/big"; formula probe "url \"$URL/big\"" "sha256 \"$(sum big)\""
check "an asset over the cap fails even when its digest is right" "1" "$(run)"
check "and says so" "1" "$(said 'over the 104857600-byte cap')"
rm -f "$ASSETS/big"

fresh; formula probe "url \"http://github.com/Glyndor/probe/releases/download/v1.0.0/probe-linux-x86_64\"" "sha256 \"$(sum probe-linux-x86_64)\""
check "a url that is not HTTPS fails" "1" "$(run)"
fresh; formula probe "url \"https://example.invalid/Glyndor/probe/releases/download/v1.0.0/probe-linux-x86_64\"" "sha256 \"$(sum probe-linux-x86_64)\""
check "a url of another host fails" "1" "$(run)"
fresh; formula probe "url \"https://github.com/Someone/probe/releases/download/v1.0.0/probe-linux-x86_64\"" "sha256 \"$(sum probe-linux-x86_64)\""
check "a url of a repository that is not Glyndor's fails" "1" "$(run)"
check "and says it is not a plain asset" "1" "$(said 'is not a plain asset of a release of a Glyndor repository')"
fresh; formula probe "url \"$URL/../probe-linux-x86_64\"" "sha256 \"$(sum probe-linux-x86_64)\""
check "a url that climbs out of the release fails" "1" "$(run)"
fresh; formula probe "url \"$URL/probe-linux-x86_64?x=1\"" "sha256 \"$(sum probe-linux-x86_64)\""
check "a url with a query fails" "1" "$(run)"

fresh; formula probe "url \"$URL/probe-linux-x86_64\"" "sha256 \"$(sum probe-linux-x86_64 | tr a-f A-F)\""
check "a digest in capitals fails" "1" "$(run)"
check "and says it is not a lowercase SHA-256" "1" "$(said 'no lowercase SHA-256')"
fresh; formula probe "url \"$URL/probe-linux-x86_64\"" "version \"1.0.0\""
check "a url not followed by a digest fails" "1" "$(run)"
fresh; mkdir -p "$R/Formula"; printf 'class X < Formula\n  url "%s/probe-linux-x86_64"\nend\n' "$URL" > "$R/Formula/probe.rb"
check "a url that ends the file with no digest after it fails" "1" "$(run)"

fresh; mkdir -p "$R/Formula"; printf 'class X < Formula\nend\n' > "$R/Formula/probe.rb"
check "a formula that names no asset fails" "1" "$(run)"
check "and says so" "1" "$(said 'names no asset to read')"
fresh; mkdir -p "$R/Formula"
check "a tap with no formula fails" "1" "$(run)"
check "and says so" "1" "$(said 'no formulae found')"
fresh
check "a folder with no Formula folder fails" "1" "$(run)"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
