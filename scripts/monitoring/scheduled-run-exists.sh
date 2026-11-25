#!/usr/bin/env bash
#
# Say whether a scheduled run of a workflow has succeeded in the last days, so that a run that exists only to try again
# can leave the work undone.
#
# The sweep of the mutations is tried at three fixed hours when its cron has not fired, because the freshness watcher
# wants a scheduled run that succeeded and a manual one is not that. Once one has succeeded the other tries have nothing
# left to answer, and a full sweep on a saturated runner is a cost the repository does not pay for nothing. The first job
# of the workflow asks this script, and the sweep is skipped, with success, when the answer is yes.
#
# It prints `skip=true` or `skip=false`, in the form a step writes to $GITHUB_OUTPUT. Only a run that is not the current
# one counts, and only one of the event `schedule` with the conclusion `success` created inside the window. Every doubt
# answers `skip=false`, so that the sweep runs: an API that fails, a response that is not what it should be, a window that
# is not a whole number of days. The cost of a doubt is one sweep, and the cost of the other answer is a watcher that
# stays red.
#
# Environment: GH_TOKEN (read access to the actions of the repository), REPO (owner/name), WORKFLOW (file name), DAYS (the
# window), THIS_RUN_ID (the run that is asking), EVENT_NAME and EVENT_SCHEDULE (the event and the cron that started it), and
# WEEKLY_CRON (the cron of the run that is never skipped). With a file as the argument, or - for stdin, the response of the API is
# read from there and nothing is fetched; the suites plant their responses that way.
#
# Usage:
#   scheduled-run-exists.sh                 # asks the API
#   scheduled-run-exists.sh <runs.json>     # reads the response from the file
set -euo pipefail

answer() { printf 'skip=%s\n' "$1"; exit 0; }

# Only a run that was started by one of the extra crons may be skipped. A run of another event, or of the weekly cron, answers for
# its own week and runs whatever the history says.
[ "${EVENT_NAME:-}" = schedule ] || answer false
WEEKLY_CRON="${WEEKLY_CRON:-}"
[ -n "$WEEKLY_CRON" ] || { echo "::warning::the cron of the weekly run is not named; the sweep runs" >&2; answer false; }
[ "${EVENT_SCHEDULE:-}" != "$WEEKLY_CRON" ] || answer false

DAYS="${DAYS:-}"
case "$DAYS" in '' | *[!0-9]* | 0*) echo "::warning::the window of days is '$DAYS', not a whole number above zero; the sweep runs" >&2; answer false ;; esac
THIS_RUN_ID="${THIS_RUN_ID:-}"
case "$THIS_RUN_ID" in '' | *[!0-9]*) echo "::warning::the id of this run is '$THIS_RUN_ID'; the sweep runs" >&2; answer false ;; esac

cutoff="$(date -u -d "$DAYS days ago" +%Y-%m-%dT%H:%M:%SZ)"

if [ -n "${1:-}" ]; then
	if [ "$1" = "-" ]; then json="$(cat)"; else json="$(cat -- "$1")" || answer false; fi
else
	REPO="${REPO:-}"
	WORKFLOW="${WORKFLOW:-}"
	case "$REPO" in */*) ;; *) echo "::warning::REPO is '$REPO'; the sweep runs" >&2; answer false ;; esac
	case "$WORKFLOW" in '' | */* | *[!A-Za-z0-9._-]*) echo "::warning::WORKFLOW is '$WORKFLOW'; the sweep runs" >&2; answer false ;; esac
	json="$(gh api "repos/$REPO/actions/workflows/$WORKFLOW/runs?event=schedule&status=success&per_page=30&created=%3E%3D$cutoff")" \
		|| { echo "::warning::the runs of $WORKFLOW could not be read; the sweep runs" >&2; answer false; }
fi

# The window is applied here as well, not only in the query: a response that ignores the filter must not count a run that
# is older than the window, or one that did not succeed, or the run that is asking.
count="$(printf '%s' "$json" | jq --arg cutoff "$cutoff" --arg this "$THIS_RUN_ID" \
	'[.workflow_runs[]? | select(.event == "schedule" and .conclusion == "success" and (.id | tostring) != $this and .created_at >= $cutoff)] | length' 2>/dev/null)" \
	|| { echo "::warning::the response about the runs of the workflow is not readable; the sweep runs" >&2; answer false; }
case "$count" in '' | *[!0-9]*) answer false ;; esac
[ "$count" -ge 1 ] && answer true
answer false
