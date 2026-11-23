#!/usr/bin/env bash
# A job runs on an image that is named, and a matrix stops at its first failure.
#
#   * `ubuntu-latest` and `macos-latest` are labels GitHub repoints on its own
#     schedule, so a job that uses one changes what it runs on without a commit
#     here. Every job names its image, except the ones listed below with the
#     reason each may keep a floating label;
#   * a matrix with `fail-fast: false` keeps spending runner minutes on the
#     other legs after one has already decided the run, and one that leaves it
#     out is the same as true. Every matrix says `fail-fast: true`.
#
# The exceptions are an exact list of (workflow, job): a new job with a floating
# label is refused until somebody lists it and writes why. The checker is shown
# to refuse each form on planted workflows first.
# Requires: bash, python3 with PyYAML.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
python3 -I - "$HERE" <<'PY'
import sys
import tempfile
from pathlib import Path

import yaml

passed = failed = 0
# (workflow, job) -> why a floating label stays.
FLOATING = {
    ("audit.yml", "scope"): "writes an output a condition reads; naming the image is a producer change that needs its own earlier pull request",
    ("audit.yml", "audit"): "the verdict is the one of the macOS a user installing today gets, and Homebrew is replaced by GitHub every week whatever the label says",
}


def problems(folder, floating):
    found = []
    for path in sorted(Path(folder).glob("*.y*ml")):
        spec = yaml.safe_load(path.read_text()) or {}
        for job_id, job in (spec.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            label = job.get("runs-on")
            if isinstance(label, str) and label.endswith("-latest") and (path.name, job_id) not in floating:
                found.append(f"{path.name}: job `{job_id}` runs on the floating label {label}")
            matrix = (job.get("strategy") or {}).get("matrix")
            if matrix is not None and (job.get("strategy") or {}).get("fail-fast") is not True:
                found.append(f"{path.name}: job `{job_id}` has a matrix that does not say fail-fast: true")
            if (path.name, job_id) in floating and not (isinstance(label, str) and label.endswith("-latest")):
                found.append(f"{path.name}: job `{job_id}` is listed as floating and no longer is, so the entry goes")
    return found


def check(label, expected, actual):
    global passed, failed
    if expected == actual:
        passed += 1
        print(f"ok    {label}")
    else:
        failed += 1
        print(f"FAIL  {label}: expected {expected!r}, got {actual!r}")


def planted(body, floating=()):
    with tempfile.TemporaryDirectory() as folder:
        (Path(folder) / "w.yml").write_text("jobs:\n  j:\n" + body)
        return problems(folder, set(floating))


check("a named image is accepted", [], planted("    runs-on: ubuntu-26.04\n"))
check("ubuntu-latest is refused", ["w.yml: job `j` runs on the floating label ubuntu-latest"],
      planted("    runs-on: ubuntu-latest\n"))
check("macos-latest is refused", ["w.yml: job `j` runs on the floating label macos-latest"],
      planted("    runs-on: macos-latest\n"))
check("a listed floating label is accepted", [], planted("    runs-on: macos-latest\n", [("w.yml", "j")]))
check("a listed job that now names its image is refused, so the entry cannot outlive its cause",
      ["w.yml: job `j` is listed as floating and no longer is, so the entry goes"],
      planted("    runs-on: ubuntu-26.04\n", [("w.yml", "j")]))
check("a matrix with fail-fast: true is accepted", [],
      planted("    runs-on: ubuntu-26.04\n    strategy:\n      fail-fast: true\n      matrix:\n        a: [1, 2]\n"))
check("a matrix with fail-fast: false is refused",
      ["w.yml: job `j` has a matrix that does not say fail-fast: true"],
      planted("    runs-on: ubuntu-26.04\n    strategy:\n      fail-fast: false\n      matrix:\n        a: [1, 2]\n"))
check("a matrix that says nothing is refused",
      ["w.yml: job `j` has a matrix that does not say fail-fast: true"],
      planted("    runs-on: ubuntu-26.04\n    strategy:\n      matrix:\n        a: [1, 2]\n"))

check("every job of this repository names its image and every matrix fails fast", [],
      problems(Path(sys.argv[1]) / ".github/workflows", set(FLOATING)))

print(f"\n{passed} passed, {failed} failed")
print(f"DONE runners-are-named.test.sh {passed} {failed}")
sys.exit(1 if failed else 0)
PY
