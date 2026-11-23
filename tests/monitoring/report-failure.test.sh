#!/usr/bin/env bash
#
# A job that judges main and fails reports it in an issue, once, and an issue of anybody else
# does not silence it. Each case plants the answers of `gh` with a fake; each condition has a
# case that breaks it and the case just inside it.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$HERE/scripts/monitoring/report-failure.sh"
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

mkdir "$WORK/bin" "$WORK/api"
cat >"$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
[ "$1" = issue ] || exit 2
case "$2" in
	list)
		[ ! -e "$API/FAIL-list" ] || exit 1
		author=""; jqx=""
		while [ "$#" -gt 0 ]; do case "$1" in --author) author="$2" ;; --jq) jqx="$2" ;; esac; shift; done
		data="$(cat "$API/issues.json" 2>/dev/null || echo '[]')"
		[ -z "$author" ] || data="$(printf '%s' "$data" | jq --arg a "$author" '[.[] | select(.author.login == $a)]')"
		printf '%s' "$data" | jq -r "$jqx" ;;
	create) echo "created" >>"$API/created"; [ ! -e "$API/FAIL-create" ] || exit 1 ;;
esac
GH
chmod +x "$WORK/bin/gh"
TITLE="A formula pushed to main by the updater does not pass"
run() { # args of the script
	rm -f "$WORK/api/created"
	env PATH="$WORK/bin:$PATH" API="$WORK/api" REPO="${REPO_ASKED-Glyndor/homebrew-tap}" bash "$script" "$@" >"$WORK/log" 2>&1
	echo "rc=$?|issues=$(wc -l <"$WORK/api/created" 2>/dev/null || echo 0)" | tr -d ' '
}
reset() { rm -f "$WORK"/api/*; }

reset
check "a failure with no issue open opens one and fails" "rc=1|issues=1" "$(run "$TITLE" body)"
printf '[{"title":"%s","author":{"login":"app/github-actions"}}]' "$TITLE" >"$WORK/api/issues.json"
check "an issue of the workflow with that title already open is not repeated" "rc=1|issues=0" "$(run "$TITLE" body)"
printf '[{"title":"%s","author":{"login":"someone"}}]' "$TITLE" >"$WORK/api/issues.json"
check "an issue with that title opened by somebody else does not silence it" "rc=1|issues=1" "$(run "$TITLE" body)"
printf '[{"title":"%s too","author":{"login":"app/github-actions"}}]' "$TITLE" >"$WORK/api/issues.json"
check "an issue of the workflow with another title does not silence it" "rc=1|issues=1" "$(run "$TITLE" body)"
printf '[{"title":"%s","author":{"login":"app/github-actions-fake"}}]' "$TITLE" >"$WORK/api/issues.json"
check "an author that only looks like the workflow does not silence it" "rc=1|issues=1" "$(run "$TITLE" body)"
reset; touch "$WORK/api/FAIL-list"
check "issues that cannot be listed are an error of their own" "rc=2|issues=0" "$(run "$TITLE" body)"
check "and the log says so" "1" "$(grep -c '^::error::the open issues could not be listed' "$WORK/log")"
reset; touch "$WORK/api/FAIL-create"
check "an issue that cannot be opened is an error of its own" "rc=2|issues=1" "$(run "$TITLE" body)"
check "and the log says so" "1" "$(grep -c '^::error::the issue that says so could not be opened' "$WORK/log")"
reset; check "no title is an error" "rc=2|issues=0" "$(run '' body)"
check "no repository is an error" "rc=2|issues=0" "$(REPO_ASKED='' run "$TITLE" body)"
check "a title with a quote is an error" "rc=2|issues=0" "$(run 'a "b"' body)"
check "a title with a backslash is an error" "rc=2|issues=0" "$(run 'a\b' body)"

echo
echo "passed: $pass  failed: $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
