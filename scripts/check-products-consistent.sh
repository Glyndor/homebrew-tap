#!/usr/bin/env bash
#
# scripts/render-formulae.sh's PRODUCTS table is the only place a product is
# declared. Two things restate it and cannot be generated from it: the README's
# "Available formulae" table, and the set of files under Formula/. With one
# product the drift is invisible; with the full roster it is certain.
#
# This lived inline in .github/workflows/ci.yml, where nothing could test it.
# A check that decides whether a tap agrees with itself, and that has never
# been watched fail, is decoration -- so it moved here and got a test.
#
# Usage: check-products-consistent.sh [repo-root]   (default: the repo this
# lives in)

set -euo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Every comparison below is between sorted lists, and `sort` compares under the
# environment's collation. UTF-8 collations ignore punctuation at the primary
# level, so `pod-up` and `podup` -- both legal formula names -- compare EQUAL
# and `sort -u` drops one. Two lists that genuinely differ then compare the
# same and this exits 0 over real drift. Pin the collation rather than inherit
# whatever the runner happens to have.
export LC_ALL=C

declared="$(awk '/^PRODUCTS=\(/ { inside = 1; next }
                 inside && /^\)/  { exit }
                 inside           { print }' "$root/scripts/render-formulae.sh" \
           | sed -n 's/^[^"]*"[^|]*|\([^|]*\)|.*/\1/p' | sort -u)"
[ -n "$declared" ] || {
	echo "::error::could not read PRODUCTS out of scripts/render-formulae.sh" >&2
	exit 1
}

# Backticks and "$" never appear inside the single quotes below. They would be
# awk's and Markdown's, but SC2016 reads them as shell expansions.
documented="$(awk '/^\| Formula \| Product \|/ { inside = 1; next }
                   inside && /^\|---/ { next }
                   inside && /^\|/    { print; next }
                   inside              { exit }' "$root/README.md" \
             | cut -d'|' -f2 | tr -cd '[:alnum:]._\n-' | awk 'NF' | sort -u)"

# An empty list here means the table header was not found, not that the table
# is empty -- renaming that heading turns this into a diff of every product
# against nothing, which reads as total drift and sends the reader looking for
# something that is not wrong. I walked into exactly that porting this check to
# the scoop bucket, where the header is spelled differently.
[ -n "$documented" ] || {
	echo "::error file=README.md::could not find the Available formulae table in README.md" >&2
	exit 1
}

rendered="$(find "$root/Formula" -maxdepth 1 -name '*.rb' -printf '%f\n' \
           | while read -r f; do echo "${f%.rb}"; done | sort -u)"

status=0
if [ "$declared" != "$documented" ]; then
	echo "::error file=README.md::the README's Available formulae table disagrees with PRODUCTS" >&2
	diff <(echo "$declared") <(echo "$documented") | sed 's/^/  /' >&2 || true
	status=1
fi
if [ "$declared" != "$rendered" ]; then
	echo "::error::Formula/ disagrees with PRODUCTS - re-run scripts/render-formulae.sh" >&2
	diff <(echo "$declared") <(echo "$rendered") | sed 's/^/  /' >&2 || true
	status=1
fi
[ "$status" -eq 0 ] && echo "ok  $(echo "$declared" | tr '\n' ' ')"
exit "$status"
