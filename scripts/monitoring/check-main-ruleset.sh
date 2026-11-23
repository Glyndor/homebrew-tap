#!/usr/bin/env bash
#
# Fail when the ruleset that protects main is no longer the one this repository's CI
# assumes, and say so in an issue when a scheduled run finds it.
#
# CI does not run its suites again on a push to main. What lands on main came through a
# pull request, and what makes the tree that lands the tree that pull request tested is the
# ruleset: the branch has to be up to date (`strict`), the checks that judge the pull
# request are required, and the only actor that bypasses is the app that regenerates the
# formulae, whose path is judged by workflows of its own. This reads the rules in force on
# main and the rulesets of the repository from GitHub and compares them with
# scripts/monitoring/main-ruleset.expected.json. A difference, an answer that cannot be
# read and a call that fails all fail: a premise that cannot be seen is not one that holds.
#
# What the copy keeps: whether the branch has to be up to date, the contexts of the required
# checks, every rule in force with its parameters, and for each ruleset its id, name,
# enforcement and `updated_at`. The list of who may bypass is returned only to a token that
# can administer the repository. When the answer carries it, it is compared exactly with the
# copy; when it does not, the output says so, and what stands in for it is `updated_at`,
# which is assumed to change on any edit of the ruleset, the bypass list included. That
# assumption has not been measured. A change that is meant is followed by a pull request that
# updates the copy.
#
# A scheduled run that finds a difference, or cannot read the rules, opens an issue unless
# an open one with this exact title, opened by the workflow, exists; an issue that cannot be
# opened is an error of its own. Issues opened by anybody else do not count: anyone can write
# a title.
#
# Inputs (env): GH_TOKEN, REPO, EVENT (`schedule` opens an issue). Argument: the expected
# file (default: the copy beside this script).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
expected="${1:-$here/main-ruleset.expected.json}"
repo="${REPO:-}"
title="The ruleset of main is not the one CI relies on"

report() { # <what was found> : an issue on a scheduled run, then the failure
	echo "::error::$1"
	if [ "${EVENT:-}" = schedule ]; then
		open="$(gh issue list -R "$repo" --state open --author app/github-actions --limit 100 --json title \
			--jq "[.[] | select(.title == \"$title\")] | length" 2>/dev/null)" || open=""
		case "$open" in
			0)
				gh issue create -R "$repo" --title "$title" --label "type:ci" --label "prio:P1" \
					--body "A scheduled run reports: $1. CI does not run its suites again on a push to main, because the ruleset makes the tree that lands the tree a pull request tested, so this has to be looked at: either the ruleset was changed by accident, or it was changed on purpose and scripts/monitoring/main-ruleset.expected.json has to follow." >/dev/null 2>&1 \
					|| { echo "::error::the issue that says so could not be opened"; exit 2; } ;;
			[1-9]*) ;;
			*) echo "::error::the open issues could not be listed, so whether this was already reported is not known"; exit 2 ;;
		esac
	fi
	exit 1
}

[ -n "$repo" ] || { echo "::error::no repository named, so the ruleset cannot be read"; exit 1; }
[ -r "$expected" ] || { echo "::error::$expected cannot be read, so there is nothing to compare with"; exit 1; }

rules="$(gh api "repos/${repo}/rules/branches/main" 2>/dev/null)" || rules=""
sets="$(gh api "repos/${repo}/rulesets" 2>/dev/null)" || sets=""

# GitHub writes the instant of a change in the zone of whoever asks, so every instant is put
# in UTC, to the second, before it is compared. The bypass list of each ruleset is read when
# the token is allowed to see it.
stamps='{}'
bypass='{}'
hidden=0
while read -r id ts; do
	[ -n "$id" ] || continue
	utc="$(date -u -d "$ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || utc=""
	[ -n "$utc" ] || report "the time of a change of ruleset $id cannot be read, so what CI assumes about main is not known"
	stamps="$(jq -c --arg id "$id" --arg utc "$utc" '. + {($id): $utc}' <<<"$stamps")"
	detail="$(gh api "repos/${repo}/rulesets/${id}" 2>/dev/null)" || report "the ruleset $id could not be read, so what CI assumes about main is not known"
	printf '%s' "$detail" | jq -e 'type == "object"' >/dev/null 2>&1 || report "the answer for the ruleset $id cannot be parsed, so what CI assumes about main is not known"
	# Only an answer that is whole and carries no `bypass_actors` at all is the token not being shown the list.
	if printf '%s' "$detail" | jq -e 'has("bypass_actors")' >/dev/null 2>&1; then
		list="$(printf '%s' "$detail" | jq -c 'if (.bypass_actors | type) == "array" then [.bypass_actors[] | {actor_id, actor_type, bypass_mode}] | sort_by(.actor_type, .actor_id) else empty end' 2>/dev/null)" || list=""
		[ -n "$list" ] || report "the bypass list of the ruleset $id is not a list, so what CI assumes about main is not known"
		bypass="$(jq -c --arg id "$id" --argjson list "$list" '. + {($id): $list}' <<<"$bypass")"
	else
		hidden=1
	fi
done < <(printf '%s' "${sets:-null}" | jq -r 'if type == "array" then .[] | "\(.id) \(.updated_at)" else empty end' 2>/dev/null)

snapshot="$(jq -S -n --argjson stamps "$stamps" --argjson bypass "$bypass" --argjson rules "${rules:-null}" --argjson sets "${sets:-null}" '
	if ($sets | type) != "array" or ($rules | length) == 0 or ($sets | length) == 0 then empty
	else {
		strict: ([$rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy] | first),
		checks: ([$rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context] | sort_by(.)),
		rules: ([$rules[] | {type} + (if .parameters then {parameters} else {} end)] | sort_by(.type, (.parameters | tojson))),
		rulesets: ([$sets[] | {id, name, enforcement, updated_at: $stamps[(.id | tostring)]} + (if $bypass[(.id | tostring)] then {bypass_actors: $bypass[(.id | tostring)]} else {} end)] | sort_by(.id))
	} end' 2>/dev/null)" || snapshot=""

[ -n "$snapshot" ] || report "the rules of main or the rulesets of $repo could not be read, so what CI assumes about main is not known"
want="$(jq -S . "$expected" 2>/dev/null)" || want=""
if [ "$hidden" = 1 ]; then
	echo "main-ruleset: the bypass list is not readable with this token; guarded by updated_at"
	want="$(printf '%s' "$want" | jq -S 'if (.rulesets | type) == "array" then .rulesets |= map(del(.bypass_actors)) else . end' 2>/dev/null)" || want=""
fi

if [ "$snapshot" = "$want" ]; then
	echo "main-ruleset: the ruleset of main is the one the copy describes"
	exit 0
fi

diff <(printf '%s\n' "$want") <(printf '%s\n' "$snapshot") | sed 's/^/main-ruleset: /' || true
report "the ruleset that protects main is not what scripts/monitoring/main-ruleset.expected.json says"
