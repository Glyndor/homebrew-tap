#!/usr/bin/env bash
#
# scripts/render-formulae.sh's PRODUCTS table is the only place a product is
# declared. Formula/ restates it and cannot be generated from the check itself, so
# this compares the two: a product added to PRODUCTS without re-running the
# generator leaves a directory that is a correct artefact of an obsolete input.
# "Generated" says where a file came from, not when.
#
# The README's table is NOT checked, deliberately, and was until 2026-08-26.
#
# It made editing prose break CI. The comparison parsed a markdown table with
# awk, so renaming the heading or adding a column reported every product as
# missing -- which happened while porting this check between the two
# repositories, where one says "Formula" and the other "Manifest". The check was
# wrong and the README was fine.
#
# And it compared two things a person maintains by hand, which anyone can
# reconcile by editing whichever is easier rather than whichever is right. That
# is not a check against ground truth; it is two documents agreeing.
#
# What is lost: the README can drift from what the tap serves. That is a
# documentation staleness, not a correctness failure -- what gets installed is
# decided by Formula/, and that is still checked.
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

rendered="$(find "$root/Formula" -maxdepth 1 -name '*.rb' -printf '%f\n' \
           | while read -r f; do echo "${f%.rb}"; done | sort -u)"

status=0
if [ "$declared" != "$rendered" ]; then
	echo "::error::Formula/ disagrees with PRODUCTS - re-run scripts/render-formulae.sh" >&2
	diff <(echo "$declared") <(echo "$rendered") | sed 's/^/  /' >&2 || true
	status=1
fi
[ "$status" -eq 0 ] && echo "ok  $(echo "$declared" | tr '\n' ' ')"
exit "$status"
