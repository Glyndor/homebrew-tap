#!/usr/bin/env bash
#
# Fail when the newest COMPLETED run of `tests.yml` on `main` is not `success`.
#
# `freshness.yml` already watches for absence: a schedule that stopped firing
# emits nothing at all, and reusable-schedule-freshness reads the newest
# *successful* scheduled run to turn that silence into a red check. That is
# the right signal for an alarm that fires on its own clock; it is the wrong
# signal for the suite. The suite runs on pull_request and on push to `main`,
# not on a cron, so it does not silently stop. What it does is land a red on
# `main`: a mergeable pull request whose checks were green can land, and a
# `push` event (most often the bot committing straight to `main` from
# update.yml) can fail the re-run, and `reusable-schedule-freshness` cannot
# see that case because the newest successful scheduled run is independent
# of what happened on the last push. This script reads the runs themselves.
#
# Reads the JSON shape `gh api repos/{owner}/{repo}/actions/workflows/{wf}/runs`
# returns. The call passes no `status` filter on purpose: an in-progress run
# is in the list rather than invisible, and the script walks past it. The
# newest run whose status is `completed` is what is checked, because an
# in-progress run is not yet a verdict, and conflating "still running" with
# "succeeded" would mean the next green run hides any red that landed while
# the previous one was finishing.
#
# Empty result is reported, not passed. With no completed run on record at
# all (first run still queued, branch never landed anything that finished,
# the workflow file missing), the script exits 1 and says so. Passing
# silently over an empty history is how a workflow that never reached the
# runner at all reads as green -- the failure mode this script exists to
# surface.
#
# Usage: check-suite-on-main.sh <path-to-runs-json>
#        check-suite-on-main.sh -   (read JSON from stdin)
# Workflows save the API response to a file and pass its path; tests do the
# same with a fixture.

set -euo pipefail

INPUT="${1:-}"
case "$INPUT" in
	"")
		echo "usage: check-suite-on-main.sh <path-to-runs-json>|-" >&2
		exit 2 ;;
	-)
		JSON="$(cat)" ;;
	*)
		[ -e "$INPUT" ] || { echo "no such file: $INPUT" >&2; exit 2; }
		JSON="$(cat "$INPUT")" ;;
esac

# Walk every run, drop the in-progress ones, and pick the newest by
# created_at. The array GitHub returns is already newest-first, but sorting
# client-side survives a server-side ordering change and is cheap on the
# twenty items the caller pages in.
newest="$(printf '%s' "$JSON" | jq -r '
	[ .workflow_runs[]
	  | select(.status == "completed")
	]
	| sort_by(.created_at) | reverse | .[0] // empty
')"

if [ -z "$newest" ]; then
	echo "::error::No completed run on record for tests.yml on main."
	echo "Either tests.yml has never finished a run on main, or every run is still in progress." >&2
	echo "A watcher that passes silently over an empty history would hide the failure mode this exists to surface." >&2
	exit 1
fi

conclusion="$(printf '%s' "$newest" | jq -r '.conclusion')"
created_at="$(printf '%s' "$newest" | jq -r '.created_at')"
html_url="$(printf '%s' "$newest" | jq -r '.html_url')"
id="$(printf '%s' "$newest" | jq -r '.id')"

echo "Newest completed tests.yml run on main:"
echo "  id:         $id"
echo "  created_at: $created_at"
echo "  conclusion: $conclusion"
echo "  url:        $html_url"

if [ "$conclusion" != "success" ]; then
	echo "::error::main is red: newest completed run of tests.yml on main is '$conclusion', not success."
	echo "Re-run the failing job, or fix the underlying failure on a branch and land it." >&2
	exit 1
fi

echo "main is green: newest completed run of tests.yml on main succeeded."
