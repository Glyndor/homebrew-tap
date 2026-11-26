#!/usr/bin/env bash
#
# The published-bytes watcher downloads whatever URL a formula declares, and its
# own URL rule only requires a Glyndor release asset. What binds a formula to the
# product it publishes is scripts/artifacts/check-formulae.sh, so the workflow has
# to run that first and fail before any download. This reads the workflow and
# requires both steps, in that order, with no step that could let the first one
# fail without stopping the job.
#
# The same job then reads every formula digest against the signed SHA256SUMS
# (`render-formulae.sh --verify-published`), which needs the verifier the render job
# installs. That step has to run once, after the product check, with nothing that
# lets it fail without stopping the job, and the install step before it has to be
# the render job's own, word for word: a verifier installed another way is a second
# thing to keep in step.
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

verdict() { # $1 = workflow file
	python3 - "$1" "$HERE/.github/workflows/update.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
update = yaml.safe_load(open(sys.argv[2]))
where = []  # (job id, index in its job, step)
for jid, job in doc["jobs"].items():
    for i, step in enumerate(job.get("steps", [])):
        if "run" in step:
            where.append((jid, i, step))
def calls(run, name):
    # A line that runs the script, not one that merely names it (an `echo` of it
    # passes a substring test while running nothing).
    return any(line.strip() in (f"bash ./{name}", f"./{name}") for line in run.splitlines())
def find(name):
    hits = [w for w in where if calls(w[2]["run"], name)]
    return hits[0] if len(hits) == 1 else None
first = find("scripts/artifacts/check-formulae.sh")
second = find("scripts/monitoring/check-published-formulae.sh")
VERIFY = "bash ./scripts/release/render-formulae.sh --verify-published"
hits = [w for w in where if any(line.strip() == VERIFY for line in w[2]["run"].splitlines())]
third = hits[0] if len(hits) == 1 else None
INSTALL = "Install the signature verifier"
def install_of(d):
    return [st.get("run") for job in d["jobs"].values() for st in job.get("steps", []) if st.get("name") == INSTALL]
mine, theirs = install_of(doc), install_of(update)
if first is None:
    print("the product check is not run exactly once")
elif second is None:
    print("the published-bytes check is not run exactly once")
elif first[0] != second[0]:
    print("the two checks are in different jobs")
elif first[1] > second[1]:
    print("the product check runs after the download check")
elif third is None:
    print("the signed-checksums check is not run exactly once")
elif third[0] != first[0]:
    print("the signed-checksums check is in another job than the product check")
elif third[1] < first[1]:
    print("the signed-checksums check runs before the product check")
elif third[2].get("continue-on-error") or third[2].get("if"):
    print("the signed-checksums check can be skipped or can fail without stopping the job")
elif len(theirs) != 1 or mine != theirs:
    print("the verifier is not installed by the render job's own step")
elif first[2].get("continue-on-error") or first[2].get("if"):
    print("the product check can be skipped or can fail without stopping the job")
elif doc["jobs"][first[0]].get("if") or doc["jobs"][first[0]].get("continue-on-error"):
    print("the job that holds the product check can be skipped or can fail without failing the workflow")
else:
    print("ok")
PY
}

check "the live workflow runs the product check first, then the signed-checksums check, unconditionally" "ok" \
	"$(verdict "$HERE/.github/workflows/published-bytes.yml")"

mkdir -p "$WORK/c"
python3 - "$HERE/.github/workflows/published-bytes.yml" "$WORK/c" <<'PY'
import sys, yaml, copy
doc = yaml.safe_load(open(sys.argv[1]))
def write(name, edit):
    d = copy.deepcopy(doc)
    edit(d)
    yaml.safe_dump(d, open(f"{sys.argv[2]}/{name}.yml", "w"), sort_keys=False)
def steps(d):
    return next(iter(d["jobs"].values()))["steps"]
def drop(d):
    s = steps(d)
    s[:] = [x for x in s if "check-formulae.sh" not in x.get("run", "")]
def swap(d):
    s = steps(d)
    a = next(i for i, x in enumerate(s) if "check-formulae.sh" in x.get("run", ""))
    b = next(i for i, x in enumerate(s) if "check-published-formulae.sh" in x.get("run", ""))
    s[a], s[b] = s[b], s[a]
def soften(d):
    for x in steps(d):
        if "check-formulae.sh" in x.get("run", ""):
            x["continue-on-error"] = True
def echoed(d):
    for x in steps(d):
        if "check-formulae.sh" in x.get("run", "") and "check-published" not in x["run"]:
            x["run"] = "echo " + x["run"]
def no_verify(d):
    s = steps(d)
    s[:] = [x for x in s if "--verify-published" not in x.get("run", "")]
def verify_first(d):
    s = steps(d)
    a = next(i for i, x in enumerate(s) if "--verify-published" in x.get("run", ""))
    moved = s.pop(a)
    b = next(i for i, x in enumerate(s) if "check-formulae.sh" in x.get("run", ""))
    s.insert(b, moved)
def verify_soft(d):
    for x in steps(d):
        if "--verify-published" in x.get("run", ""):
            x["continue-on-error"] = True
def verify_if(d):
    for x in steps(d):
        if "--verify-published" in x.get("run", ""):
            x["if"] = "github.event_name == 'schedule'"
def other_install(d):
    for x in steps(d):
        if x.get("name") == "Install the signature verifier":
            x["run"] = "sudo apt-get install -y -qq python3-cryptography\n"
def verify_echoed(d):
    for x in steps(d):
        if "--verify-published" in x.get("run", ""):
            x["run"] = x["run"].replace("bash ./scripts", "echo ./scripts")
write("no-verify", no_verify)
write("verify-first", verify_first)
write("verify-soft", verify_soft)
write("verify-if", verify_if)
write("other-install", other_install)
write("verify-echoed", verify_echoed)
write("echoed", echoed)
write("dropped", drop)
write("swapped", swap)
def job_soft(d):
    next(iter(d["jobs"].values()))["continue-on-error"] = True
def job_if(d):
    next(iter(d["jobs"].values()))["if"] = "github.event_name == 'schedule'"
def split(d):
    job = next(iter(d["jobs"].values()))
    a = next(i for i, x in enumerate(job["steps"]) if "check-formulae.sh" in x.get("run", ""))
    moved = job["steps"].pop(a)
    d["jobs"]["product"] = {"runs-on": "ubuntu-latest", "steps": [moved]}
write("softened", soften)
write("job-soft", job_soft)
write("job-if", job_if)
write("split", split)
PY
check "without the signed-checksums check the workflow is reported" "the signed-checksums check is not run exactly once" "$(verdict "$WORK/c/no-verify.yml")"
check "a step that only echoes the signed-checksums check is reported" "the signed-checksums check is not run exactly once" "$(verdict "$WORK/c/verify-echoed.yml")"
check "with the signed-checksums check before the product check it is reported" "the signed-checksums check runs before the product check" "$(verdict "$WORK/c/verify-first.yml")"
check "with continue-on-error on the signed-checksums check it is reported" "the signed-checksums check can be skipped or can fail without stopping the job" "$(verdict "$WORK/c/verify-soft.yml")"
check "with a condition on the signed-checksums check it is reported" "the signed-checksums check can be skipped or can fail without stopping the job" "$(verdict "$WORK/c/verify-if.yml")"
check "with another way of installing the verifier it is reported" "the verifier is not installed by the render job's own step" "$(verdict "$WORK/c/other-install.yml")"
check "a step that only echoes the product check is reported" "the product check is not run exactly once" "$(verdict "$WORK/c/echoed.yml")"
check "without the product check the workflow is reported" "the product check is not run exactly once" "$(verdict "$WORK/c/dropped.yml")"
check "with the checks swapped the workflow is reported" "the product check runs after the download check" "$(verdict "$WORK/c/swapped.yml")"
check "with continue-on-error on the job that holds the product check it is reported" "the job that holds the product check can be skipped or can fail without failing the workflow" "$(verdict "$WORK/c/job-soft.yml")"
check "with a condition on the job that holds the product check it is reported" "the job that holds the product check can be skipped or can fail without failing the workflow" "$(verdict "$WORK/c/job-if.yml")"
check "with the checks in different jobs it is reported" "the two checks are in different jobs" "$(verdict "$WORK/c/split.yml")"
check "with continue-on-error on the product check it is reported" "the product check can be skipped or can fail without stopping the job" "$(verdict "$WORK/c/softened.yml")"

# The push trigger is not filtered by the files the job runs, unlike the bucket's: a push of the updater app is judged
# by this workflow for what it wrote (Formula/**), and tests/ci/policy/workflows/push-runs-only-what-main-owns.test.sh holds
# that list to what update.yml commits. The daily schedule is what reads a change of the scripts.


echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
