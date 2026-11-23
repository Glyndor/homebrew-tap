#!/usr/bin/env bash
# The workflow that installs the formulae from the tap covers every formula of the tap, on macOS and on Linux, and
# is shaped to be read as a test of the published tap and not of a pull request.
#
#   * the formulae of its matrix are the files of Formula/, both ways: a formula added to the tap and not to the
#     matrix is a formula nobody installs, and one left in the matrix after it left the tap is a job that fails;
#   * the matrix has a macOS runner and a Linux runner, and the Linux one names its image;
#   * it runs on dispatch and on a push that changes Formula/ and nothing else, and on no pull
#     request (its cron comes with the watcher that reads it, in a pull request after this one): it reads the tap as published, and a pull request has not published anything;
#   * its steps use only actions of GitHub (`actions/`), pinned to a commit, and its checkout keeps the history
#     the previous formula is found in and keeps no credential;
#   * its job has a bound, and a leg that fails does not stop the other.
# Every case is planted first, so a checker that read nothing would not pass them.
# Requires: bash, python3 with PyYAML.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
python3 -I - "$HERE" <<'PY'
import re
import sys
import tempfile
from pathlib import Path

import yaml

root = Path(sys.argv[1])
passed = failed = 0
NAME = "install-from-the-tap.yml"


def problems(repo):
    found = []
    spec = yaml.safe_load((repo / ".github/workflows" / NAME).read_text()) or {}
    on = spec.get("on", spec.get(True)) or {}
    job = (spec.get("jobs") or {}).get("install") or {}
    matrix = (job.get("strategy") or {}).get("matrix") or {}
    formulae = sorted(p.stem for p in (repo / "Formula").glob("*.rb"))
    if sorted(matrix.get("formula") or []) != formulae:
        found.append(f"the matrix installs {sorted(matrix.get('formula') or [])} and the tap has {formulae}")
    runners = [str(r) for r in matrix.get("runner") or []]
    if not any(r.startswith("macos") for r in runners):
        found.append("the matrix has no macOS runner")
    linux = [r for r in runners if r.startswith("ubuntu")]
    if not linux:
        found.append("the matrix has no Linux runner")
    for r in linux:
        if r.endswith("-latest"):
            found.append(f"the Linux runner {r} is a floating label")
    if job.get("runs-on") != "${{ matrix.runner }}":
        found.append("the job does not run on the runner of its leg")
    if (job.get("strategy") or {}).get("fail-fast") is not False:
        found.append("a leg that fails stops the other: fail-fast is not false")
    if not isinstance(job.get("timeout-minutes"), int):
        found.append("the job has no bound of its own")
    for bad in sorted({"pull_request", "pull_request_target"} & set(on)):
        found.append(f"it runs on {bad}")
    for need in ("workflow_dispatch", "push"):
        if need not in on:
            found.append(f"it does not run on {need}")
    push = on.get("push") or {}
    if isinstance(push, dict) and push.get("paths") != ["Formula/**"]:
        found.append(f"its push runs for {push.get('paths')} and not for Formula/** alone")
    for step in job.get("steps") or []:
        uses = str(step.get("uses", ""))
        if uses and not re.fullmatch(r"actions/[a-z-]+@[0-9a-f]{40}( # .*)?", uses):
            found.append(f"a step uses {uses}, which is not an action of GitHub pinned to a commit")
        if uses.startswith("actions/checkout"):
            with_ = step.get("with") or {}
            if with_.get("fetch-depth") != 0:
                found.append("the checkout does not keep the history, so the commit before the formula cannot be found")
            if with_.get("persist-credentials") is not False:
                found.append("the checkout keeps its credential")
    return found


def plant(formulae, mutate=lambda spec: None, on=None):
    with tempfile.TemporaryDirectory() as d:
        repo = Path(d)
        (repo / "Formula").mkdir()
        (repo / ".github/workflows").mkdir(parents=True)
        for f in formulae:
            (repo / "Formula" / f"{f}.rb").write_text("class X < Formula\nend\n")
        spec = {
            "on": on or {"workflow_dispatch": None, "push": {"branches": ["main"], "paths": ["Formula/**"]}},
            "jobs": {"install": {
                "strategy": {"fail-fast": False, "matrix": {"runner": ["macos-latest", "ubuntu-26.04"], "formula": ["podup"]}},
                "runs-on": "${{ matrix.runner }}", "timeout-minutes": 30,
                "steps": [{"uses": "actions/checkout@" + "a" * 40 + " # v7", "with": {"persist-credentials": False, "fetch-depth": 0}}, {"run": "true"}]}},
        }
        mutate(spec)
        (repo / ".github/workflows" / NAME).write_text(yaml.safe_dump(spec, sort_keys=False))
        return problems(repo)


def check(label, expected, actual):
    global passed, failed
    if expected == actual:
        print(f"ok    {label}")
        passed += 1
    else:
        print(f"FAIL  {label}\n        expected: {expected}\n        actual:   {actual}")
        failed += 1


def matrix(spec): return spec["jobs"]["install"]["strategy"]["matrix"]
def job(spec): return spec["jobs"]["install"]


check("a workflow that installs every formula on both systems passes", [], plant(["podup"]))
check("a formula of the tap that the matrix does not install is refused", ["the matrix installs ['podup'] and the tap has ['epistle', 'podup']"], plant(["podup", "epistle"]))
check("a formula left in the matrix after it left the tap is refused", ["the matrix installs ['podup'] and the tap has []"], plant([]))
check("a matrix with no macOS runner is refused", ["the matrix has no macOS runner"], plant(["podup"], lambda s: matrix(s).update(runner=["ubuntu-26.04"])))
check("a matrix with no Linux runner is refused", ["the matrix has no Linux runner"], plant(["podup"], lambda s: matrix(s).update(runner=["macos-latest"])))
check("a Linux runner that is a floating label is refused", ["the Linux runner ubuntu-latest is a floating label"], plant(["podup"], lambda s: matrix(s).update(runner=["macos-latest", "ubuntu-latest"])))
check("a job that does not run on the runner of its leg is refused", ["the job does not run on the runner of its leg"], plant(["podup"], lambda s: job(s).update({"runs-on": "ubuntu-26.04"})))
check("a leg that stops the other is refused", ["a leg that fails stops the other: fail-fast is not false"], plant(["podup"], lambda s: job(s)["strategy"].update({"fail-fast": True})))
check("a job with no bound is refused", ["the job has no bound of its own"], plant(["podup"], lambda s: job(s).pop("timeout-minutes")))
check("a run on a pull request is refused", ["it runs on pull_request"], plant(["podup"], on={"workflow_dispatch": None, "push": {"paths": ["Formula/**"]}, "pull_request": None}))
check("a run with no push is refused", ["it does not run on push", "its push runs for None and not for Formula/** alone"], plant(["podup"], on={"workflow_dispatch": None}))
check("a push for more than the formulae is refused", ["its push runs for ['Formula/**', 'docs/**'] and not for Formula/** alone"], plant(["podup"], on={"workflow_dispatch": None, "push": {"paths": ["Formula/**", "docs/**"]}}))
check("a step of a third party is refused", ["a step uses someone/action@" + "b" * 40 + ", which is not an action of GitHub pinned to a commit"], plant(["podup"], lambda s: job(s)["steps"].append({"uses": "someone/action@" + "b" * 40})))
check("an action of GitHub pinned to a tag is refused", ["a step uses actions/cache@v4, which is not an action of GitHub pinned to a commit"], plant(["podup"], lambda s: job(s)["steps"].append({"uses": "actions/cache@v4"})))
check("a checkout without the history is refused", ["the checkout does not keep the history, so the commit before the formula cannot be found"], plant(["podup"], lambda s: job(s)["steps"][0]["with"].update({"fetch-depth": 1})))
check("a checkout that keeps its credential is refused", ["the checkout keeps its credential"], plant(["podup"], lambda s: job(s)["steps"][0]["with"].update({"persist-credentials": True})))
check("the live workflow covers the tap", [], problems(root))
print(f"\n{passed} passed, {failed} failed")
print(f"DONE install-covers-the-tap.test.sh {passed} {failed}")
sys.exit(1 if failed else 0)
PY
