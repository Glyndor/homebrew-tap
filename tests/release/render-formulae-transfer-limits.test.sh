#!/usr/bin/env bash
# Bound SHA256SUMS and its signature during transfer, before verification or
# publication. Removing --max-filesize must fail even with the disk caps intact.
set -euo pipefail

HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../fixtures/release" && pwd)"
# shellcheck disable=SC1091
. "$HERE_FIXTURE/render-fixture.sh"
pass=0
fail=0
unset CURL_STUB_IGNORE_MAXFILESIZE CURL_STUB_FAIL

# Observe the effective argv, including the deadline and protocol restrictions,
# rather than accepting flag names in comments. Keep the fixture's curl behavior.
export CURL_ARGS_LOG="$WORK/curl.args"
mv "$BIN/curl" "$BIN/curl-fixture"
cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
python3 - "$CURL_ARGS_LOG" "$@" <<'PY'
import json, sys
with open(sys.argv[1], "a") as log:
    log.write(json.dumps(sys.argv[2:]) + "\n")
PY
exec "$(dirname "$0")/curl-fixture" "$@"
SH
chmod +x "$BIN/curl"

# An exactly 4096-byte, genuinely signed manifest and its 64-byte signature
# must render. Blank lines pad the valid manifest without changing its entries.
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
python3 - "$RELEASES/Glyndor__podup/SHA256SUMS" "$WORK/padded.sums" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
open(sys.argv[2], "wb").write(data + b"\n" * (4096 - len(data)))
PY
resign "$WORK/padded.sums" Glyndor/podup
check "control: the signed manifest is exactly at the cap" "4096" \
	"$(stat -c%s "$RELEASES/Glyndor__podup/SHA256SUMS")"
check "control: the signature is exactly at the cap" "64" \
	"$(stat -c%s "$RELEASES/Glyndor__podup/SHA256SUMS.sig")"
new_root "$WORK/valid"
generator_with "$WORK/valid/scripts/release/render-formulae.sh" "$PODUP"
rc=0; run "$WORK/valid/scripts/release/render-formulae.sh" "$WORK/valid" || rc=$?
check "control: both files at their caps are accepted" "0" "$rc"
check "control: a verified formula is written" "1" \
	"$([ -f "$WORK/valid/Formula/podup.rb" ] && echo 1 || echo 0)"

bounded=0
python3 - "$CURL_ARGS_LOG" <<'PY' || bounded=$?
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
for asset in ("SHA256SUMS", "SHA256SUMS.sig"):
    matches = [args for args in calls if args[-1].endswith("/" + asset)]
    assert len(matches) == 1, f"{asset}: expected one HTTPS transfer"
    args = matches[0]
    for flag in ("--proto", "--proto-redir"):
        assert args[args.index(flag) + 1] == "=https", f"{asset}: {flag}"
    seconds = float(args[args.index("--max-time") + 1])
    assert 0 < seconds <= 120, f"{asset}: missing or excessive deadline"
PY
check "both metadata transfers have a deadline and HTTPS-only protocols" "0" "$bounded"

for spec in 'SHA256SUMS|5000|4096' 'SHA256SUMS.sig|65|64'; do
	IFS='|' read -r asset size limit <<< "$spec"
	publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64
	head -c "$size" /dev/zero > "$RELEASES/Glyndor__podup/$asset"
	for state in empty served; do
		dest="$WORK/$asset-$state"
		new_root "$dest"
		generator_with "$dest/scripts/release/render-formulae.sh" "$PODUP"
		if [ "$state" = served ]; then
			cp "$WORK/valid/Formula/podup.rb" "$dest/Formula/podup.rb"
		fi
		rc=0; run "$dest/scripts/release/render-formulae.sh" "$dest" || rc=$?
		check "$asset ($state): an oversized transfer is refused" "3" "$rc"
		contains "$asset ($state): curl refuses before copying the body" "$WORK/out" \
			"curl stub: maximum file size exceeded for https://github.com/Glyndor/podup/releases/download/v9.9.9/$asset"
		contains "$asset ($state): the error names the file and byte limit" "$WORK/out" \
			"failed to download $asset within the ${limit}-byte cap"
		check "$asset ($state): no signature is accepted" "0" \
			"$(grep -cF 'SHA256SUMS signature verified' "$WORK/out")"
		if [ "$state" = served ]; then
			unchanged=0
			cmp -s "$WORK/valid/Formula/podup.rb" "$dest/Formula/podup.rb" || unchanged=$?
			check "$asset: the served formula keeps every byte" "0" "$unchanged"
		else
			check "$asset: no formula is written" "0" "$(find "$dest/Formula" -name '*.rb' | wc -l)"
		fi
	done
done

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
