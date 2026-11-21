#!/usr/bin/env bash
#
# Record, check, or put in place the files under Formula/ by their SHA-256.
#
# WHY THIS EXISTS
#
# .github/workflows/update.yml renders the formulae in one job, runs
# `brew style` and `brew audit --strict` on them in a second, and commits them
# in a third, which is the only job that ever holds the updater app's private
# key. Homebrew's style and audit commands install Ruby gems from RubyGems when
# the ones they need are missing, which is code nobody here chose, so they run
# where no secret is.
#
# Splitting the jobs only helps if the commit job can tell that the bytes it
# commits are the bytes the render job produced, and not a version something
# rewrote on the way. This script is how it tells. The render job records the
# manifest and hands it on through its job outputs, which no later job can
# change; the commit job compares the files it is about to commit with that
# manifest and refuses any difference. A manifest carried inside the artifact
# would not do: the validation job downloads the artifact and holds the token
# that can upload one, so a copy in there is a copy it could replace.
#
# THE MANIFEST
#
#   One line per regular file under Formula/, at any depth, in bytewise order:
#   the 64 lowercase hex characters of its SHA-256, two spaces, and its path
#   from the root (`Formula/podup.rb`). That is the format `sha256sum` prints,
#   so `sha256sum -c` reads the copy the artifact carries.
#
# WHAT IT REFUSES, with exit 1 and a message naming the cause
#
#   - a root with no Formula/, a Formula/ that is a symlink or not a directory;
#   - an entry under Formula/ that is neither a regular file nor a directory
#     (a symlink, a FIFO), because its bytes are not what the manifest records;
#   - a path with a character outside [A-Za-z0-9._+@/-]: a newline would split
#     a record in two, and `sha256sum` escapes a backslash in the name;
#   - a Formula/ with no file in it, because a manifest of nothing matches any
#     empty tree and an empty tap must never be committed;
#   - for `check` and `place`, an expected manifest that is missing or empty,
#     and any difference between it and the tree: a changed byte, a file
#     added, a file missing.
#
# Usage:
#   formulae-digests.sh list  <root>                    print the manifest of <root>/Formula
#   formulae-digests.sh check <root> <manifest>         exit 0 only when <root>/Formula is exactly <manifest>
#   formulae-digests.sh place <from> <root> <manifest>  check <from>, replace <root>/Formula with its copy,
#                                                       and check <root> again

set -euo pipefail

# `sort` orders under the environment's collation, and the manifest has to be
# the same text on every runner that writes or reads it.
export LC_ALL=C

die() {
	echo "::error::$*" >&2
	exit 1
}

list_manifest() { # $1=root
	local root="$1" odd f sum count=0
	[ ! -L "$root/Formula" ] || die "$root/Formula is a symlink; the manifest covers files the tap holds itself"
	[ -d "$root/Formula" ] || die "$root/Formula is missing or is not a directory"
	odd="$(cd "$root" && find Formula ! -type f ! -type d -print -quit)"
	[ -z "$odd" ] || die "$root/$odd is neither a regular file nor a directory"
	while IFS= read -r -d '' f; do
		case "$f" in
		*[!A-Za-z0-9._+@/-]*) die "refusing a path with a character outside [A-Za-z0-9._+@/-]: $(printf '%q' "$f")" ;;
		esac
		sum="$(sha256sum < "$root/$f")" || die "cannot read $root/$f"
		printf '%s  %s\n' "${sum%% *}" "$f"
		count=$((count + 1))
	done < <(cd "$root" && find Formula -type f -print0 | sort -z)
	[ "$count" -gt 0 ] || die "$root/Formula holds no file; refusing to record an empty tap"
}

check_manifest() { # $1=root $2=expected manifest
	local root="$1" expected="$2" actual want
	[ -s "$expected" ] || die "the expected manifest $expected is missing or empty"
	want="$(cat "$expected")"
	actual="$(list_manifest "$root")"
	if [ "$actual" != "$want" ]; then
		echo "::error::the files under $root/Formula are not the ones the render job recorded" >&2
		diff <(printf '%s\n' "$want") <(printf '%s\n' "$actual") | sed 's/^/    /' >&2 || true
		exit 1
	fi
	echo "$(printf '%s\n' "$actual" | wc -l | tr -d ' ') file(s) under $root/Formula match the recorded digests"
}

place_manifest() { # $1=from $2=root $3=expected manifest
	local from="$1" root="$2" expected="$3"
	# The source is checked before anything in the root is touched, so a
	# refused artifact leaves the checkout as it was.
	check_manifest "$from" "$expected"
	rm -rf "$root/Formula"
	cp -R "$from/Formula" "$root/Formula"
	# And the copy is checked too: what counts is the tree the next step reads.
	check_manifest "$root" "$expected"
}

case "${1:-}" in
list)
	[ "$#" -eq 2 ] || die "usage: formulae-digests.sh list <root>"
	list_manifest "$2"
	;;
check)
	[ "$#" -eq 3 ] || die "usage: formulae-digests.sh check <root> <manifest>"
	check_manifest "$2" "$3"
	;;
place)
	[ "$#" -eq 4 ] || die "usage: formulae-digests.sh place <from> <root> <manifest>"
	place_manifest "$2" "$3" "$4"
	;;
*)
	die "usage: formulae-digests.sh list|check|place ..."
	;;
esac
