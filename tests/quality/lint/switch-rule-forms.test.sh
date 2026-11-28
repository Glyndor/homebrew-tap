#!/usr/bin/env bash
# The forms a job may carry are a contract about the workflows of THIS
# repository: every entry names a workflow and a job of it. An entry that
# names a workflow this repository does not have, or a job that is not in it,
# is documentation of something that does not exist, and the rule that reads
# the forms cannot tell it from a real one: it never looks up an entry whose
# job is absent, so the entry says nothing and hides a workflow that was
# renamed or removed.
#
# The checker is shown to refuse a planted violation first, and then reads the
# forms of this repository.
#
# Requires: bash, python3 with PyYAML.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FORMS="$HERE/scripts/quality/lint/switch-rule-forms.json"
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

# problems <forms file> <repository root>: one line per entry that names
# something the repository does not have, and nothing when every entry does.
problems() {
	python3 -I - "$1" "$2" <<'PY'
import json
import os
import sys

import yaml

forms_path, root = sys.argv[1], sys.argv[2]
try:
    with open(forms_path, encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, ValueError) as error:
    print(f"the forms cannot be read: {error}")
    sys.exit(0)


def jobs_of(name):
    """The jobs of a workflow, or None when it is not a workflow of the tree."""
    path = os.path.join(root, ".github", "workflows", name)
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            spec = yaml.safe_load(handle) or {}
    except (OSError, yaml.YAMLError) as error:
        print(f"{name}: cannot be read as a workflow: {error}")
        return None
    jobs = spec.get("jobs") or {}
    return set(jobs) if isinstance(jobs, dict) else set()


def name_of(entry):
    return str(entry.get("file", "")).rsplit("/", 1)[-1]


found = []
for section in ("conditional_jobs", "step_conditions"):
    for entry in data.get(section) or []:
        name = name_of(entry)
        jobs = jobs_of(name)
        if jobs is None:
            found.append(f"{section}: {entry.get('file')} is not a workflow of this repository")
            continue
        if str(entry.get("job", "")) not in jobs:
            found.append(f"{section}: {entry.get('file')} has no job `{entry.get('job')}`")
for entry in data.get("needs_the_gate") or []:
    name = name_of(entry)
    jobs = jobs_of(name)
    if jobs is None:
        found.append(f"needs_the_gate: {entry.get('file')} is not a workflow of this repository")
        continue
    for key in ("job", "gate"):
        if str(entry.get(key, "")) not in jobs:
            found.append(f"needs_the_gate: {entry.get('file')} has no job `{entry.get(key)}`")
for line in found:
    print(line)
PY
}

# --- planted violations -------------------------------------------------------
plant() { # <name>: a tree with one workflow and one form that names it
	local d="$WORK/$1"
	mkdir -p "$d/.github/workflows" "$d/scripts/quality/lint"
	printf 'jobs:\n  real:\n    runs-on: ubuntu-26.04\n    steps:\n      - run: true\n' >"$d/.github/workflows/real.yml"
	printf '%s\n' "$2" >"$d/scripts/quality/lint/switch-rule-forms.json"
	printf '%s' "$d"
}

GOOD='{"conditional_jobs": [{"file": ".github/workflows/real.yml", "job": "real", "reusable": null, "forms": [], "why": "x"}]}'
NOFILE='{"conditional_jobs": [{"file": ".github/workflows/gone.yml", "job": "real", "reusable": null, "forms": [], "why": "x"}]}'
NOJOB='{"conditional_jobs": [{"file": ".github/workflows/real.yml", "job": "ghost", "reusable": null, "forms": [], "why": "x"}]}'
NOSTEP='{"step_conditions": [{"file": ".github/workflows/real.yml", "job": "ghost", "ifs": ["x"]}]}'
NOGATE='{"needs_the_gate": [{"file": ".github/workflows/real.yml", "job": "real", "gate": "ghost"}]}'

D="$(plant good "$GOOD")"
check "an entry that names a workflow and a job of it is accepted" "" "$(problems "$D/scripts/quality/lint/switch-rule-forms.json" "$D")"
D="$(plant nofile "$NOFILE")"
check "an entry that names a workflow this repository does not have is reported" \
	"conditional_jobs: .github/workflows/gone.yml is not a workflow of this repository" \
	"$(problems "$D/scripts/quality/lint/switch-rule-forms.json" "$D")"
D="$(plant nojob "$NOJOB")"
check "an entry that names a job the workflow does not have is reported" \
	"conditional_jobs: .github/workflows/real.yml has no job \`ghost\`" \
	"$(problems "$D/scripts/quality/lint/switch-rule-forms.json" "$D")"
D="$(plant nostep "$NOSTEP")"
check "a step condition of a job that is not there is reported" \
	"step_conditions: .github/workflows/real.yml has no job \`ghost\`" \
	"$(problems "$D/scripts/quality/lint/switch-rule-forms.json" "$D")"
D="$(plant nogate "$NOGATE")"
check "a gate that is not a job of the workflow is reported" \
	"needs_the_gate: .github/workflows/real.yml has no job \`ghost\`" \
	"$(problems "$D/scripts/quality/lint/switch-rule-forms.json" "$D")"

# --- the forms of this repository ----------------------------------------------
check "every entry of the forms names a workflow and a job of this repository" "" \
	"$(problems "$FORMS" "$HERE")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
