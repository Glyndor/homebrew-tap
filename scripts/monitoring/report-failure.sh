#!/usr/bin/env bash
#
# Open an issue that says a job that judges main failed, unless the workflow already has one
# open with that exact title, and then fail.
#
#   report-failure.sh <title> <body>
#
# There is no pull request to block when what failed was judged after it landed, so the issue
# is the alert. Only an open issue with this exact title opened by the workflow counts as
# already reported: anyone can write a title, so issues of anybody else are not looked at. An
# issue that cannot be opened, and a list of issues that cannot be read, are errors of their
# own (exit 2); otherwise the exit is 1, because what this reports is a failure.
#
# Inputs (env): GH_TOKEN, REPO.
set -uo pipefail

title="${1:-}"
body="${2:-}"
repo="${REPO:-}"
[ -n "$title" ] && [ -n "$repo" ] || { echo "::error::report-failure.sh needs a title and REPO"; exit 2; }
case "$title" in *\"* | *\\*) echo "::error::the title has a character the search cannot carry"; exit 2 ;; esac

open="$(gh issue list -R "$repo" --state open --author app/github-actions --limit 100 --json title \
	--jq "[.[] | select(.title == \"$title\")] | length" 2>/dev/null)" || open=""
case "$open" in
	0)
		gh issue create -R "$repo" --title "$title" --label "type:bug" --label "prio:P1" --body "$body" >/dev/null 2>&1 \
			|| { echo "::error::the issue that says so could not be opened"; exit 2; } ;;
	[1-9]*) echo "report-failure: an issue with this title is already open" ;;
	*) echo "::error::the open issues could not be listed, so whether this was already reported is not known"; exit 2 ;;
esac
exit 1
