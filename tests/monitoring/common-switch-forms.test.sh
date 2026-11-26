#!/usr/bin/env bash
# common-switch-forms.sh: the part of the forms of the switch rule that the two channels share. What it leaves out is
# exactly what is listed, a listed entry has to differ, and anything it cannot read is a refusal.
#
# Requires: bash, python3.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$HERE/scripts/monitoring/common-switch-forms.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"; fail=$((fail + 1))
		sed 's/^/        | /' "$WORK/out" 2> /dev/null
	fi
}
# forms <file> <form of own job> <form of the shared job> [a note]
forms() {
	printf '{"notes": ["%s"], "conditional_jobs": [{"file": "w.yml", "job": "own", "forms": ["%s"]}, {"file": "w.yml", "job": "both", "forms": ["%s"]}], "step_conditions": [{"file": "w.yml", "job": "both", "ifs": ["x"]}], "allowed_inputs": {"r.yml": []}}\n' \
		"${4:-n}" "$2" "$3" > "$1"
}
list() { printf '# a comment\n\n' > "$WORK/list"; printf '%b\n' "$@" >> "$WORK/list"; }
OWN='conditional_jobs\tw.yml\town'
run() {
	local rc=0
	rm -f "$WORK/a.out" "$WORK/b.out"
	bash "$SCRIPT" "$WORK/a" "$WORK/b" "$WORK/list" "$WORK/a.out" "$WORK/b.out" > "$WORK/out" 2>&1 || rc=$?
	echo "$rc"
}
same() { cmp -s "$WORK/a.out" "$WORK/b.out" && echo same || echo differ; }
says() { grep -c -F -- "$1" "$WORK/out" || true; }

forms "$WORK/a" one s; forms "$WORK/b" two s; list "$OWN"
check "the listed job apart, the two copies say the same" "0 same" "$(run) $(same)"
check "the listed entry is in neither" "0" "$(grep -c '"own"' "$WORK/a.out" "$WORK/b.out" | awk -F: '{ n += $2 } END { print n }')"
check "the rest is there, an entry a line" "2" "$(grep -c '"both"' "$WORK/a.out")"
forms "$WORK/b" two changed
check "a job that is not listed still differs" "0 differ" "$(run) $(same)"
forms "$WORK/b" two s changed
check "and so does a note" "0 differ" "$(run) $(same)"
forms "$WORK/b" two s
sed -i 's/"r.yml": \[\]/"r.yml": ["more"]/' "$WORK/b"
check "and what is not a list of entries" "0 differ" "$(run) $(same)"
forms "$WORK/b" two s
sed -i 's/"ifs": \["x"\]/"ifs": ["y"]/' "$WORK/b"
check "and the step condition of a job whose conditional entry alone is listed" "0 differ" "$(run) $(same)"
forms "$WORK/b" two s
python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); d["conditional_jobs"] = d["conditional_jobs"][1:]; json.dump(d, open(sys.argv[1], "w"))' "$WORK/b"
check "a listed job only one side has is left out of both" "0 same" "$(run) $(same)"

forms "$WORK/b" one s
check "a listed entry that no longer differs is refused" "1 1" "$(run) $(says 'take the line off')"
list "$OWN" 'conditional_jobs\tw.yml\tabsent'; forms "$WORK/b" two s
check "and so is one neither side has" "1 1" "$(run) $(says 'take the line off')"
for bad in 'conditional_jobs\tw.yml' 'conditional_jobs w.yml own' 'notes\tw.yml\town' 'conditional_jobs\tw.yml\town\textra' 'conditional_jobs\t\town'; do
	list "$bad"
	check "the list line '$bad' is refused" "1 1" "$(run) $(says 'is not')"
done
list "$OWN" "$OWN"
check "a line listed twice is refused" "1 1" "$(run) $(says 'twice')"
rm "$WORK/list"
check "a list that is not there is refused" "1 1" "$(run) $(says 'cannot read')"
list "$OWN"
for side in a b; do
	forms "$WORK/a" one s; forms "$WORK/b" two s
	printf '{' > "$WORK/$side"
	check "forms that are not JSON, side $side, are refused" "1 1" "$(run) $(says 'cannot be read as the forms')"
	rm "$WORK/$side"
	check "forms that are not there, side $side, are refused" "1 1" "$(run) $(says 'cannot be read as the forms')"
	printf '{"conditional_jobs": [], "conditional_jobs": [], "step_conditions": []}' > "$WORK/$side"
	check "a key written twice, side $side, is refused" "1 1" "$(run) $(says 'written twice')"
	for shape in '[]' '{"conditional_jobs": []}' '{"conditional_jobs": {}, "step_conditions": []}' '{"conditional_jobs": [1], "step_conditions": []}' '{"conditional_jobs": [{"job": "j"}], "step_conditions": []}'; do
		printf '%s' "$shape" > "$WORK/$side"
		check "forms shaped as ${shape:0:30}, side $side, are refused" "1 1" "$(run) $(says 'does not hold the lists')"
	done
done
rc=0; bash "$SCRIPT" a b > "$WORK/out" 2>&1 || rc=$?
check "the wrong number of arguments" "2" "$rc"

# The list and the forms of this repository: against a copy of itself every listed line is refused, since nothing differs,
# which shows each line is read as an entry.
cp "$HERE/scripts/quality/lint/switch-rule-forms.json" "$WORK/a"; cp "$WORK/a" "$WORK/b"
cp "$HERE/scripts/monitoring/differing-switch-forms.txt" "$WORK/list"
check "the shipped list is read, and against an identical copy it is refused" "1 1" "$(run) $(says 'take the line off')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
