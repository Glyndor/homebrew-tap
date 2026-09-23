#!/usr/bin/env bash
#
# Fail when the tests.yml run that should answer for the current event is
# not `success`.
#
# Two modes, picked from the environment when no file is given:
#
# 1. push (GITHUB_EVENT_NAME=push). The verdict is the tests.yml run on
#    main whose head_sha equals GITHUB_SHA, i.e. the run of the commit that
#    was just pushed. The script polls up to 32 times with 15 s between
#    attempts (8 minutes, inside the 10-minute job timeout) waiting for
#    that run to appear and finish. A `cancelled` conclusion for the
#    pushed commit is RED: nothing newer can answer for that commit, and
#    waiting for a successor would be the wrong shape.
#
#    A previous commit's run is not a verdict here. On 2026-09-19 the
#    push that fixed a red main was itself green, but this job ran on
#    push at the same moment and asked for the newest completed run on
#    main, which was the previous commit's still-red run. The script
#    reported red over a run that had nothing to do with the commit being
#    checked, and a developer pushing the fix saw the red on their next
#    visit while the queue refilled with green. Picking the run with the
#    matching head_sha closes that race.
#
# 2. schedule / pull_request. The newest completed run on main, with
#    `cancelled` conclusions skipped (a cancelled run means a newer push
#    superseded it, not that the suite is red). The page is sorted by
#    created_at newest first; the API does not guarantee that order, and
#    on 2026-09-08 a one-item page returned a run thirteen days old while
#    that morning's success existed (Glyndor/apt#249).
#
# `per_page=30` in both modes. A page that comes back unsorted cannot be
# trusted on its own, and thirty is comfortably above what any realistic
# day on this repository produces (measured: zero to three Tests runs on
# main per day over the last week).
#
# When a JSON file path or `-` is given on the command line, the script
# processes the supplied response as the schedule / pull_request case
# (newest-completed semantics). Tests that plant a fixture use this form.
#
# Empty result is reported, not passed. With no completed run on record at
# all, the script exits 1 and says so. Passing silently over an empty
# history is how a workflow that never reached the runner at all reads as
# green, the failure mode this script exists to surface.
#
# Usage:
#   check-suite-on-main.sh                    # mode from env, calls gh api
#   check-suite-on-main.sh <path-to-runs-json> # parse the given file
#   check-suite-on-main.sh -                  # read JSON from stdin

set -euo pipefail

INPUT="${1:-}"

# Read a JSON response and emit the verdict for the schedule /
# pull_request case. Cancelled conclusions are skipped: a cancelled run
# means a newer push superseded it, not that the suite is red. If every
# completed run on record was cancelled, there is no verdict at all.
check_schedule_json() {
	local json="$1"

	local picked cancelled_count
	picked="$(printf '%s' "$json" | jq -r '
		[ .workflow_runs[]
		  | select(.status == "completed" and .conclusion != "cancelled")
		]
		| sort_by(.created_at) | reverse | .[0] // empty
	')"
	cancelled_count="$(printf '%s' "$json" | jq -r '
		[ .workflow_runs[]
		  | select(.status == "completed" and .conclusion == "cancelled")
		] | length
	')"

	if [ -z "$picked" ] && [ "${cancelled_count:-0}" -gt 0 ]; then
		echo "::error::No verdict on main: every completed tests.yml run was cancelled ($cancelled_count)."
		echo "A newer push superseded each one. Wait for the next scheduled" >&2
		echo "fire or push the next commit." >&2
		exit 1
	fi

	if [ -z "$picked" ]; then
		echo "::error::No completed run on record for tests.yml on main."
		echo "Either tests.yml has never finished a run on main, or every run is still in progress." >&2
		echo "A watcher that passes silently over an empty history would hide the failure mode this exists to surface." >&2
		exit 1
	fi

	local conclusion created_at html_url id
	conclusion="$(printf '%s' "$picked" | jq -r '.conclusion')"
	created_at="$(printf '%s' "$picked" | jq -r '.created_at')"
	html_url="$(printf '%s' "$picked" | jq -r '.html_url')"
	id="$(printf '%s' "$picked" | jq -r '.id')"

	echo "Newest completed tests.yml run on main:"
	echo "  id:         $id"
	echo "  created_at: $created_at"
	echo "  conclusion: $conclusion"
	echo "  url:        $html_url"

	if [ "${cancelled_count:-0}" -gt 0 ]; then
		if [ "$cancelled_count" -eq 1 ]; then
			echo "  skipped 1 cancelled run (newer push superseded it)"
		else
			echo "  skipped $cancelled_count cancelled runs (newer pushes superseded them)"
		fi
	fi

	if [ "$conclusion" != "success" ]; then
		echo "::error::main is red: newest completed run of tests.yml on main is '$conclusion', not success."
		echo "Re-run the failing job, or fix the underlying failure on a branch and land it." >&2
		exit 1
	fi

	echo "main is green: newest completed run of tests.yml on main succeeded."
}

# Push mode: poll up to 32 times with 15 s between attempts (8 minutes)
# for the tests.yml run on main whose head_sha equals the pushed commit.
# Nothing newer can answer for that commit, so a cancelled run for it is
# RED and the script does not wait for a successor.
push_path() { # $1=REPO $2=SHA
	local repo="$1" sha="$2"
	local attempt=1 max_attempts=32

	while [ "$attempt" -le "$max_attempts" ]; do
		local page run
		# head_sha so the API returns only runs for the pushed commit; a
		# re-run of an older commit cannot push this run past page 30.
		# The local jq select is the second guard, not the first.
		page="$(gh api "repos/${repo}/actions/workflows/tests.yml/runs?branch=main&per_page=30&head_sha=${sha}")"
		run="$(printf '%s' "$page" | jq -r --arg sha "$sha" '
			[ .workflow_runs[]
			  | select(.head_sha == $sha)
			]
			| sort_by(.created_at) | reverse | .[0] // empty
		')"

		if [ -n "$run" ]; then
			local status conclusion created_at html_url id
			status="$(printf '%s' "$run" | jq -r '.status')"
			conclusion="$(printf '%s' "$run" | jq -r '.conclusion')"
			created_at="$(printf '%s' "$run" | jq -r '.created_at')"
			html_url="$(printf '%s' "$run" | jq -r '.html_url')"
			id="$(printf '%s' "$run" | jq -r '.id')"

			if [ "$status" = "completed" ]; then
				echo "tests.yml run on main for commit $sha:"
				echo "  id:         $id"
				echo "  created_at: $created_at"
				echo "  conclusion: $conclusion"
				echo "  url:        $html_url"

				if [ "$conclusion" != "success" ]; then
					echo "::error::main is red: tests.yml run for commit $sha is '$conclusion', not success."
					echo "Re-run the failing job, or fix the underlying failure on a branch and land it." >&2
					exit 1
				fi

				echo "main is green: tests.yml run for commit $sha succeeded."
				exit 0
			fi
		fi

		if [ "$attempt" -lt "$max_attempts" ]; then
			sleep 15
		fi
		attempt=$((attempt + 1))
	done

	echo "::error::No tests.yml run on main for commit $sha finished within 8 minutes (waited $max_attempts attempts; refusing to read another commit's run as a verdict)."
	exit 1
}

if [ -z "$INPUT" ] && [ -n "${GITHUB_EVENT_NAME:-}" ]; then
	# Env-driven: call gh api based on mode.
	EVENT="${GITHUB_EVENT_NAME:-}"
	SHA="${GITHUB_SHA:-}"
	REPO="${REPO:-${GITHUB_REPOSITORY:-}}"

	if [ -z "$REPO" ]; then
		echo "::error::REPO or GITHUB_REPOSITORY must be set when running without a JSON argument"
		exit 2
	fi

	if [ "$EVENT" = "push" ]; then
		if [ -z "$SHA" ]; then
			echo "::error::GITHUB_SHA must be set when running in push mode"
			exit 2
		fi
		push_path "$REPO" "$SHA"
	else
		# status=completed so in-flight runs cannot fill the 30-item page
		# ahead of the newest completed one.
		JSON="$(gh api "repos/${REPO}/actions/workflows/tests.yml/runs?branch=main&per_page=30&status=completed")"
		check_schedule_json "$JSON"
	fi
else
	case "$INPUT" in
		"")
			echo "usage: check-suite-on-main.sh [path-to-runs-json]|-" >&2
			exit 2 ;;
		-)
			JSON="$(cat)" ;;
		*)
			[ -e "$INPUT" ] || { echo "no such file: $INPUT" >&2; exit 2; }
			JSON="$(cat "$INPUT")" ;;
	esac
	check_schedule_json "$JSON"
fi
