#!/usr/bin/env bash
#
# Dependabot opens one pull request per group. The action that receives the app's
# private key has to be reviewed on its own, so when a workflow uses
# actions/create-github-app-token the config must give it a group of its own and
# keep it out of the broad one; every ecosystem entry must carry the labels the
# project filters on. This reads the live config and plants each way of getting it
# wrong.
#
# Requires: python3 with PyYAML (tests.yml installs python3-yaml).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
		echo "ok    $1"
	else
		fail=$((fail + 1))
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
	fi
}

verdict() { # $1 = dependabot.yml, $2 = "yes" when a workflow uses the app-token action
	python3 - "$1" "$2" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
uses_token = sys.argv[2] == "yes"
problems = []
ups = cfg.get("updates") or []
if not any(u.get("package-ecosystem") == "github-actions" for u in ups):
    problems.append("no github-actions entry")
for u in ups:
    labels = u.get("labels") or []
    if "type:deps" not in labels:
        problems.append("missing label type:deps")
    groups = u.get("groups") or {}
    tok = "actions/create-github-app-token"
    own = [n for n, g in groups.items() if tok in (g.get("patterns") or [])]
    broad = [n for n, g in groups.items() if "*" in (g.get("patterns") or [])]
    # The app-token action is a GitHub Action, so only that ecosystem is asked to
    # keep it in a group of its own; an entry for another ecosystem cannot hold it.
    if uses_token and u.get("package-ecosystem") == "github-actions":
        if not own:
            problems.append("the app-token action has no group of its own")
        for n in own:
            if list(groups[n].get("patterns") or []) != [tok]:
                problems.append("the app-token group holds more than the app-token action")
        for n in broad:
            if tok not in (groups[n].get("exclude-patterns") or []):
                problems.append("the broad group does not exclude the app-token action")
print("ok" if not problems else "; ".join(sorted(set(problems))))
PY
}

uses_token=no
grep -rqF 'actions/create-github-app-token@' "$HERE/.github/workflows" && uses_token=yes
check "the live config is sound" "ok" "$(verdict "$HERE/.github/dependabot.yml" "$uses_token")"

mkdir -p "$WORK/c"
python3 - "$HERE/.github/dependabot.yml" "$WORK/c" <<'PY'
import sys, yaml, copy
cfg = yaml.safe_load(open(sys.argv[1]))
def write(name, edit):
    c = copy.deepcopy(cfg)
    edit(c["updates"][0])
    yaml.safe_dump(c, open(f"{sys.argv[2]}/{name}.yml", "w"), sort_keys=False)
def no_own(u):
    u["groups"] = {k: v for k, v in u["groups"].items()
                   if "actions/create-github-app-token" not in (v.get("patterns") or [])}
def no_exclude(u):
    for g in u["groups"].values():
        g.pop("exclude-patterns", None)
def no_label(u):
    u["labels"] = [l for l in u["labels"] if l != "type:deps"]
write("no-own", no_own)
write("no-exclude", no_exclude)
def mixed(u):
    for g in u["groups"].values():
        if "actions/create-github-app-token" in (g.get("patterns") or []):
            g["patterns"] = ["actions/create-github-app-token", "actions/checkout"]
write("no-label", no_label)
write("mixed", mixed)
PY
if [ "$uses_token" = yes ]; then
	check "without a group of its own the app-token action is reported" \
		"the app-token action has no group of its own" "$(verdict "$WORK/c/no-own.yml" yes)"
	check "without the exclusion the broad group is reported" \
		"the broad group does not exclude the app-token action" "$(verdict "$WORK/c/no-exclude.yml" yes)"
	check "a group that mixes the app-token action with another is reported" \
		"the app-token group holds more than the app-token action" "$(verdict "$WORK/c/mixed.yml" yes)"
fi
check "a missing label is reported" "missing label type:deps" "$(verdict "$WORK/c/no-label.yml" no)"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
