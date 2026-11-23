#!/usr/bin/env bash
#
# The scheduled sweep of the mutation catalogue is split by file of the catalogue, every file is in
# a fragment, and each fragment has a time bound that covers what it measured.
#
# GitHub reports a job that exceeds its `timeout-minutes` as `cancelled`, and a cancelled run is not
# a success, so the freshness watcher of the sweep cannot count it. That is how the scheduled run of
# 2026-11-23 failed in two channels: the bound had been written for a catalogue a third of the size,
# and nothing said so until the cron had fired once and been cut. The grace period of a new cron ends
# with its first run, successful or not, so the failure cost the whole fortnight. This holds, in the
# pull request that causes it and not in the cron a week later:
#
#   * every file of the catalogue (catalog.txt and each catalog.d/*.txt) is one fragment of the
#     matrix of the sweep, once, and no fragment names a file that is not there, so no entry is left
#     outside every fragment, and the entries of the fragments add up to the whole catalogue;
#   * the matrix does not stop the other fragments when one fails, and the bound of each job is the
#     one its fragment names;
#   * the file tests/mutation/sweep-durations.txt has a line for each fragment, with the entries it
#     had when it was measured and the seconds it took on a runner, and the bound of the fragment is
#     at least that time, scaled to the entries the fragment has now, with a half on top. A catalogue
#     that grows past the bound fails here and names the bound it needs.
#
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
MARGIN = 1.5


def files_of(repo):
    found = [repo / "tests/mutation/catalog.txt"] if (repo / "tests/mutation/catalog.txt").exists() else []
    found += sorted((repo / "tests/mutation/catalog.d").glob("*.txt")) if (repo / "tests/mutation/catalog.d").is_dir() else []
    return [str(f.relative_to(repo)) for f in found]


def entries(repo, rel):
    return sum(1 for line in (repo / rel).read_text().splitlines() if line.strip() and not line.startswith("#"))


def problems(repo):
    found = []
    spec = yaml.safe_load((repo / ".github/workflows/mutation.yml").read_text()) or {}
    jobs = [(n, j) for n, j in (spec.get("jobs") or {}).items()
            if any("run-mutations.sh" in str(s.get("run", "")) for s in j.get("steps") or [])]
    if len(jobs) != 1:
        return [f"{len(jobs)} jobs of mutation.yml run run-mutations.sh, and the fragments can only be read from one"]
    name, job = jobs[0]
    strategy = job.get("strategy") or {}
    include = (strategy.get("matrix") or {}).get("include") or []
    if strategy.get("fail-fast") is not False:
        found.append(f"job `{name}` does not say `fail-fast: false`, so one fragment that fails would stop the others")
    if job.get("timeout-minutes") != "${{ matrix.minutes }}":
        found.append(f"job `{name}` is not bound by the minutes its fragment names")
    declared = [e.get("fragment") for e in include]
    live = files_of(repo)
    for rel in live:
        if declared.count(rel) == 0:
            found.append(f"{rel} is in no fragment of the sweep, so its entries are never run")
    for rel in sorted(set(declared)):
        if rel not in live:
            found.append(f"the sweep names the fragment {rel}, which is not a file of the catalogue")
        elif declared.count(rel) > 1:
            found.append(f"the fragment {rel} is listed {declared.count(rel)} times")
    measured = {}
    data = repo / "tests/mutation/sweep-durations.txt"
    for line in data.read_text().splitlines() if data.exists() else []:
        if line.strip() and not line.startswith("#"):
            cols = line.split("\t")
            if len(cols) != 4 or not re.fullmatch(r"[0-9]+", cols[1]) or not re.fullmatch(r"[0-9]+", cols[2]) or int(cols[1]) == 0:
                found.append(f"the line `{line}` of sweep-durations.txt is not <file>, <entries>, <seconds>, <source>")
            else:
                measured[cols[0]] = (int(cols[1]), int(cols[2]))
    total = 0
    counted = set()
    for e in include:
        rel = e.get("fragment")
        if rel not in live:
            continue
        now = entries(repo, rel)
        if rel not in counted:
            total += now
            counted.add(rel)
        if rel not in measured:
            found.append(f"{rel} has no measured duration in sweep-durations.txt")
            continue
        was, secs = measured[rel]
        need = secs * now / was * MARGIN / 60
        minutes = e.get("minutes")
        if not isinstance(minutes, int):
            found.append(f"the fragment {rel} names no minutes")
        elif minutes < need:
            found.append(f"the fragment {rel} is bound at {minutes} minutes and needs {int(need) + 1} for its {now} entries")
    for rel in sorted(set(measured) - set(live)):
        found.append(f"sweep-durations.txt measures {rel}, which is not a file of the catalogue")
    if declared and set(declared) >= set(live) and total != sum(entries(repo, r) for r in live):
        found.append("the entries of the fragments do not add up to the catalogue")
    return found


def plant(catalogs, workflow_include, durations, fail_fast=False, timeout="${{ matrix.minutes }}"):
    with tempfile.TemporaryDirectory() as d:
        repo = Path(d)
        (repo / "tests/mutation/catalog.d").mkdir(parents=True)
        (repo / ".github/workflows").mkdir(parents=True)
        for rel, n in catalogs.items():
            (repo / rel).write_text("# c\n\n" + "".join(f"{rel.replace('/', '-')}{i}\ta\tb\tc\td\n" for i in range(n)))
        incl = "".join(f"          - fragment: {f}\n            minutes: {m}\n" for f, m in workflow_include)
        ff = "" if fail_fast is None else f"      fail-fast: {str(fail_fast).lower()}\n"
        (repo / ".github/workflows/mutation.yml").write_text(
            "on:\n  schedule:\n    - cron: '0 0 * * 1'\njobs:\n  sweep:\n    runs-on: x\n"
            f"    timeout-minutes: {timeout}\n    strategy:\n{ff}      matrix:\n        include:\n{incl}"
            "    steps:\n      - run: bash ./tests/mutation/run-mutations.sh --catalog \"$FRAGMENT\"\n")
        (repo / "tests/mutation/sweep-durations.txt").write_text("# header\n" + "".join(f"{f}\t{n}\t{s}\tplanted\n" for f, n, s in durations))
        return problems(repo)


def check(label, expected, actual):
    global passed, failed
    if expected == actual:
        print(f"ok    {label}")
        passed += 1
    else:
        print(f"FAIL  {label}\n        expected: {expected}\n        actual:   {actual}")
        failed += 1


A, B = "tests/mutation/catalog.txt", "tests/mutation/catalog.d/x.txt"
cat = {A: 60, B: 20}
inc = [(A, 30), (B, 10)]
dur = [(A, 60, 600), (B, 20, 100)]
check("fragments that cover the catalogue, each with a bound over its measure, pass", [], plant(cat, inc, dur))
check("a file of the catalogue that no fragment names is refused", [f"{B} is in no fragment of the sweep, so its entries are never run"], plant(cat, [(A, 30)], dur))
check("a fragment that names a file that is not there is refused", [f"the sweep names the fragment tests/mutation/catalog.d/gone.txt, which is not a file of the catalogue"],
      [p for p in plant(cat, inc + [("tests/mutation/catalog.d/gone.txt", 10)], dur) if "not a file" in p and "names the fragment" in p])
check("a fragment listed twice is refused", [f"the fragment {A} is listed 2 times"], plant(cat, inc + [(A, 30)], dur))
check("a bound under the measure scaled to the entries is refused", [f"the fragment {A} is bound at 14 minutes and needs 16 for its 60 entries"],
      plant(cat, [(A, 14), (B, 10)], dur))
check("a catalogue that grew past its bound is refused naming the bound it needs", [f"the fragment {A} is bound at 30 minutes and needs 46 for its 180 entries"], plant({A: 180, B: 20}, inc, dur))
check("and the bound it names is enough", [], plant({A: 180, B: 20}, [(A, 46), (B, 10)], dur))
check("a fragment with no measured duration is refused", [f"{B} has no measured duration in sweep-durations.txt"], plant(cat, inc, dur[:1]))
check("a measured duration of a file that is gone is refused", [f"sweep-durations.txt measures tests/mutation/catalog.d/gone.txt, which is not a file of the catalogue"],
      plant(cat, inc, dur + [("tests/mutation/catalog.d/gone.txt", 5, 50)]))
check("a matrix that stops the others when one fails is refused", ["job `sweep` does not say `fail-fast: false`, so one fragment that fails would stop the others"],
      plant(cat, inc, dur, fail_fast=None))
check("a job bound by a fixed number and not by its fragment is refused", ["job `sweep` is not bound by the minutes its fragment names"],
      plant(cat, inc, dur, timeout="90"))
check("a line of the durations with no entries is refused", ["the line `x\t0\t5\tplanted` of sweep-durations.txt is not <file>, <entries>, <seconds>, <source>"], plant(cat, inc, dur + [("x", 0, 5)]))
check("the live sweep is split, covers the catalogue and is bound over what it measured", [], problems(root))
print(f"\n{passed} passed, {failed} failed")
print(f"DONE mutation-sweep-is-split-and-bounded.test.sh {passed} {failed}")
sys.exit(1 if failed else 0)
PY
