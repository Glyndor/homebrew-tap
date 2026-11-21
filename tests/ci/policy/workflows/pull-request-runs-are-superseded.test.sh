#!/usr/bin/env bash
#
# A workflow that runs on a pull request and does work of its own must let a newer push
# supersede the run still going on the old commit, and must never let that
# cancellation reach a run on main or a scheduled one.
#
# tests.yml had no `concurrency` at all: every push to a pull request left the suite,
# the formula checks and `brew style` running to the end on a commit nobody reads
# any more, and nothing noticed, because cancel-policy.test.sh only lists five
# reusable workflows and the callers with jobs of their own were never looked at. The
# next workflow added with jobs of its own would have had the same gap.
#
# The rule, for every workflow that is not a reusable one:
#
#   * it triggers on `pull_request` and has at least one job of its own (`runs-on`),
#     a caller that only `uses:` a reusable inherits the reusable's group;
#   * so it carries `concurrency`, at the top or on every such job;
#   * the group names the ref, or a pull request would cancel the run of another;
#   * the group names the event, so that a push to main or a schedule is told apart
#     from a pull request and never queues behind, or cancels, one;
#   * `cancel-in-progress` is exactly `${{ github.event_name == 'pull_request' }}`.
#
# The checker runs against planted trees first, so a pass is shown to be a pass of
# a check that can fail, and then against this repository's workflows.
#
# Requires: python3 with PyYAML (tests.yml installs python3-yaml).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
		echo "ok    $1"
	else
		fail=$((fail + 1))
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
	fi
}

# One line per offence: "<file>: <what is wrong>". Exit 1 when there is one.
audit() { # $1=workflows dir
	python3 -I - "$1" <<'PY'
import glob
import os
import sys

import yaml

WANT_CANCEL = "${{ github.event_name == 'pull_request' }}"


def triggers(doc):
    # PyYAML reads the bare key `on` as the boolean True.
    on = doc.get("on", doc.get(True))
    if isinstance(on, dict):
        return set(on)
    if isinstance(on, str):
        return {on}
    return set(on or [])


def problems(conc):
    if not isinstance(conc, dict):
        return ["concurrency is not a mapping with a group"]
    out = []
    group = str(conc.get("group", ""))
    if "github.ref" not in group:
        out.append("the group does not name github.ref")
    if "github.event_name" not in group:
        out.append("the group does not name github.event_name")
    if str(conc.get("cancel-in-progress", "")).strip() != WANT_CANCEL:
        out.append("cancel-in-progress is not limited to a pull request")
    return out


bad = 0
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.yml"))):
    name = os.path.basename(path)
    if name.startswith("reusable-"):
        continue
    with open(path) as f:
        doc = yaml.safe_load(f) or {}
    if "pull_request" not in triggers(doc):
        continue
    own = {k: j for k, j in (doc.get("jobs") or {}).items() if isinstance(j, dict) and "runs-on" in j}
    if not own:
        continue
    if "concurrency" in doc:
        found = problems(doc["concurrency"])
        found = [f"{name}: {p}" for p in found]
    else:
        found = []
        for key, job in own.items():
            if "concurrency" not in job:
                found.append(f"{name}: job {key} has no concurrency and the workflow has none")
            else:
                found += [f"{name}: job {key}: {p}" for p in problems(job["concurrency"])]
    for line in found:
        bad += 1
        print(line)
sys.exit(1 if bad else 0)
PY
}

plant() { # $1=dir $2=file name; the workflow text on stdin
	mkdir -p "$1"
	cat > "$1/$2"
}

# --- the control: every way of getting it wrong is reported ------------------
plant "$WORK/none" bare.yml <<'EOF'
name: bare
on:
  pull_request:
  push:
    branches: [main]
jobs:
  work:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
EOF
rc=0; out="$(audit "$WORK/none")" || rc=$?
check "a pull request workflow with a job of its own and no concurrency is reported" "1" "$rc"
check "and the report names the workflow and the job" "1" \
	"$(printf '%s\n' "$out" | grep -c '^bare.yml: job work has no concurrency')"

plant "$WORK/always" always.yml <<'EOF'
name: always
on: pull_request
concurrency:
  group: always-${{ github.event_name }}-${{ github.ref }}
  cancel-in-progress: true
jobs:
  work:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
EOF
rc=0; out="$(audit "$WORK/always")" || rc=$?
check "a group that cancels unconditionally is reported" "1" "$rc"
check "and the report says it is not limited to a pull request" "1" \
	"$(printf '%s\n' "$out" | grep -c 'always.yml: cancel-in-progress is not limited to a pull request')"

plant "$WORK/noref" noref.yml <<'EOF'
name: noref
on: [pull_request, push]
concurrency:
  group: noref-${{ github.event_name }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
jobs:
  work:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
EOF
rc=0; out="$(audit "$WORK/noref")" || rc=$?
check "a group without the ref, which lets one pull request cancel another, is reported" "1" "$rc"
check "and the report says the group does not name github.ref" "1" \
	"$(printf '%s\n' "$out" | grep -c 'noref.yml: the group does not name github.ref')"

plant "$WORK/noevent" noevent.yml <<'EOF'
name: noevent
on:
  pull_request:
  push:
    branches: [main]
concurrency:
  group: noevent-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
jobs:
  work:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
EOF
rc=0; out="$(audit "$WORK/noevent")" || rc=$?
check "a group that does not tell the events apart is reported" "1" "$rc"
check "and the report says the group does not name github.event_name" "1" \
	"$(printf '%s\n' "$out" | grep -c 'noevent.yml: the group does not name github.event_name')"

# --- what is not held to the rule ---------------------------------------------
plant "$WORK/fine" right.yml <<'EOF'
name: right
on:
  pull_request:
  push:
    branches: [main]
concurrency:
  group: right-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
jobs:
  work:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
EOF
plant "$WORK/fine" caller.yml <<'EOF'
name: caller
on: pull_request
jobs:
  gate:
    uses: ./.github/workflows/reusable-something.yml
EOF
plant "$WORK/fine" scheduled.yml <<'EOF'
name: scheduled
on:
  schedule:
    - cron: "5 4 * * *"
jobs:
  work:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
EOF
plant "$WORK/fine" reusable-thing.yml <<'EOF'
name: reusable
on:
  workflow_call:
  pull_request:
jobs:
  work:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
EOF
plant "$WORK/fine" perjob.yml <<'EOF'
name: perjob
on: pull_request
jobs:
  poll:
    runs-on: ubuntu-latest
    concurrency:
      group: perjob-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}
      cancel-in-progress: ${{ github.event_name == 'pull_request' }}
    steps:
      - run: echo hi
EOF
rc=0; out="$(audit "$WORK/fine")" || rc=$?
check "a correct workflow, a caller of a reusable, a schedule-only workflow, a reusable and a job-level group are not reported" "0" "$rc"
[ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/        /'

# A job-level group is judged the same way: one job with it and one without is reported.
plant "$WORK/half" half.yml <<'EOF'
name: half
on: pull_request
jobs:
  covered:
    runs-on: ubuntu-latest
    concurrency:
      group: half-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}
      cancel-in-progress: ${{ github.event_name == 'pull_request' }}
    steps:
      - run: echo hi
  bare:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
EOF
rc=0; out="$(audit "$WORK/half")" || rc=$?
check "a workflow where only one of two own jobs is covered is reported" "1" "$rc"
check "and the report names the bare job" "1" \
	"$(printf '%s\n' "$out" | grep -c '^half.yml: job bare has no concurrency')"
check "and not the covered one" "0" "$(printf '%s\n' "$out" | grep -c 'job covered')"

# --- this repository ----------------------------------------------------------
rc=0; out="$(audit "$HERE/.github/workflows")" || rc=$?
check "every pull request workflow with jobs of its own supersedes the run on the old commit" "0" "$rc"
[ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/        /'

# The same tree with tests.yml's block removed must be reported, which shows the live
# check reads that file and not only the planted ones.
mkdir -p "$WORK/live"
cp "$HERE"/.github/workflows/*.yml "$WORK/live/"
python3 -I - "$WORK/live/tests.yml" <<'PY'
import re
import sys

p = sys.argv[1]
text = open(p).read()
cut = re.sub(r"(?m)^concurrency:\n(?:[ ]+.*\n)+", "", text, count=1)
if cut == text:
    sys.exit("no top-level concurrency block in tests.yml to remove")
open(p, "w").write(cut)
PY
rc=0; out="$(audit "$WORK/live")" || rc=$?
check "tests.yml without its concurrency block is reported" "1" "$rc"
check "and the report names tests.yml and each of its jobs" "tests.yml: job formulae,tests.yml: job products" \
	"$(printf '%s\n' "$out" | grep -o '^tests.yml: job [a-z]*' | LC_ALL=C sort | paste -sd, -)"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
