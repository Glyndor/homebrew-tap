#!/usr/bin/env bash
#
# Every formula under Formula/ must be what scripts/release/render-formulae.sh
# emits for the product the roster declares: the same repository, the same tag
# on every url, the same assets, the same shape of digest, and no statement the
# generator does not write.
#
# WHY THIS EXISTS
#
# `brew style` and `brew audit --strict` read a formula as Ruby and as a
# Homebrew recipe. Neither of them knows what the product's release looked
# like, so both accept a formula that is well formed and wrong: a url naming
# another Glyndor repository, a second url carrying a different tag, a
# `post_install` block that runs on every install. The tap's git content IS
# the published artifact, and update.yml commits to `main` with no pull
# request between that commit and `brew install`, so a formula that says the
# wrong thing reaches every user without a second reader.
#
# The roster in scripts/release/render-formulae.sh is the only place a product
# is declared, and it is read here rather than copied. A second list of
# products would be a second thing to keep in step, and a formula no roster
# row declares has no business being in the tap.
#
# The sibling channel refuses the same shapes for the same reason:
# scripts/artifacts/check-manifests.sh in Glyndor/scoop-bucket.
#
# WHAT IT REFUSES
#
#   - a url that is not https://github.com/<repo>/releases/download/<tag>/<asset>,
#     where <repo> is the repository the roster row declares;
#   - a second tag inside the same formula;
#   - an asset the roster row does not declare, in a url or in the install body;
#   - a sha256 that is not 64 lowercase hexadecimal characters;
#   - a statement the generator does not emit: `system`, `exec`, a backtick,
#     `post_install`, `resource`, `patch`, `depends_on`, anything else;
#   - a formula whose name no roster row declares, and a roster with no rows
#     at all (an empty roster must fail, not pass vacuously).
#
# The formula is compared with what the generator writes for the same roster
# row, so a change to the generator shows up here by name the first time it is
# rendered, the way the sibling's allowlist does.
#
# Usage: check-formulae.sh [repo-root]   (default: the repo this lives in)

set -euo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
renderer="$root/scripts/release/render-formulae.sh"

# Fail closed on a missing roster. A check that cannot read the source of
# truth has nothing to compare against, and "nothing to compare against" must
# never read as "nothing is wrong".
if [ ! -r "$renderer" ]; then
	echo "::error::cannot read the PRODUCTS roster at scripts/release/render-formulae.sh; refusing to validate against an unknown roster" >&2
	exit 1
fi
if [ ! -d "$root/Formula" ]; then
	echo "::error::no Formula/ directory under $root; refusing to validate an empty tap" >&2
	exit 1
fi

# The roster block, cut out of the generator. The rows themselves are parsed
# and validated by the python below, so the two do not disagree about where
# the roster starts or what a row looks like.
roster="$(mktemp)"
trap 'rm -f "$roster"' EXIT
awk '/^PRODUCTS=\(/ { inside = 1; print; next }
     inside && /^\)/ { print; exit }
     inside { print }' "$renderer" >"$roster"

# Every formula Homebrew would load, at any depth: a file under Formula/e/ is
# a formula this tap serves whatever the roster says. Symlinks are listed too
# and refused below, because a symlink named like a formula passes a name
# comparison while serving whatever it points at.
formulae=()
while IFS= read -r -d '' found; do
	formulae+=("$found")
done < <(find "$root/Formula" \( -type f -o -type l \) -iname '*.rb' -print0 | LC_ALL=C sort -z)

if [ ${#formulae[@]} -eq 0 ]; then
	echo "::error::no formulae found under Formula/; refusing to validate an empty tap" >&2
	exit 1
fi

# The python prints one tab-separated record per line: "ok<TAB>file" for a
# formula that matches the row, and "file<TAB>message" for a problem.
problems="$(python3 -I "$(dirname "${BASH_SOURCE[0]}")/check-formulae.py" "$roster" "$root" "${formulae[@]}")" || {
	echo "::error::the formula check could not run" >&2
	exit 1
}

status=0
verdict=""
while IFS=$'\t' read -r marker message; do
	[ -n "$message" ] || continue
	if [ "$marker" = "VERDICT" ]; then
		verdict="$message"
		continue
	fi
	if [ "$marker" = "ok" ]; then
		echo "ok  $message"
		continue
	fi
	echo "::error file=$marker::$marker $message" >&2
	status=1
done <<<"$problems"

# The python counts the verdict where the records are made. One that did not
# arrive, or that counts problems nobody printed, is a failure, not a pass.
if [ "$verdict" != "0" ]; then
	[ "$status" -ne 0 ] || echo "::error::the formula check reported '${verdict:-no}' problem(s) that were not printed" >&2
	status=1
fi

if [ "$status" -ne 0 ]; then
	echo "The formulae do not match what scripts/release/render-formulae.sh emits." >&2
	exit 1
fi
exit 0
