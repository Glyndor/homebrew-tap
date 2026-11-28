#!/usr/bin/env bash
#
# The forms the suites of the switch rule judge their planted trees by. Sourced, never run, and not named
# *.test.sh because it is not a suite. The suite that sources it names HERE, the root of the repository, and
# WORK, its scratch directory. It sets FORMS_MERGED and gives `with_forms <tree>`.
#
# Requires: python3 with PyYAML.
# shellcheck disable=SC2034 # the suites that source this read what it sets

# The forms the planted trees are judged by: those of the repository, and, for a job it does not
# list, the shapes only the suites plant (tests/fixtures/ci/switch-forms-planted.json). The
# repository's own list names its jobs alone, so a shape the rule has to be shown to honour lives
# there. A planted entry whose condition a job of this repository really carries is left out: that
# one is the repository's own to list, so dropping it from the list has to be seen.
FORMS_MERGED="$WORK/forms.json"
python3 -I - "$HERE/scripts/quality/lint/switch-rule-forms.json" \
	"$HERE/tests/fixtures/ci/switch-forms-planted.json" "$FORMS_MERGED" "$HERE" <<'PY' || exit 1
import json, os, sys

import yaml

real, planted, out, root = sys.argv[1:5]


def carried(section, entry):
    """Whether a job of this repository carries what the entry allows."""
    path = os.path.join(root, entry["file"])
    if not os.path.isfile(path):
        return False
    job = (yaml.safe_load(open(path, encoding="utf-8")).get("jobs") or {}).get(entry["job"])
    if job is None:
        return False
    if section == "conditional_jobs":
        return {k: job[k] for k in ("if", "needs") if k in job} in entry["forms"]
    if section == "step_conditions":
        return any(step.get("if") in entry["ifs"] for step in job.get("steps") or [])
    return False


data, extra = json.load(open(real)), json.load(open(planted))
keys = {"conditional_jobs": ("file", "job", "reusable"), "step_conditions": ("file", "job"),
        "needs_the_gate": ("file", "job")}
for section, key in keys.items():
    listed = {tuple(e[k] for k in key) for e in data[section]}
    data[section] += [e for e in extra[section]
                      if tuple(e[k] for k in key) not in listed and not carried(section, e)]
data["allowed_inputs"] = {**extra["allowed_inputs"], **data["allowed_inputs"]}
with open(out, "w") as handle:
    handle.write("{\n")
    for number, (name, value) in enumerate(data.items()):
        comma = "," if number < len(data) - 1 else ""
        if isinstance(value, list):
            items = ",\n".join("  " + json.dumps(v) for v in value)
            handle.write(f' {json.dumps(name)}: [\n{items}\n ]{comma}\n' if value else f' {json.dumps(name)}: []{comma}\n')
        else:
            handle.write(f" {json.dumps(name)}: {json.dumps(value)}{comma}\n")
    handle.write("}\n")
PY
with_forms() { mkdir -p "$1/scripts/quality/lint"; cp "$FORMS_MERGED" "$1/scripts/quality/lint/switch-rule-forms.json"; }
