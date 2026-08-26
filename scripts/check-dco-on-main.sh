#!/usr/bin/env bash
#
# Report any commit on `main` that a person authored without a `Signed-off-by:`
# trailer.
#
# Detection, not prevention: by the time this runs the commit is already on the
# branch `brew install` reads. See .github/workflows/dco-on-main.yml for why
# this repository cannot have a gate here and what prevention would take.
#
# Commits authored by github-actions[bot] are exempt. DCO is a person's
# attestation about their right to submit code; a bot regenerating a formula
# from an already-verified release is not contributing in that sense, and
# emitting a trailer on its behalf would manufacture an attestation nobody made.
#
# Usage: check-dco-on-main.sh <before-sha> <after-sha>
#
# A zero <before-sha> (a branch's first push, or a force push GitHub reports
# that way) means there is no range to walk, so the tip alone is checked rather
# than the repository's whole history.

set -euo pipefail

BEFORE="${1:?usage: check-dco-on-main.sh <before-sha> <after-sha>}"
AFTER="${2:?usage: check-dco-on-main.sh <before-sha> <after-sha>}"

BOT_AUTHOR="github-actions[bot]"

case "$BEFORE" in
	0000000000000000000000000000000000000000|"") range="$AFTER -1" ;;
	*) range="$BEFORE..$AFTER" ;;
esac

# shellcheck disable=SC2086 # `range` is either "A..B" or "SHA -1", both intended
commits="$(git rev-list --no-merges $range 2>/dev/null || true)"
[ -n "$commits" ] || { echo "no commits in range; nothing to check"; exit 0; }

missing=""
checked=0
for c in $commits; do
	author="$(git log -1 --format='%an' "$c")"
	if [ "$author" = "$BOT_AUTHOR" ]; then
		echo "skip $(git log -1 --format='%h' "$c")  authored by $BOT_AUTHOR"
		continue
	fi
	checked=$((checked + 1))
	if git log -1 --format='%B' "$c" | grep -q '^Signed-off-by: '; then
		echo "ok   $(git log -1 --format='%h %s' "$c")"
	else
		missing="$missing $c"
	fi
done

if [ -n "$missing" ]; then
	echo "::error::a human commit reached main without a Signed-off-by trailer" >&2
	for c in $missing; do
		echo "  $(git log -1 --format='%h  %an  %s' "$c")" >&2
	done
	echo "This is detection, not prevention -- the commit is already on main." >&2
	echo "Add the trailer to any follow-up work; the history stays as it is." >&2
	exit 1
fi

echo "$checked human commit(s) checked, all signed off"
