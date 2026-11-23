#!/usr/bin/env bash
#
# CI runs no suite on a push to main because the ruleset of main makes the tree that lands the
# tree a pull request tested. This is the watcher of that premise: it fails when the branch
# stops having to be up to date, when a required check (the aggregator among them) stops
# being required, when the kinds of rule, the merge methods or any ruleset change, and when
# the rules cannot be read, and a scheduled run says so in an issue, once.
#
# Each case plants the answers of the API with a fake `gh`; each condition has a case that
# breaks it and the case just inside it.
#
# Requires: jq.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$HERE/scripts/monitoring/check-main-ruleset.sh"
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
case "$1" in
	api)
		case "$2" in
			*/rules/branches/main) f=rules ;;
			*/rulesets/*) f="ruleset-${2##*/}" ;;
			*/rulesets) f=rulesets ;;
			*) exit 2 ;;
		esac
		[ ! -e "$API/FAIL-$f" ] || exit 1
		[ -e "$API/$f.json" ] || exit 1
		cat "$API/$f.json" ;;
	issue)
		case "$2" in
			list)
				[ ! -e "$API/FAIL-list" ] || exit 1
				author=""; jqx=""
				while [ "$#" -gt 0 ]; do case "$1" in --author) author="$2" ;; --jq) jqx="$2" ;; esac; shift; done
				data="$(cat "$API/issues.json" 2>/dev/null || echo '[]')"
				[ -z "$author" ] || data="$(printf '%s' "$data" | jq --arg a "$author" '[.[] | select(.author.login == $a)]')"
				printf '%s' "$data" | jq -r "$jqx" ;;
			create) echo "created" >>"$API/created"; [ ! -e "$API/FAIL-create" ] || exit 1 ;;
		esac ;;
esac
GH
chmod +x "$WORK/bin/gh"

cat >"$WORK/expected.json" <<'JSON'
{"checks":["audit gate","shell / test"],
 "rules":[{"type":"deletion"},{"type":"pull_request","parameters":{"allowed_merge_methods":["squash"]}},
  {"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"shell / test","integration_id":15368},{"context":"audit gate","integration_id":15368}]}}],
 "rulesets":[{"bypass_actors":[{"actor_id":4927450,"actor_type":"Integration","bypass_mode":"always"}],"enforcement":"active","id":7,"name":"protect-main","updated_at":"2026-11-23T11:10:34Z"}],"strict":true}
JSON
good() {
	rm -f "$WORK"/api/*
	cat >"$WORK/api/rules.json" <<'JSON'
[{"type":"deletion"},{"type":"pull_request","parameters":{"allowed_merge_methods":["squash"]}},
 {"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"shell / test","integration_id":15368},{"context":"audit gate","integration_id":15368}]}}]
JSON
	cat >"$WORK/api/rulesets.json" <<'JSON'
[{"id":7,"name":"protect-main","enforcement":"active","updated_at":"2026-11-23T06:10:34.692-05:00"}]
JSON
	cat >"$WORK/api/ruleset-7.json" <<'JSON'
{"id":7,"bypass_actors":[{"actor_id":4927450,"actor_type":"Integration","bypass_mode":"always"}]}
JSON
}
edit() { # <file> <jq filter>
	jq "$2" "$WORK/api/$1.json" >"$WORK/tmp.json" && mv "$WORK/tmp.json" "$WORK/api/$1.json"
}
run() { # env... ; prints exit status and whether an issue was created
	rm -f "$WORK/api/created"
	env PATH="$WORK/bin:$PATH" API="$WORK/api" REPO="${REPO_ASKED-Glyndor/homebrew-tap}" EVENT="${EVENT:-push}" OPEN_ISSUES="${OPEN_ISSUES:-0}" \
		bash "$script" "${EXPECTED:-$WORK/expected.json}" >"$WORK/log" 2>&1
	echo "rc=$?|issues=$(wc -l <"$WORK/api/created" 2>/dev/null || echo 0)" | tr -d ' '
}

good
check "the ruleset the copy describes is accepted" "rc=0|issues=0" "$(run)"
good; edit rulesets '.[0].updated_at = "2026-11-23T11:10:34Z"'
check "the same instant written in UTC is the same instant" "rc=0|issues=0" "$(run)"

good; edit rules '(.[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy) = false'
check "a branch that no longer has to be up to date fails" "rc=1|issues=0" "$(run)"
good; edit rules 'map(if .type == "required_status_checks" then .parameters.required_status_checks |= map(select(.context != "audit gate")) else . end)'
check "an aggregator that is no longer required fails" "rc=1|issues=0" "$(run)"
good; edit rules 'map(if .type == "required_status_checks" then .parameters.required_status_checks += [{"context":"another","integration_id":1}] else . end)'
check "a required check that is added fails, so the copy follows" "rc=1|issues=0" "$(run)"
good; edit rules 'map(select(.type != "deletion"))'
check "a kind of rule that is gone fails" "rc=1|issues=0" "$(run)"
good; edit rules '. + [{"type":"update"}]'
check "a kind of rule that is new fails" "rc=1|issues=0" "$(run)"
good; edit rules 'map(if .type == "pull_request" then .parameters.allowed_merge_methods = ["squash","merge"] else . end)'
check "a merge method that is allowed fails" "rc=1|issues=0" "$(run)"
good; edit rules '. + [{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[]}}]'
check "two sets of required checks fail, because the strict of one is not the strict of the other" "rc=1|issues=0" "$(run)"
good; edit rulesets '.[0].updated_at = "2026-11-24T00:00:00.000Z"'
check "a ruleset changed since the copy fails, which is how a change of its bypass list is seen" "rc=1|issues=0" "$(run)"
good; edit rulesets '.[0].enforcement = "evaluate"'
check "a ruleset that is not enforced fails" "rc=1|issues=0" "$(run)"
good; edit rulesets '. + [{"id":8,"name":"another","enforcement":"active","updated_at":"2026-11-23T11:10:34Z"}]'
check "a ruleset that is new fails" "rc=1|issues=0" "$(run)"
good; edit rulesets '.[0].name = "renamed"'
check "a ruleset that is renamed fails" "rc=1|issues=0" "$(run)"

good; check "no repository named fails" "rc=1|issues=0" "$(REPO_ASKED='' run)"
good; touch "$WORK/api/FAIL-rules"
check "rules that cannot be read fail" "rc=1|issues=0" "$(run)"
good; touch "$WORK/api/FAIL-rulesets"
check "rulesets that cannot be read fail" "rc=1|issues=0" "$(run)"
good; printf 'not json' >"$WORK/api/rules.json"
check "rules that are not JSON fail" "rc=1|issues=0" "$(run)"
check "and the log says the rules could not be read" "1" "$(grep -c 'could not be read' "$WORK/log")"
good; printf '{"message":"Not Found"}' >"$WORK/api/rules.json"
check "rules that are not a list fail" "rc=1|issues=0" "$(run)"
check "and the log says the rules could not be read when they are JSON but not a list" "1" "$(grep -c 'could not be read' "$WORK/log")"
good; printf '{"message":"Not Found"}' >"$WORK/api/rulesets.json"
check "an answer that is not a list fails" "rc=1|issues=0" "$(run)"
good; printf '[]' >"$WORK/api/rules.json"
check "no rule at all fails" "rc=1|issues=0" "$(run)"
good; printf '[]' >"$WORK/api/rulesets.json"
check "no ruleset at all fails" "rc=1|issues=0" "$(run)"
good; edit rulesets '.[0].updated_at = "not a time"'
check "a time that cannot be read fails" "rc=1|issues=0" "$(run)"
check "and the log says the time cannot be read" "1" "$(grep -c 'the time of a change of ruleset 7 cannot be read' "$WORK/log")"
good; check "an expected copy that cannot be read fails" "rc=1|issues=0" "$(EXPECTED="$WORK/none.json" run)"
good; printf 'not json' >"$WORK/bad.json"
check "an expected copy that is not JSON fails" "rc=1|issues=0" "$(EXPECTED="$WORK/bad.json" run)"

# The bypass list.
good; edit ruleset-7 '.bypass_actors[0].actor_id = 1'
check "a bypass list that is read and is not the copy's fails" "rc=1|issues=0" "$(run)"
good; edit ruleset-7 '.bypass_actors += [{"actor_id":2,"actor_type":"RepositoryRole","bypass_mode":"always"}]'
check "a bypass actor that is added fails" "rc=1|issues=0" "$(run)"
good; edit ruleset-7 '.bypass_actors[0].bypass_mode = "pull_request"'
check "a bypass mode that changes fails" "rc=1|issues=0" "$(run)"
good; edit ruleset-7 '.bypass_actors = []'
check "a bypass list that is emptied fails" "rc=1|issues=0" "$(run)"
good; printf '{"id":7,"name":"protect-main"}' >"$WORK/api/ruleset-7.json"
check "a whole answer that carries no bypass list passes on updated_at" "rc=0|issues=0" "$(run)"
check "and the output says that it is not readable and what stands in for it" "1" "$(grep -c 'bypass list is not readable with this token; guarded by updated_at' "$WORK/log")"
good; printf '{"id":7}' >"$WORK/api/ruleset-7.json"
check "a ruleset whose answer has no bypass list is not read as an empty one" "1" "$(run >/dev/null; grep -c 'not readable with this token' "$WORK/log")"
good; printf '{"id":7}' >"$WORK/api/ruleset-7.json"; edit rulesets '.[0].updated_at = "2026-11-24T00:00:00Z"'
check "with the list hidden, an edit of the ruleset still fails through updated_at" "rc=1|issues=0" "$(run)"
good; touch "$WORK/api/FAIL-ruleset-7"
check "an answer for the ruleset that fails is a failure and not a hidden bypass list" "rc=1|issues=0" "$(run)"
check "and the log says the ruleset could not be read" "1" "$(grep -c '^::error::the ruleset 7 could not be read' "$WORK/log")"
check "and a scheduled run opens an issue for it" "rc=1|issues=1" "$(EVENT=schedule run)"
good; rm -f "$WORK/api/ruleset-7.json"
check "an answer for the ruleset that is missing is a failure too" "rc=1|issues=0" "$(run)"
good; printf 'not json' >"$WORK/api/ruleset-7.json"
check "an answer for the ruleset that does not parse is a failure" "rc=1|issues=0" "$(run)"
check "and the log says it cannot be parsed" "1" "$(grep -c 'the answer for the ruleset 7 cannot be parsed' "$WORK/log")"
good; printf '[]' >"$WORK/api/ruleset-7.json"
check "an answer for the ruleset that is not an object is a failure" "rc=1|issues=0" "$(run)"
good; printf '{"id":7,"bypass_actors":null}' >"$WORK/api/ruleset-7.json"
check "a bypass list that is present and null is a failure, not a hidden list" "rc=1|issues=0" "$(run)"
check "and the log says it is not a list" "1" "$(grep -c 'the bypass list of the ruleset 7 is not a list' "$WORK/log")"
good; printf '{"id":7,"bypass_actors":"none"}' >"$WORK/api/ruleset-7.json"
check "a bypass list that is a string is a failure" "rc=1|issues=0" "$(run)"
good; edit rules 'map(if .type == "pull_request" then .parameters.dismiss_stale_reviews_on_push = true else . end)'
check "a parameter of a rule that changes fails" "rc=1|issues=0" "$(run)"

# The issue.
good; edit rules 'map(select(.type != "deletion"))'
check "a scheduled run that finds a difference opens one issue" "rc=1|issues=1" "$(EVENT=schedule run)"
check "a run of a pull request that finds it does not" "rc=1|issues=0" "$(EVENT=pull_request run)"
title="The ruleset of main is not the one CI relies on"
printf '[{"title":"%s","author":{"login":"app/github-actions"}}]' "$title" >"$WORK/api/issues.json"
check "a scheduled run does not open a second issue while the workflow's own is open" "rc=1|issues=0" "$(EVENT=schedule run)"
printf '[{"title":"%s","author":{"login":"someone"}}]' "$title" >"$WORK/api/issues.json"
check "an issue with that title opened by somebody else does not silence the alert" "rc=1|issues=1" "$(EVENT=schedule run)"
printf '[{"title":"%s too","author":{"login":"app/github-actions"}}]' "$title" >"$WORK/api/issues.json"
check "an issue of the workflow with another title does not silence the alert" "rc=1|issues=1" "$(EVENT=schedule run)"
printf '[{"title":"%s","author":{"login":"app/github-actions-fake"}}]' "$title" >"$WORK/api/issues.json"
check "an issue from an author that only looks like the workflow does not silence the alert" "rc=1|issues=1" "$(EVENT=schedule run)"
rm -f "$WORK/api/issues.json"; touch "$WORK/api/FAIL-list"
check "open issues that cannot be listed are an error of their own and open none" "rc=2|issues=0" "$(EVENT=schedule run)"
check "and the log says so with an error" "1" "$(grep -c '^::error::the open issues could not be listed' "$WORK/log")"
rm -f "$WORK/api/FAIL-list"; touch "$WORK/api/FAIL-create"
check "an issue that cannot be created is an error of its own" "rc=2|issues=1" "$(EVENT=schedule run)"
check "and the log says so with an error" "1" "$(grep -c '^::error::the issue that says so could not be opened' "$WORK/log")"
good; touch "$WORK/api/FAIL-rules"
check "rules that cannot be read on a scheduled run open an issue too" "rc=1|issues=1" "$(EVENT=schedule run)"
good; check "a scheduled run that finds nothing opens no issue" "rc=0|issues=0" "$(EVENT=schedule run)"

echo
echo "passed: $pass  failed: $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
