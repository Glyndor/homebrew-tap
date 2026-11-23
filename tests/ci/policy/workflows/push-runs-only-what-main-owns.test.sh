#!/usr/bin/env bash
# A workflow that runs suites does not run on a push to main, and a workflow that does run
# on a push has its reason and runs no suite that a pull request already ran.
#
# What lands on main came through a pull request, and the ruleset requires the branch up to
# date, the aggregator and no bypass, so the tree that lands is the tree the pull request
# tested. A push to main that ran the same suites again would spend the minutes of every
# merge to tell nothing new. What does exist only because it is on main stays on push, each
# with its reason, in the exact list below:
#
#   * a workflow with a `push` trigger is in the list, and a workflow in the list has the
#     trigger, so a reason does not outlive the workflow it was written for;
#   * no workflow with a `pull_request` trigger and a job that runs a suite (a call of
#     the shell, line-limit, workflow-lint or empty-diff reusables, or a step that runs
#     a file of `tests/`) has a `push` trigger;
#   * a workflow in the list runs no such job.
#
# The checker is shown to refuse each form on planted workflows first.
# Requires: bash, python3 with PyYAML.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
python3 -I - "$HERE" <<'PY'
import re
import sys
import tempfile
from pathlib import Path

import yaml

passed = failed = 0
# workflow -> why it runs on a push to main.
ON_PUSH = {
    "dco-on-main.yml": "the sign-off of the commit that GitHub makes when it squashes a pull request exists only on main",
    "generated-on-main.yml": "the updater app bypasses the ruleset and pushes the formulae with no pull request, so what it pushed is judged here",
    "pushes-to-main.yml": "a commit that reached main with no pull request and that is not what the updater writes is judged by nobody, so this reads every push",
    "audit.yml": "the updater app bypasses the ruleset and pushes the formulae with no pull request, so what it pushed is audited here",
}
# The workflows of the list that judge what the updater app writes: their `paths` have to cover everything
# the app commits, read from the step of update.yml that commits it.
GENERATED = ("generated-on-main.yml", "audit.yml")
# The workflow that judges every push: it has no filter of paths, and it takes its judge, the
# script and the list, from the commit that main had (`github.event.before`) in every checkout,
# never from what was pushed, so a push cannot change how it is judged.
GUARD = "pushes-to-main.yml"
BEFORE = "${{ github.event.before }}"
UPDATER = ("update.yml", "commit", "Commit the update to main (GitHub-signed)")
SUITE_REUSABLES = ("reusable-shell-ci.yml", "reusable-line-limit.yml", "reusable-workflow-lint.yml", "reusable-empty-diff.yml")
TESTS_RE = re.compile(r"(^|[\s;&|(])(bash\s+)?\./tests/\S+\.test\.sh")


def triggers(spec):
    on = spec.get("on", spec.get(True)) or {}
    if isinstance(on, str):
        return {on}
    if isinstance(on, list):
        return set(on)
    return set(on)


def runs_suites(spec):
    for job in (spec.get("jobs") or {}).values():
        if not isinstance(job, dict):
            continue
        if str(job.get("uses", "")).rsplit("/", 1)[-1].split("@")[0] in SUITE_REUSABLES:
            return True
        for step in job.get("steps") or []:
            if isinstance(step, dict) and TESTS_RE.search(str(step.get("run", ""))):
                return True
    return False


def problems(folder, on_push):
    found = []
    seen = set()
    for path in sorted(Path(folder).glob("*.y*ml")):
        spec = yaml.safe_load(path.read_text()) or {}
        if path.name.startswith("reusable-"):
            continue
        seen.add(path.name)
        on = triggers(spec)
        suites = runs_suites(spec)
        if "push" in on and path.name not in on_push:
            found.append(f"{path.name}: runs on a push to main and no reason is written for it")
        if "push" in on and path.name in on_push and suites:
            found.append(f"{path.name}: is listed for a push and runs a suite a pull request ran")
        if "push" in on and "pull_request" in on and suites:
            found.append(f"{path.name}: runs suites on a pull request and again on a push to main")
        if "push" not in on and path.name in on_push:
            found.append(f"{path.name}: is listed for a push and has no push trigger, so the entry goes")
    for name in sorted(set(on_push) - seen):
        found.append(f"{name}: is listed for a push and does not exist, so the entry goes")
    return found


def written(folder):
    """The paths the updater app commits: the pathspecs after `--` in the step that commits."""
    spec = yaml.safe_load((Path(folder) / UPDATER[0]).read_text()) or {}
    for step in (spec.get("jobs", {}).get(UPDATER[1], {}).get("steps") or []):
        if step.get("name") == UPDATER[2]:
            return sorted(set(re.findall(r"(?:^|\s)--\s+([A-Za-z0-9_][A-Za-z0-9_./-]*)", step.get("run", ""))))
    return None


def path_problems(folder, generated):
    found = []
    paths = written(folder)
    if not paths:
        return [f"{UPDATER[0]}: the step that commits the update has no pathspec to read, so the paths cannot be held against it"]
    for name in generated:
        spec = yaml.safe_load((Path(folder) / name).read_text()) or {}
        on = spec.get("on", spec.get(True)) or {}
        have = ((on.get("push") or {}).get("paths") if isinstance(on, dict) else None) or []
        for path in paths:
            if f"{path}/**" not in have:
                found.append(f"{name}: the paths of its push do not cover {path}, which the updater app commits")
        for path in have:
            if path.rstrip("/*") not in paths:
                found.append(f"{name}: the paths of its push name {path}, which the updater app does not commit")
    return found


def guard_problems(folder):
    found = []
    path = Path(folder) / GUARD
    if not path.exists():
        return [f"{GUARD}: the guard of every push does not exist"]
    spec = yaml.safe_load(path.read_text()) or {}
    on = spec.get("on", spec.get(True)) or {}
    push = on.get("push") if isinstance(on, dict) else None
    if not isinstance(push, dict) or "paths" in push or "paths-ignore" in push:
        found.append(f"{GUARD}: has a filter of paths, and a push outside them would not be read")
    for job_id, job in (spec.get("jobs") or {}).items():
        for step in job.get("steps") or []:
            if str(step.get("uses", "")).startswith("actions/checkout@") and (step.get("with") or {}).get("ref") != BEFORE:
                found.append(f"{GUARD}: job `{job_id}` checks out something other than the commit main had, so a push could change its judge")
    return found


def check(label, expected, actual):
    global passed, failed
    if expected == actual:
        passed += 1
        print(f"ok    {label}")
    else:
        failed += 1
        print(f"FAIL  {label}: expected {expected!r}, got {actual!r}")


def planted(files, on_push=()):
    with tempfile.TemporaryDirectory() as folder:
        for name, body in files.items():
            (Path(folder) / name).write_text(body)
        return problems(folder, dict.fromkeys(on_push, "x"))


PR = "on:\n  pull_request:\n"
PUSH = "on:\n  push:\n    branches: [main]\n"
BOTH = "on:\n  pull_request:\n  push:\n    branches: [main]\n"
CALL = "jobs:\n  shell:\n    uses: ./.github/workflows/reusable-shell-ci.yml\n"
RUN = "jobs:\n  j:\n    runs-on: x\n    steps:\n      - run: ./tests/a/b.test.sh\n"
PLAIN = "jobs:\n  j:\n    runs-on: x\n    steps:\n      - run: echo hi\n"

check("a workflow that runs suites on a pull request only is accepted", [], planted({"w.yml": PR + CALL}))
check("a workflow that runs suites on a pull request and on a push is refused",
      ["w.yml: runs on a push to main and no reason is written for it", "w.yml: runs suites on a pull request and again on a push to main"],
      planted({"w.yml": BOTH + CALL}))
check("a step that runs a file of tests/ counts as a suite",
      ["w.yml: runs on a push to main and no reason is written for it", "w.yml: runs suites on a pull request and again on a push to main"],
      planted({"w.yml": BOTH + RUN}))
check("the line-limit reusable counts as a suite",
      ["w.yml: runs on a push to main and no reason is written for it", "w.yml: runs suites on a pull request and again on a push to main"],
      planted({"w.yml": BOTH + "jobs:\n  l:\n    uses: ./.github/workflows/reusable-line-limit.yml\n"}))
check("a push with no reason written is refused", ["w.yml: runs on a push to main and no reason is written for it"],
      planted({"w.yml": PUSH + PLAIN}))
check("a push with its reason is accepted", [], planted({"w.yml": PUSH + PLAIN}, ["w.yml"]))
check("a listed workflow that runs a suite is refused", ["w.yml: is listed for a push and runs a suite a pull request ran"],
      planted({"w.yml": PUSH + CALL}, ["w.yml"]))
check("a listed workflow with no push trigger is refused", ["w.yml: is listed for a push and has no push trigger, so the entry goes"],
      planted({"w.yml": PR + PLAIN}, ["w.yml"]))
check("a listed workflow that does not exist is refused", ["gone.yml: is listed for a push and does not exist, so the entry goes"],
      planted({"w.yml": PR + PLAIN}, ["gone.yml"]))
check("a reusable workflow is not read as a workflow that runs", [], planted({"reusable-x.yml": BOTH + CALL}))
check("a workflow with a schedule and suites is accepted", [], planted({"w.yml": "on:\n  schedule:\n    - cron: '0 0 * * 1'\n" + CALL}))
check("a push written as a list is read", ["w.yml: runs on a push to main and no reason is written for it"],
      planted({"w.yml": "on: [push]\n" + PLAIN}))
check("a push written as a word is read", ["w.yml: runs on a push to main and no reason is written for it"],
      planted({"w.yml": "on: push\n" + PLAIN}))

UPD = "name: U\non: workflow_dispatch\njobs:\n  commit:\n    runs-on: x\n    steps:\n      - name: Commit the update to main (GitHub-signed)\n        run: |\n          git diff -z --name-only -- Formula\n          git ls-files -z -o -- Formula\n"
GEN = "on:\n  push:\n    branches: [main]\n    paths:\n      - Formula/**\n" + PLAIN


def planted_paths(files):
    with tempfile.TemporaryDirectory() as folder:
        for name, body in files.items():
            (Path(folder) / name).write_text(body)
        return path_problems(folder, ["g.yml"])


check("paths that cover what the app commits are accepted", [], planted_paths({"update.yml": UPD, "g.yml": GEN}))
check("a path the app commits and the push does not cover is refused",
      ["g.yml: the paths of its push do not cover Casks, which the updater app commits"],
      planted_paths({"update.yml": UPD.replace("-- Formula\n          git ls", "-- Formula\n          git diff -- Casks\n          git ls"), "g.yml": GEN}))
check("a path the push names and the app does not commit is refused",
      ["g.yml: the paths of its push name docs/**, which the updater app does not commit"],
      planted_paths({"update.yml": UPD, "g.yml": GEN.replace("      - Formula/**\n", "      - Formula/**\n      - docs/**\n")}))
check("a push with no paths is refused", ["g.yml: the paths of its push do not cover Formula, which the updater app commits"],
      planted_paths({"update.yml": UPD, "g.yml": "on:\n  push:\n    branches: [main]\n" + PLAIN}))
check("an update with no step that commits is refused",
      ["update.yml: the step that commits the update has no pathspec to read, so the paths cannot be held against it"],
      planted_paths({"update.yml": "name: U\non: workflow_dispatch\njobs:\n  commit:\n    runs-on: x\n    steps:\n      - run: true\n", "g.yml": GEN}))

live = problems(Path(sys.argv[1]) / ".github" / "workflows", ON_PUSH)
GUARD_OK = "on:\n  push:\n    branches: [main]\njobs:\n  guard:\n    runs-on: x\n    steps:\n      - uses: actions/checkout@abc\n        with:\n          ref: ${{ github.event.before }}\n"


def planted_guard(body):
    with tempfile.TemporaryDirectory() as folder:
        (Path(folder) / GUARD).write_text(body)
        return guard_problems(folder)


check("a guard that reads every push from the commit main had is accepted", [], planted_guard(GUARD_OK))
check("a guard with a filter of paths is refused", [f"{GUARD}: has a filter of paths, and a push outside them would not be read"],
      planted_guard(GUARD_OK.replace("    branches: [main]\n", "    branches: [main]\n    paths: [Formula/**]\n")))
check("a guard that checks out the pushed commit is refused",
      [f"{GUARD}: job `guard` checks out something other than the commit main had, so a push could change its judge"],
      planted_guard(GUARD_OK.replace("          ref: ${{ github.event.before }}\n", "")))
check("a guard that checks out the head of the push is refused",
      [f"{GUARD}: job `guard` checks out something other than the commit main had, so a push could change its judge"],
      planted_guard(GUARD_OK.replace("github.event.before", "github.sha")))
check("a guard that is not there is refused", [f"{GUARD}: the guard of every push does not exist"], planted_guard("x: 1\n") if False else guard_problems("/nonexistent"))
check("the workflows of this repository run on a push only for the reasons listed", [], live)
check("the guard of every push reads no path filter and judges from the commit main had", [], guard_problems(Path(sys.argv[1]) / ".github" / "workflows"))
check("the paths of the workflows that judge what the app pushes cover what it commits",
      [], path_problems(Path(sys.argv[1]) / ".github" / "workflows", GENERATED))

print()
print(f"passed: {passed}  failed: {failed}")
print(f"DONE {Path('push-runs-only-what-main-owns.test.sh')} {passed} {failed}")
sys.exit(1 if failed else 0)
PY
