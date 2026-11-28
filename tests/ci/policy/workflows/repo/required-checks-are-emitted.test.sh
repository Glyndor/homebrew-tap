#!/usr/bin/env bash
# The ruleset of main requires checks by name, and GitHub matches the name and
# nothing else. A job renamed here leaves the ruleset waiting for a check that is
# never reported, and every pull request is then blocked with nothing saying why.
# The list below is the ruleset, written once, and it has to change with it: a
# name here that no workflow emits fails this suite, and so does a workflow that
# stops emitting one of them.
#
# A check is named by its job's `name:` (the job id when it has none). A job that
# calls a local reusable emits `<job id> / <name of the called job>` for each job
# in the reusable. Each name is also required to be emitted by one workflow only,
# so a green result from a workflow the pull request did not run cannot stand in
# for it (required-check-names-are-unique.test.sh holds that for the whole tree).
#
# The checker is shown to refuse a renamed job and a renamed caller first.
# Requires: bash, python3 with PyYAML.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
python3 -I -W error::DeprecationWarning - "$HERE" <<'PY'
import sys
import tempfile
from pathlib import Path

import yaml

# The checks the ruleset of main requires. A change to the ruleset is a change here.
REQUIRED = [
    "shell / test",
    "shell / shellcheck",
    "line-limit / line limit",
    "dco / Signed-off-by present on every commit",
    "workflow-lint / workflow-lint",
    "empty-diff / empty diff",
    "audit gate",
    "brew style",
    "products match the generator",
    "ML-DSA-65 verifier",
]
passed = failed = 0


def emitted(folder):
    folder = Path(folder)
    names = set()
    for path in sorted(folder.glob("*.y*ml")):
        for job_id, job in ((yaml.safe_load(path.read_text()) or {}).get("jobs") or {}).items():
            uses = job.get("uses") if isinstance(job, dict) else None
            if isinstance(uses, str) and uses.startswith("./.github/workflows/"):
                inner = (yaml.safe_load((folder / uses.rsplit("/", 1)[1]).read_text()) or {}).get("jobs") or {}
                names |= {f"{job_id} / {(j or {}).get('name', i)}" for i, j in inner.items()}
            elif isinstance(job, dict):
                names.add(str(job.get("name", job_id)))
    return names


def missing(folder, required):
    have = emitted(folder)
    return [f"{name}: no workflow emits it" for name in required if name not in have]


def check(label, expected, actual):
    global passed, failed
    if expected == actual:
        passed += 1
        print(f"ok    {label}")
    else:
        failed += 1
        print(f"FAIL  {label}: expected {expected!r}, got {actual!r}")


def planted(files, required):
    with tempfile.TemporaryDirectory() as folder:
        for name, text in files.items():
            (Path(folder) / name).write_text(text)
        return missing(folder, required)


CALLER = "jobs:\n  shell:\n    uses: ./.github/workflows/reusable-x.yml\n"
REUSABLE = "jobs:\n  test:\n    name: test\n    runs-on: x\n    steps: []\n"
DIRECT = "jobs:\n  g:\n    name: the gate\n    runs-on: x\n    steps: []\n"
files = {"a.yml": CALLER, "reusable-x.yml": REUSABLE, "b.yml": DIRECT}
check("a caller and a job of its own are both emitted", [], planted(files, ["shell / test", "the gate"]))
check("a job renamed is reported by the name the ruleset has", ["the gate: no workflow emits it"],
      planted({**files, "b.yml": DIRECT.replace("the gate", "the gatex")}, ["shell / test", "the gate"]))
check("a caller renamed is reported for the check it carried", ["shell / test: no workflow emits it"],
      planted({**files, "a.yml": CALLER.replace("shell", "shellx")}, ["shell / test", "the gate"]))
check("a job of the reusable renamed is reported", ["shell / test: no workflow emits it"],
      planted({**files, "reusable-x.yml": REUSABLE.replace("name: test", "name: testx")}, ["shell / test", "the gate"]))
check("a job with no name is named by its id", [], planted({"a.yml": "jobs:\n  products:\n    runs-on: x\n    steps: []\n"}, ["products"]))

check("every check the ruleset requires is emitted by a workflow of this repository", [],
      missing(Path(sys.argv[1]) / ".github/workflows", REQUIRED))

print(f"\n{passed} passed, {failed} failed")
print(f"DONE required-checks-are-emitted.test.sh {passed} {failed}")
sys.exit(1 if failed else 0)
PY
