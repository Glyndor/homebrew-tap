#!/usr/bin/env bash
# The check a pull request must pass is named by its job, and GitHub matches the
# name, not the workflow or the event that produced it. If two workflows, or one
# workflow on two events, both emit the same name, a green result from the one
# the pull request did not run can satisfy the requirement.
#
#   * no check name is produced by two workflow files. A job that calls a local
#     reusable produces `<job id> / <inner job name>` for each job inside it;
#   * a name produced by a workflow that runs on both `push` and `pull_request`
#     is safe only because the two events can never be about the same commit
#     here: a push trigger names the one branch `main`, and a pull request is
#     opened from a branch to `main`, so its head commit is not a commit that was
#     pushed to `main` (a branch that is level with `main` is the empty diff that
#     empty-diff.yml refuses). Every `push` trigger of every workflow therefore
#     lists `branches: [main]` and no other branch, and no `pull_request` trigger
#     names a base other than `main`.
#
# The checker is shown to refuse each form on planted workflows first.
# Requires: bash, python3 with PyYAML.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
python3 -I - "$HERE" <<'PY'
import sys
import tempfile
from pathlib import Path

import yaml

passed = failed = 0


def load(path):
    return yaml.safe_load(path.read_text()) or {}


def names(folder):
    """check name -> the workflow files that produce it."""
    folder = Path(folder)
    produced = {}
    for path in sorted(folder.glob("*.y*ml")):
        for job_id, job in (load(path).get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            uses = job.get("uses")
            if isinstance(uses, str) and uses.startswith("./.github/workflows/"):
                inner = load(folder / uses.rsplit("/", 1)[1]).get("jobs") or {}
                for inner_id, inner_job in inner.items():
                    inner_name = (inner_job or {}).get("name", inner_id)
                    produced.setdefault(f"{job_id} / {inner_name}", set()).add(path.name)
            elif not path.name.startswith("reusable-"):
                produced.setdefault(str(job.get("name", job_id)), set()).add(path.name)
    return produced


def problems(folder):
    found = [f"`{name}` is produced by {', '.join(sorted(files))}"
             for name, files in sorted(names(folder).items()) if len(files) > 1 and not name.startswith("${{")]
    for path in sorted(Path(folder).glob("*.y*ml")):
        on = load(path).get("on", load(path).get(True)) or {}
        if not isinstance(on, dict):
            continue
        push = on.get("push")
        if "push" in on and (not isinstance(push, dict) or push.get("branches") != ["main"]):
            found.append(f"{path.name}: the push trigger does not name `branches: [main]` alone")
        pr = on.get("pull_request")
        if isinstance(pr, dict) and pr.get("branches") not in (None, ["main"]):
            found.append(f"{path.name}: the pull_request trigger names a base other than main")
    return found


def check(label, expected, actual):
    global passed, failed
    if expected == actual:
        passed += 1
        print(f"ok    {label}")
    else:
        failed += 1
        print(f"FAIL  {label}: expected {expected!r}, got {actual!r}")


def planted(files):
    with tempfile.TemporaryDirectory() as folder:
        for name, text in files.items():
            (Path(folder) / name).write_text(text)
        return problems(folder)


JOB = "jobs:\n  gate:\n    name: gate\n    runs-on: x\n    steps: []\n"
PUSH_MAIN = "on:\n  push:\n    branches: [main]\n  pull_request:\n"
check("two workflows with different check names are accepted", [],
      planted({"a.yml": PUSH_MAIN + JOB, "b.yml": PUSH_MAIN + JOB.replace("gate", "other")}))
check("two workflows that produce the same check name are refused",
      ["`gate` is produced by a.yml, b.yml"], planted({"a.yml": PUSH_MAIN + JOB, "b.yml": PUSH_MAIN + JOB}))
caller = "on:\n  pull_request:\njobs:\n  shell:\n    uses: ./.github/workflows/reusable-x.yml\n"
reusable = "on:\n  workflow_call:\njobs:\n  test:\n    name: test\n    runs-on: x\n    steps: []\n"
check("a caller and a workflow that make the same `<job> / <name>` are refused",
      ["`shell / test` is produced by a.yml, b.yml"],
      planted({"a.yml": caller, "b.yml": caller, "reusable-x.yml": reusable}))
check("a push to any branch is refused", ["a.yml: the push trigger does not name `branches: [main]` alone"],
      planted({"a.yml": "on:\n  push:\n" + JOB}))
check("a push to main and another branch is refused", ["a.yml: the push trigger does not name `branches: [main]` alone"],
      planted({"a.yml": "on:\n  push:\n    branches: [main, develop]\n" + JOB}))
check("a pull request against another base is refused", ["a.yml: the pull_request trigger names a base other than main"],
      planted({"a.yml": "on:\n  pull_request:\n    branches: [develop]\n" + JOB}))

check("no check name of this repository is produced twice, and every trigger is bound to main", [],
      problems(Path(sys.argv[1]) / ".github/workflows"))

print(f"\n{passed} passed, {failed} failed")
print(f"DONE required-check-names-are-unique.test.sh {passed} {failed}")
sys.exit(1 if failed else 0)
PY
