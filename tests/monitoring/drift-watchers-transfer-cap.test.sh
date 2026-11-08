#!/usr/bin/env bash
# The three drift watchers fetch a workflow file from a sibling repository and
# diff it. A response of unbounded size would fill the runner's disk or memory
# before --max-time stopped it, so each curl must also carry --max-filesize.
#
# The cases read the scripts, then run the same audit over a copy with the cap
# removed and require it to be reported: a check that passes on a sabotaged
# copy proves nothing.
#
# Requires: bash, grep, sed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"
		pass=$((pass + 1))
	else
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# Count of curl invocations in a script that carry no --max-filesize.
uncapped() { # <script>
	grep -E '(^|[^A-Za-z0-9_/])curl[[:space:]]' "$1" | grep -vE '^[[:space:]]*#' \
		| grep -vc -e '--max-filesize' || true
}

# Count of curl invocations in a script.
calls() { # <script>
	grep -E '(^|[^A-Za-z0-9_/])curl[[:space:]]' "$1" | grep -vcE '^[[:space:]]*#' || true
}

for name in check-render-drift check-reusable-drift check-channel-drift; do
	script="$HERE/scripts/monitoring/$name.sh"
	check "$name fetches with curl" "1" "$([ "$(calls "$script")" -ge 1 ] && echo 1 || echo 0)"
	check "$name: every curl carries --max-filesize" "0" "$(uncapped "$script")"

	sed 's/ --max-filesize [^ ]*//' "$script" > "$WORK/$name.sh"
	check "$name: the audit reports a copy with the cap removed" "1" \
		"$([ "$(uncapped "$WORK/$name.sh")" -ge 1 ] && echo 1 || echo 0)"
done

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
