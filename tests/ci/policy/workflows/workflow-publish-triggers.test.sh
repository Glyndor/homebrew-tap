#!/usr/bin/env bash
# Pin the exact event set for workflows that publish with a write-capable token.
#
# update.yml mints glyndor-updater's App token and commits the rendered files to main.
# A PR event would check out revision-controlled code in that credentialed job.
# Scan parsed workflow data (not comments) so future publishers enter this rule.
# Requires: python3 with PyYAML (tests.yml installs python3-yaml).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/live"

pass=0
fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1)); echo "ok    $1"
	else
		fail=$((fail + 1)); echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
	fi
}

# Print one diagnostic per missing/extra trigger. YAML 1.1 may decode bare `on`
# as True; GitHub's accepted map, list and scalar forms normalize to a set here.
violations() { # $1 = workflows directory
	python3 -I - "$1" <<'PY'
import os, sys, yaml

root = sys.argv[1]
expected = {"update.yml": {"schedule", "workflow_dispatch", "repository_dispatch"}}
found = set()
for name in sorted(os.listdir(root)):
    if not name.endswith((".yml", ".yaml")):
        continue
    path = os.path.join(root, name)
    try:
        with open(path, encoding="utf-8") as stream:
            doc = yaml.safe_load(stream)
    except (OSError, yaml.YAMLError) as exc:
        print(f"{name}: YAML unreadable: {exc}")
        continue
    if not isinstance(doc, dict):
        continue
    jobs = doc.get("jobs", {})
    text = repr(jobs)
    publisher = "actions/create-github-app-token@" in text or "createCommitOnBranch" in text
    if not publisher:
        continue
    found.add(name)
    on = doc.get(True, doc.get("on"))
    if isinstance(on, dict):
        triggers = {str(key) for key in on}
    elif isinstance(on, (list, tuple)):
        triggers = {str(item) for item in on}
    elif isinstance(on, str):
        triggers = {on}
    else:
        print(f"{name}: on: must be a trigger map, list or scalar")
        continue
    allowed = expected.get(name)
    if allowed is None:
        print(f"{name}: publishing workflow has no exact trigger policy")
        continue
    for trigger in sorted(triggers - allowed):
        print(f"{name}: unexpected trigger {trigger}")
    for trigger in sorted(allowed - triggers):
        print(f"{name}: missing required trigger {trigger}")
for name in sorted(set(expected) - found):
    print(f"{name}: expected publishing workflow not found")
PY
}

cp "$HERE/.github/workflows/update.yml" "$WORK/live/update.yml"
msg="$(violations "$WORK/live")"
check "the live publisher has exactly its three documented triggers" "" "$msg"

# Each plant starts from an independent copy. Compare bytes before running the
# checker: an inert edit cannot count as evidence that the guard caught anything.
for trigger in pull_request pull_request_target workflow_run push; do
	case_dir="$WORK/$trigger"
	mkdir -p "$case_dir"
	cp "$HERE/.github/workflows/update.yml" "$case_dir/update.yml"
	cp "$case_dir/update.yml" "$case_dir/before"
	python3 - "$case_dir/update.yml" "$trigger" <<'PY'
import sys
path, trigger = sys.argv[1:]
source = open(path, encoding="utf-8").read()
needle = "  workflow_dispatch:\n"
assert source.count(needle) == 1, "expected unique map trigger insertion point"
open(path, "w", encoding="utf-8").write(source.replace(needle, needle + f"  {trigger}:\n", 1))
PY
	if diff -q "$case_dir/before" "$case_dir/update.yml" >/dev/null; then
		echo "SABOTAGE INERT: $trigger did not change update.yml"
		fail=$((fail + 1))
	else
		echo "SABOTAGE APPLIED: added $trigger to update.yml"
		msg="$(violations "$case_dir")"
		printf '%s\n' "$msg"
		check "$trigger plant is rejected by name" "1" "$(printf '%s\n' "$msg" | grep -F "unexpected trigger $trigger" >/dev/null && echo 1 || echo 0)"
	fi
done

# A different unexpected event proves this is an exact-set check, not merely a
# blacklist of the four currently dangerous names.
extra="$WORK/extra"
mkdir -p "$extra"
cp "$HERE/.github/workflows/update.yml" "$extra/update.yml"
python3 - "$extra/update.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
n = "  workflow_dispatch:\n"
assert s.count(n) == 1
open(p, "w", encoding="utf-8").write(s.replace(n, n + "  issues:\n", 1))
PY
msg="$(violations "$extra")"
printf '%s\n' "$msg"
check "an unlisted event is also rejected" "1" "$(printf '%s\n' "$msg" | grep -F 'unexpected trigger issues' >/dev/null && echo 1 || echo 0)"

# Exercise map/list/scalar normalization with small credentialed workflow docs.
for form in map list scalar; do
	shape="$WORK/shape-$form"
	mkdir -p "$shape"
	case "$form" in
		map) on='  schedule:\n  workflow_dispatch:\n  repository_dispatch:\n' ;;
		list) on='  - schedule\n  - workflow_dispatch\n  - repository_dispatch\n' ;;
		scalar) on='  schedule\n' ;;
	esac
	{
		printf 'on:\n%b' "$on"
		printf 'jobs:\n  publish:\n    steps:\n      - uses: actions/create-github-app-token@v3\n'
	} > "$shape/update.yml"
	msg="$(violations "$shape")"
	if [ "$form" = scalar ]; then
		check "scalar trigger syntax is parsed and compared exactly" "1" "$(printf '%s\n' "$msg" | grep -F 'missing required trigger workflow_dispatch' >/dev/null && echo 1 || echo 0)"
	else
		check "$form trigger syntax passes the same exact set" "" "$msg"
	fi
done

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
