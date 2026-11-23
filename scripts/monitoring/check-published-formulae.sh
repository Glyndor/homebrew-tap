#!/usr/bin/env bash
#
# Read every formula of the tap as published against the bytes it points to: download each release asset a formula
# names and compare its SHA-256 with the digest the formula declares.
#
# Usage: check-published-formulae.sh [repository root]
#
# `brew install` refuses an asset whose digest is not the one of the formula, so a wrong digest on main is a formula
# that fails for every user and that no pull request saw, because the updater app pushes to main with none. This is
# the check the bucket has under the name of published-bytes.yml. It binds the formula to the bytes behind its urls;
# that those digests are the ones of the signed SHA256SUMS of the release is the renderer's own check, made when it
# renders.
#
# Each formula has to name at least one asset, every asset a plain HTTPS asset of a release of a Glyndor repository,
# every url a lowercase SHA-256 on the line after it: a formula that names nothing is a failure of its own, so a check
# that read nothing cannot end well. Each transfer is bounded to 120 seconds, 100 MiB, and three attempts.
# Exit 0 when every digest matches, 1 otherwise.
set -euo pipefail
shopt -s nullglob

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
MAX_ASSET_BYTES=104857600
DOWNLOAD_ATTEMPTS=3
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-2}"
case "$RETRY_DELAY_SECONDS" in '' | *[!0-9]*) RETRY_DELAY_SECONDS=2 ;; esac

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

formulae=("$root"/Formula/*.rb)
if [ "${#formulae[@]}" -eq 0 ]; then
	echo "::error::no formulae found under $root/Formula" >&2
	exit 1
fi

download_asset() { # <url> <destination> <error file>
	local attempt status=1
	for ((attempt = 1; attempt <= DOWNLOAD_ATTEMPTS; attempt++)); do
		rm -f -- "$2"
		if curl -fsSL --proto =https --proto-redir =https --connect-timeout 10 --max-time 120 --max-filesize "$MAX_ASSET_BYTES" -o "$2" "$1" 2>"$3"; then
			return 0
		else
			status=$?
		fi
		[ "$attempt" -ge "$DOWNLOAD_ATTEMPTS" ] || sleep "$RETRY_DELAY_SECONDS"
	done
	return "$status"
}

assets=0
verified=0
failed=0
for formula in "${formulae[@]}"; do
	# One "url<TAB>digest" line for each url, the digest being the sha256 on the next line; an empty digest when
	# the line after a url is not a sha256.
	pairs="$(awk '
		/^[[:space:]]*url "/ { if (pending) print url "\t"; url = $0; sub(/^[^"]*"/, "", url); sub(/".*$/, "", url); pending = 1; next }
		pending { digest = ""; if ($0 ~ /^[[:space:]]*sha256 "/) { digest = $0; sub(/^[^"]*"/, "", digest); sub(/".*$/, "", digest) } print url "\t" digest; pending = 0 }
		END { if (pending) print url "\t" }
	' "$formula")"
	if [ -z "$pairs" ]; then
		echo "::error file=$formula::the formula names no asset to read" >&2
		failed=$((failed + 1))
		continue
	fi
	while IFS=$'\t' read -r url expected; do
		assets=$((assets + 1))
		if [[ ! "$url" =~ ^https://github\.com/Glyndor/[A-Za-z0-9_.-]+/releases/download/v[0-9A-Za-z.+-]+/[A-Za-z0-9_.-]+$ ]]; then
			echo "::error file=$formula::$url is not a plain asset of a release of a Glyndor repository" >&2
			failed=$((failed + 1))
			continue
		fi
		if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
			echo "::error file=$formula::$url has no lowercase SHA-256 on the line after it" >&2
			failed=$((failed + 1))
			continue
		fi
		destination="$tmp/asset-$assets"
		if ! download_asset "$url" "$destination" "$tmp/curl.err"; then
			echo "::error file=$formula::$url could not be downloaded after $DOWNLOAD_ATTEMPTS attempts" >&2
			[ ! -s "$tmp/curl.err" ] || sed 's/^/  curl: /' "$tmp/curl.err" >&2
			failed=$((failed + 1))
			continue
		fi
		if [ ! -f "$destination" ]; then
			echo "::error file=$formula::the download of $url reported success without a file" >&2
			failed=$((failed + 1))
			continue
		fi
		if [ "$(stat -c%s "$destination")" -gt "$MAX_ASSET_BYTES" ]; then
			echo "::error file=$formula::$url is over the $MAX_ASSET_BYTES-byte cap" >&2
			failed=$((failed + 1))
			continue
		fi
		actual="$(sha256sum "$destination")"
		actual="${actual%% *}"
		if [ "$actual" != "$expected" ]; then
			echo "::error file=$formula::$url declares digest $expected but the downloaded asset has digest $actual" >&2
			failed=$((failed + 1))
			continue
		fi
		verified=$((verified + 1))
	done <<<"$pairs"
done

if [ "$failed" -ne 0 ]; then
	echo "verified $verified of $assets published asset(s); $failed failure(s)." >&2
	exit 1
fi
echo "verified $verified published asset(s) across ${#formulae[@]} formula(e)."
