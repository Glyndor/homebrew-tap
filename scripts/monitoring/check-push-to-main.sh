#!/usr/bin/env bash
#
# Fail when a push to main brought a commit that nobody judged.
#
# What reaches main is a pull request that was judged on the tree that lands, or the push of
# the app that regenerates the formulae, which bypasses the ruleset and writes only the
# formulae. Anything else is judged by nobody, and this is what notices it. For every commit of
# `before..after`, in order, all of it read from GitHub, and everything else is a failure:
#
#   R1  The commit has exactly one parent, and it is the commit before it in the range (for the
#       first, `before`). A merge, a range that is not a line, a force-push and a `before` of
#       zeros fail.
#   R2  It is "of a pull request" only when GitHub gives exactly one pull request, merged, whose
#       merge commit is this commit, into main, from a branch of this repository, the committer
#       is `web-flow` with a signature GitHub verified, and the one who merged it is somebody
#       named and is not an actor that bypasses the ruleset. Anything else is a direct push.
#   R3  A commit of a pull request is accepted when its tree is the tree of that pull request's
#       head (the branch was up to date, which the ruleset requires) and every check the
#       ruleset requires ended in success on that head, from GitHub Actions (integration
#       15368), counting every attempt.
#   R4  A direct push is accepted only when whoever pushed is exactly the updater app, the
#       author of the commit is that app, the committer is `web-flow` with a verified signature
#       (the way GitHub signs what the app commits through the API), and every file of the
#       commit, both ends of a rename, is under a generated path. When every commit of the push
#       is direct, the files of the whole comparison are held to the same paths. Any other
#       direct push is "a direct push of an actor that is not authorised".
#   R5  A call that fails, an answer that does not parse, a list that is not whole and a field
#       that is absent or empty are failures. This is a detective control and a failure opens
#       an issue, so in doubt it fails.
#
# The workflow runs this script from the commit `before`, the one main had, and not from the tree
# that was pushed, so a push cannot change its own judge.
#
# Inputs (env): GH_TOKEN, REPO, BEFORE, AFTER, PUSHER (who pushed). Arguments: the file of
# generated paths, the file of the updater and the actors that bypass, the copy of the ruleset
# (default: the copies beside this script).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
paths_file="${1:-$here/generated-paths.txt}"
actors_file="${2:-$here/bypass-actors.txt}"
ruleset_file="${3:-$here/main-ruleset.expected.json}"
repo="${REPO:-}"
before="${BEFORE:-}"
after="${AFTER:-}"
pusher="${PUSHER:-}"
zeros=0000000000000000000000000000000000000000

fail() { echo "::error::$1"; exit 1; }
hex40() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

[ -n "$repo" ] || fail "no repository named, so the push cannot be read"
if ! { hex40 "$before" && hex40 "$after"; }; then fail "the push does not name two commits, so it cannot be read"; fi
[ "$before" != "$zeros" ] || fail "the push has no commit before it (a new branch), so it cannot be read"
[ -n "$pusher" ] || fail "nobody is named as the pusher, so the push cannot be classified"
[ -r "$paths_file" ] || fail "$paths_file cannot be read, so what the app writes is not known"
[ -r "$actors_file" ] || fail "$actors_file cannot be read, so who bypasses the ruleset is not known"
mapfile -t allowed < <(grep -v '^[[:space:]]*\(#\|$\)' "$paths_file")
mapfile -t actors < <(grep -v '^[[:space:]]*\(#\|$\)' "$actors_file")
mapfile -t required < <(jq -r '.checks[]?' "$ruleset_file" 2>/dev/null)
[ "${#allowed[@]}" -gt 0 ] || fail "$paths_file lists nothing, so no direct push is acceptable"
[ "${#actors[@]}" -gt 0 ] || fail "$actors_file lists nothing, so the updater app is not known"
[ "${#required[@]}" -gt 0 ] || fail "$ruleset_file lists no required check, so what a pull request had to pass is not known"

# The one login of the list that is the updater app and the actors that bypass: the exact
# match of a login that is not empty, and nothing else.
updater="${actors[0]}"
is_updater() { [ -n "$1" ] && [ "$1" = "$updater" ]; }
bypasses() { local a; for a in "${actors[@]}"; do [ "$a" = "$1" ] && return 0; done; return 1; }
under_generated() { local f="$1" p; [ -n "$f" ] || return 1; for p in "${allowed[@]}"; do case "$f" in "$p"*) return 0 ;; esac; done; return 1; }

tree_of() { # <commit> : its tree, or nothing
	local t
	t="$(gh api "repos/${repo}/git/commits/${1}" 2>/dev/null | jq -r '.tree.sha // empty' 2>/dev/null)" || return 0
	hex40 "$t" && printf '%s' "$t"
	return 0
}

# R1 and R5: the commits of the push, every page of them, each projected to the fields the rules read
# before it is kept, and kept in files: a large comparison does not fit in the arguments of a command,
# and a judgment that stops at the limit of one is no judgment. A range larger than the cap is a failure.
max=200
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: >"$tmp/commits.jsonl"
page=1
total=-1
while :; do
	gh api "repos/${repo}/compare/${before}...${after}?per_page=100&page=${page}" >"$tmp/page.json" 2>/dev/null || fail "the commits of the push could not be read"
	total="$(jq -r 'if (.total_commits | type) == "number" and (.commits | type) == "array" and (.files | type) == "array" then .total_commits else empty end' "$tmp/page.json" 2>/dev/null)" || total=""
	[ -n "$total" ] || fail "the comparison of the push cannot be read whole"
	[ "$total" -le "$max" ] || fail "the push has $total commits, more than the $max that can be judged"
	jq -c '.commits[] | {sha, parents: [.parents[]?.sha], author: (.author.login // ""), committer: (.committer.login // ""), verified: (.commit.verification.verified == true)}' "$tmp/page.json" >>"$tmp/commits.jsonl" 2>/dev/null || fail "the commits of the push cannot be read"
	# Every page carries the same list of files of the whole comparison; the first is the one read.
	[ "$page" != 1 ] || jq -c '[.files[] | .filename, (.previous_filename // empty)]' "$tmp/page.json" >"$tmp/files.json" 2>/dev/null || fail "the files of the push cannot be read"
	[ "$(grep -c . "$tmp/commits.jsonl")" -ge "$total" ] && break
	[ "$(jq '.commits | length' "$tmp/page.json")" -gt 0 ] || fail "a page of the commits of the push is empty before the count the comparison gives is reached"
	page=$((page + 1))
done
[ "$total" -gt 0 ] && [ "$(grep -c . "$tmp/commits.jsonl")" = "$total" ] || fail "the commits of the push that were read are not the ones the comparison counts"

rows="$(jq -rs --arg before "$before" '
	. as $c | range(0; $c | length) as $i | $c[$i]
	| [.sha, (.parents | length | tostring), (.parents[0] // ""), (if $i == 0 then $before else $c[$i - 1].sha end), .author, .committer, (.verified | tostring)] | @tsv' "$tmp/commits.jsonl" 2>/dev/null)" || fail "the commits of the push cannot be read"
[ -n "$rows" ] || fail "the commits of the push cannot be read"
last="$(tail -n 1 "$tmp/commits.jsonl" | jq -r '.sha' 2>/dev/null)" || last=""
[ "$last" = "$after" ] || fail "the push does not end in the commit it says"

bad=0
direct_all=1
while IFS=$'\t' read -r sha nparents parent previous author committer verified; do
	hex40 "$sha" || { echo "::error::a commit of the push has no usable id"; bad=1; continue; }
	# R1
	if [ "$nparents" != 1 ] || [ "$parent" != "$previous" ]; then
		echo "::error::$sha is not a single commit on top of the one before it: a merge, a range that is not a line or a force-push"; bad=1; continue
	fi
	# R2
	pulls="$(gh api "repos/${repo}/commits/${sha}/pulls?per_page=100" 2>/dev/null)" || { echo "::error::the pull requests of $sha could not be read"; bad=1; continue; }
	associated="$(printf '%s' "$pulls" | jq -r 'if type == "array" then length else empty end' 2>/dev/null)" || associated=""
	[ -n "$associated" ] || { echo "::error::the pull requests of $sha cannot be read"; bad=1; continue; }
	number="$(printf '%s' "$pulls" | jq -r --arg sha "$sha" --arg repo "$repo" '
		if type == "array" and length == 1 and (.[0] | .merged_at != null and .merge_commit_sha == $sha and .base.ref == "main" and .head.repo.full_name == $repo)
		then .[0].number | tostring else empty end' 2>/dev/null)" || number=""
	merger=""
	head=""
	if [ -n "$number" ] && [ "$committer" = web-flow ] && [ "$verified" = true ]; then
		detail="$(gh api "repos/${repo}/pulls/${number}" 2>/dev/null)" || { echo "::error::pull request $number could not be read, so who merged it is not known"; bad=1; continue; }
		merger="$(printf '%s' "$detail" | jq -r 'select(.merged_at != null and .base.ref == "main") | .merged_by.login // empty' 2>/dev/null)" || merger=""
		head="$(printf '%s' "$detail" | jq -r 'select(.merged_at != null and .base.ref == "main") | .head.sha // empty' 2>/dev/null)" || head=""
		if ! hex40 "$head"; then
			echo "::error::pull request $number has no usable head, so it is not read as judged"; bad=1; continue
		fi
	fi
	# A commit that has a pull request, and is not the judged merge of it, is not a direct push: it is refused.
	if [ "$associated" != 0 ] && { [ -z "$merger" ] || bypasses "$merger"; }; then
		echo "::error::$sha has a pull request but is not the merge of one that was judged (merged by '${merger}', committed by '${committer}'), so it is refused and not read as a direct push"; bad=1; continue
	fi
	if [ "$associated" != 0 ]; then
		direct_all=0
		# R3
		[ -n "$(tree_of "$sha")" ] && [ "$(tree_of "$sha")" = "$(tree_of "$head")" ] || { echo "::error::$sha is not on the tree of the head of pull request $number, so what landed is not what was judged"; bad=1; continue; }
		for name in "${required[@]}"; do
			enc="$(jq -rn --arg n "$name" '$n | @uri' 2>/dev/null)" || enc=""
			[ -n "$enc" ] || { echo "::error::the check name '$name' could not be encoded"; bad=1; continue 2; }
			runs="$(gh api "repos/${repo}/commits/${head}/check-runs?check_name=${enc}&filter=all&per_page=100" 2>/dev/null)" || runs=""
			if ! printf '%s' "$runs" | jq -e '(.check_runs | type) == "array" and (.total_count | type) == "number" and (.check_runs | length) == .total_count
					and ([.check_runs[] | select(.app.id == 15368)] | length > 0 and all(.[]; .conclusion == "success"))' >/dev/null 2>&1; then
				echo "::error::pull request $number was merged without '$name' in success on its head from GitHub Actions"; bad=1; continue 2
			fi
		done
		continue
	fi
	# R4
	if ! is_updater "$pusher"; then
		echo "::error::$sha is a direct push of an actor that is not authorised ($pusher)"; bad=1; continue
	fi
	if ! is_updater "$author" || [ "$committer" != web-flow ] || [ "$verified" != true ]; then
		echo "::error::$sha is a direct push whose author is '$author' and whose committer is '$committer' ($verified), not the updater app signed by GitHub"; bad=1; continue
	fi
	commit="$(gh api "repos/${repo}/commits/${sha}" 2>/dev/null)" || { echo "::error::the files of $sha could not be read"; bad=1; continue; }
	names="$(printf '%s' "$commit" | jq -r 'if (.files | type) == "array" and (.files | length) < 300 then .files[] | .filename, (.previous_filename // empty) else empty end' 2>/dev/null)" || names=""
	[ -n "$names" ] || { echo "::error::the files of $sha cannot be listed whole"; bad=1; continue; }
	while IFS= read -r file; do
		under_generated "$file" || { echo "::error::$sha is a direct push that touches $file, which is not what the updater app writes"; bad=1; }
	done <<<"$names"
done <<<"$rows"

if [ "$direct_all" = 1 ] && [ "$bad" = 0 ]; then
	[ "$(jq 'length' "$tmp/files.json")" -gt 0 ] && [ "$(jq 'length' "$tmp/files.json")" -lt 300 ] || { echo "::error::the files of the whole push cannot be listed whole"; bad=1; }
	while IFS= read -r file; do
		under_generated "$file" || { echo "::error::the push touches $file, which is not what the updater app writes"; bad=1; }
	done < <(jq -r '.[]' "$tmp/files.json")
fi
[ "$bad" = 0 ] || exit 1
echo "push-to-main: every commit of the push is a pull request that was judged or the updater app writing only what it writes"
