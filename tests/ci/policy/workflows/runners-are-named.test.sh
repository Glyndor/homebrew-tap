#!/usr/bin/env bash
# A job runs on an image that is named, and a matrix stops at its first failure.
#
#   * `ubuntu-latest` and `macos-latest` are labels GitHub repoints on its own
#     schedule, so a job that uses one changes what it runs on without a commit
#     here. Every job names its image, except the ones listed as floating, with
#     the reason each may keep a floating label;
#   * a matrix with `fail-fast: false` keeps spending runner minutes on the
#     other legs after one has already decided the run, and one that leaves it
#     out is the same as true. Every matrix says `fail-fast: true`, except the
#     ones listed as independent, whose legs each answer a question of their own
#     and say `fail-fast: false`.
#
# Both lists are exact, by (workflow, job), and of each repository: they are in
# runners-exceptions.json beside this file, which the sibling channel does not
# share, while this file is a copy it does. A new job with a floating label is
# refused until somebody lists it and writes why, and an entry for a job that is
# not here is refused. The checker is shown to refuse each form on planted
# workflows first.
# Requires: bash, python3 with PyYAML.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
python3 -I - "$HERE" <<'PY'
import json
import sys
import tempfile
from pathlib import Path

import yaml

passed = failed = 0
HERE = Path(sys.argv[1])
EXCEPTIONS = "tests/ci/policy/workflows/runners-exceptions.json"


def load_exceptions(path, folder):
    """The exceptions of this repository: ({(workflow, job): why} floating, the same for independent, what is wrong)."""
    def once(pairs):
        keys = [k for k, _ in pairs]
        if len(set(keys)) != len(keys):
            raise ValueError("a key is written twice")
        return dict(pairs)

    try:
        data = json.loads(path.read_text(), object_pairs_hook=once)
    except (OSError, ValueError) as error:
        return {}, {}, [f"the exceptions cannot be read: {type(error).__name__}"]
    if not isinstance(data, dict) or sorted(data) != ["floating", "independent"] \
            or not all(isinstance(v, list) for v in data.values()):
        return {}, {}, ["the exceptions are not the two lists floating and independent"]
    found, out = [], {}
    for name in ("floating", "independent"):
        out[name] = {}
        for entry in data[name]:
            if not (isinstance(entry, list) and len(entry) == 3 and all(isinstance(x, str) and x.strip() for x in entry)):
                found.append(f"{name}: an entry is not [workflow, job, why]")
                continue
            workflow, job, why = entry
            if (workflow, job) in out[name]:
                found.append(f"{name}: {workflow} `{job}` is listed twice")
            out[name][(workflow, job)] = why
            spec = folder / workflow
            jobs = (yaml.safe_load(spec.read_text()) or {}).get("jobs") or {} if spec.is_file() else {}
            if job not in jobs:
                found.append(f"{name}: {workflow} has no job `{job}` in this repository, so the entry goes")
    return out["floating"], out["independent"], found


def problems(folder, floating, independent=frozenset()):
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
            wanted = (path.name, job_id) not in independent
            if matrix is not None and (job.get("strategy") or {}).get("fail-fast") is not wanted:
                found.append(f"{path.name}: job `{job_id}` has a matrix that does not say fail-fast: {str(wanted).lower()}")
            if matrix is None and not wanted:
                found.append(f"{path.name}: job `{job_id}` is listed as independent and has no matrix, so the entry goes")
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


def planted(body, floating=(), independent=()):
    with tempfile.TemporaryDirectory() as folder:
        (Path(folder) / "w.yml").write_text("jobs:\n  j:\n" + body)
        return problems(folder, set(floating), set(independent))


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

MATRIX_OFF = "    runs-on: ubuntu-26.04\n    strategy:\n      fail-fast: false\n      matrix:\n        a: [1, 2]\n"
check("a matrix that is listed as independent and says fail-fast: false is accepted", [], planted(MATRIX_OFF, independent=[("w.yml", "j")]))
check("a listed matrix that says fail-fast: true is refused",
      ["w.yml: job `j` has a matrix that does not say fail-fast: false"],
      planted("    runs-on: ubuntu-26.04\n    strategy:\n      fail-fast: true\n      matrix:\n        a: [1, 2]\n", independent=[("w.yml", "j")]))
check("a listed job with no matrix is refused, so the entry cannot outlive its cause",
      ["w.yml: job `j` is listed as independent and has no matrix, so the entry goes"],
      planted("    runs-on: ubuntu-26.04\n", independent=[("w.yml", "j")]))
check("a job that is not listed still needs fail-fast: true", ["w.yml: job `j` has a matrix that does not say fail-fast: true"], planted(MATRIX_OFF))

def loaded(text, jobs="jobs:\n  j:\n    runs-on: x\n"):
    with tempfile.TemporaryDirectory() as folder:
        (Path(folder) / "w.yml").write_text(jobs)
        listed = Path(folder) / "x.json"
        if text is not None:
            listed.write_text(text)
        return load_exceptions(listed, Path(folder))[2]


GOOD = '{"floating": [["w.yml", "j", "why"]], "independent": []}'
check("exceptions that name a job of the repository load", [], loaded(GOOD))
check("no exceptions file is refused", ["the exceptions cannot be read: FileNotFoundError"], loaded(None))
check("exceptions that are not JSON are refused", ["the exceptions cannot be read: JSONDecodeError"], loaded("{"))
check("a key written twice is refused", ["the exceptions cannot be read: ValueError"],
      loaded('{"floating": [], "floating": [], "independent": []}'))
check("a missing list is refused", ["the exceptions are not the two lists floating and independent"], loaded('{"floating": []}'))
check("an entry with no reason is refused", ["floating: an entry is not [workflow, job, why]"],
      loaded('{"floating": [["w.yml", "j", " "]], "independent": []}'))
check("an entry listed twice is refused", ["independent: w.yml `j` is listed twice"],
      loaded('{"floating": [], "independent": [["w.yml", "j", "a"], ["w.yml", "j", "b"]]}'))
check("an entry for a job that is not here is refused", ["floating: w.yml has no job `k` in this repository, so the entry goes"],
      loaded('{"floating": [["w.yml", "k", "why"]], "independent": []}'))
check("an entry for a workflow that is not here is refused", ["floating: z.yml has no job `j` in this repository, so the entry goes"],
      loaded('{"floating": [["z.yml", "j", "why"]], "independent": []}'))

FLOATING, INDEPENDENT, unreadable = load_exceptions(HERE / EXCEPTIONS, HERE / ".github/workflows")
check("the exceptions of this repository name its own jobs", [], unreadable)
check("every job of this repository names its image and every matrix fails fast", [],
      problems(HERE / ".github/workflows", set(FLOATING), set(INDEPENDENT)))

print(f"\n{passed} passed, {failed} failed")
print(f"DONE runners-are-named.test.sh {passed} {failed}")
sys.exit(1 if failed else 0)
PY
