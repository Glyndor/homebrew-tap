#!/usr/bin/env bash
# What judges a push to main is the commit main HAD, and nothing of what was pushed runs in the job that judges it.
#
#   * generated-on-main.yml: in every job that judges what the updater pushed, the first step is the checkout of
#     `github.event.before`, with no path of its own, and the pushed data (the formulae or the manifests, nothing
#     else) comes in after it, through git, from `github.sha`; no step checks out anything else, and none runs a script
#     of a folder the pushed commit could have filled; the report job checks nothing out and runs no script of the repository;
#   * pushes-to-main.yml: the first step of the guard is code written in the workflow that asks GitHub whether the guard
#     passed on the commit main had, before anything is checked out; the report job checks nothing out and runs no script.
#
# Each rule is shown to refuse the form that breaks it, on a copy of the workflow with that one change.
# Requires: bash, python3 with PyYAML.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
python3 -I - "$HERE" <<'PY'
import copy
import re
import sys
from pathlib import Path

import yaml

here = Path(sys.argv[1])
passed = failed = 0


def check(description, expected, actual):
    global passed, failed
    if expected == actual:
        print("ok    " + description)
        passed += 1
    else:
        print("FAIL  " + description)
        print("        expected:", expected)
        print("        actual:  ", actual)
        failed += 1


def load(name):
    return yaml.safe_load((here / ".github/workflows" / name).read_text())


def runs_repo_code(step):
    run = step.get("run", "")
    return bool(re.search(r"(^|[\s;&|(])(\./|bash |sh |python3? )|scripts/|\btests/", run))


def generated_problems(doc):
    found = []
    data_dir = doc[True]["push"]["paths"][0].split("/")[0] if True in doc else doc["on"]["push"]["paths"][0].split("/")[0]
    for name, job in doc["jobs"].items():
        steps = job["steps"]
        if name == "report":
            if any("uses" in s for s in steps):
                found.append("report: checks something out or uses an action")
            if any(runs_repo_code(s) for s in steps):
                found.append("report: runs a script of the repository")
            continue
        first = steps[0]
        if not str(first.get("uses", "")).startswith("actions/checkout@") or first.get("with", {}).get("ref") != "${{ github.event.before }}":
            found.append(f"{name}: the first step is not the checkout of the commit main had")
        if "path" in first.get("with", {}):
            found.append(f"{name}: the commit main had is checked out into a folder of its own, so the scripts run from somewhere else")
        checkouts = [s for s in steps if "uses" in s]
        if len(checkouts) != 1:
            found.append(f"{name}: {len(checkouts)} steps check something out, one is the commit main had")
        data = [s for s in steps if "git checkout" in s.get("run", "")]
        if len(data) != 1 or f'rm -rf {data_dir}\n' not in data[0]["run"]:
            found.append(f"{name}: what the commit main had holds of {data_dir}/ is not taken away before the pushed one comes in, so a file the push deleted is still judged")
        if len(data) != 1 or f'git checkout "$AFTER" -- {data_dir}' not in data[0]["run"] or "${{ github.sha }}" != data[0].get("env", {}).get("AFTER"):
            found.append(f"{name}: what was pushed does not come in as {data_dir}/ and only that, from github.sha, with git")
        for s in steps:
            if "github.sha" in str(s.get("with", {})) or "trusted" in str(s):
                found.append(f"{name}: a step takes the pushed commit or a folder of the trusted one")
        position = steps.index(data[0]) if data else 0
        if any(runs_repo_code(s) for s in steps[:position + 1]):
            found.append(f"{name}: a script of the repository runs before the pushed data is in or while it comes in")
    return found


def push_problems(doc):
    found = []
    guard = doc["jobs"]["guard"]
    steps = guard["steps"]
    first = steps[0]
    if "uses" in first or runs_repo_code(first) or "check-runs" not in first.get("run", "") or "15368" not in first.get("run", ""):
        found.append("guard: the first step is not code of the workflow that asks GitHub whether the guard passed")
    if "${{ github.event.before }}" != first.get("env", {}).get("BEFORE"):
        found.append("guard: the first step does not ask about the commit main had")
    if guard.get("needs"):
        found.append("guard: a job in front of it")
    uses = [i for i, s in enumerate(steps) if "uses" in s]
    if uses != [1]:
        found.append("guard: the checkout is not the second step, once")
    report = doc["jobs"]["report"]
    if any("uses" in s or runs_repo_code(s) for s in report["steps"]):
        found.append("report: checks something out or runs a script of the repository")
    return found


gen = load("generated-on-main.yml")
push = load("pushes-to-main.yml")
check("generated-on-main.yml is judged from the commit main had, and the pushed data comes in as data", [], generated_problems(gen))
check("pushes-to-main.yml asks whether the guard passed on the commit main had before anything of it runs", [], push_problems(push))

jobs = [n for n in gen["jobs"] if n != "report"]
doc = copy.deepcopy(gen)
doc["jobs"][jobs[0]]["steps"].insert(0, {"name": "x", "run": "bash ./scripts/artifacts/check-products-consistent.sh"})
check("a script of the repository run before the checkout of the commit main had is refused", True,
      any("first step" in p for p in generated_problems(doc)))
doc = copy.deepcopy(gen)
doc["jobs"][jobs[0]]["steps"][0]["with"]["ref"] = "${{ github.sha }}"
check("the first checkout taking the pushed commit is refused", True, any("first step" in p for p in generated_problems(doc)))
doc = copy.deepcopy(gen)
doc["jobs"][jobs[0]]["steps"][0]["with"]["path"] = "trusted"
check("the commit main had in a folder of its own, so that the pushed tree is the one that runs, is refused", True,
      any("folder of its own" in p for p in generated_problems(doc)))
doc = copy.deepcopy(gen)
doc["jobs"][jobs[0]]["steps"].append({"uses": "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "with": {"path": "pushed"}})
check("a second checkout is refused", True, any("steps check something out" in p for p in generated_problems(doc)))
doc = copy.deepcopy(gen)
doc["jobs"][jobs[0]]["steps"][1]["run"] = doc["jobs"][jobs[0]]["steps"][1]["run"].replace('git checkout "$AFTER" -- ', 'git checkout "$AFTER" -- . #')
check("pushed data that is the whole tree, not only the data folder, is refused", True, any("only that" in p for p in generated_problems(doc)))
doc = copy.deepcopy(gen)
doc["jobs"][jobs[0]]["steps"][1]["run"] = doc["jobs"][jobs[0]]["steps"][1]["run"].replace("rm -rf ", "true ")
check("pushed data that comes in over what main had, with no clearing first, is refused", True, any("is not taken away" in p for p in generated_problems(doc)))
doc = copy.deepcopy(gen)
doc["jobs"]["report"]["steps"].insert(0, {"uses": "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"})
check("a report job that checks something out is refused", True, any("report" in p for p in generated_problems(doc)))
doc = copy.deepcopy(gen)
doc["jobs"]["report"]["steps"][0]["run"] += "\nbash ./scripts/monitoring/report-failure.sh x y"
check("a report job that runs a script of the repository is refused", True, any("report" in p for p in generated_problems(doc)))

doc = copy.deepcopy(push)
doc["jobs"]["guard"]["steps"].insert(0, doc["jobs"]["guard"]["steps"].pop(1))
check("the checkout of the commit main had before the question is refused", True, any("first step" in p for p in push_problems(doc)))
doc = copy.deepcopy(push)
doc["jobs"]["guard"]["steps"][0] = {"name": "x", "env": doc["jobs"]["guard"]["steps"][0]["env"], "run": "exit 0"}
check("a question that asks nothing is refused", True, any("first step" in p for p in push_problems(doc)))
doc = copy.deepcopy(push)
doc["jobs"]["guard"]["steps"][0]["env"]["BEFORE"] = "${{ github.sha }}"
check("a question about the pushed commit is refused", True, any("commit main had" in p for p in push_problems(doc)))
doc = copy.deepcopy(push)
doc["jobs"]["report"]["steps"].insert(0, {"uses": "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"})
check("a push report job that checks something out is refused", True, any("report" in p for p in push_problems(doc)))

print()
print(f"passed: {passed}  failed: {failed}")
print(f"DONE {Path(sys.argv[0]).name if sys.argv[0] != '-' else 'main-judges-from-the-commit-it-had.test.sh'} {passed} {failed}")
sys.exit(1 if failed else 0)
PY
