#!/usr/bin/env bash
#
# The updater app's private key lives in exactly one job of update.yml, and
# that job runs no Homebrew and commits only the bytes the render job recorded.
#
# `brew style` and `brew audit` install Ruby gems from RubyGems when the ones
# they need are missing. When they ran in the job that then minted the app's
# token and committed whatever was in the workspace, that code could rewrite a
# formula, or the tools the commit step runs, before the step that used the
# token. Three properties keep the split meaningful, and each has its own
# assertion here:
#
#   (a) the only job that references a secret is `commit`, it runs no `brew`
#       and installs nothing, and the other two jobs hold no secret;
#   (b) `commit` needs both `render` and `validate`, with no condition that
#       would run it after either failed;
#   (c) before the commit step, `commit` checks the files against the digests
#       the render job put in its outputs, not against a file in the artifact,
#       and holds them to the roster again.
#
# The structure is read with PyYAML and every rule is first shown reporting a
# planted break in a copy of the live workflow. The check step of (c) is then
# extracted and executed against a render, a tampered artifact, a tampered
# artifact that carries a matching manifest of its own, and another parent.
#
# Requires: python3 with PyYAML, git, jq.
# The plants carry literal `${{ }}` and `$VAR` into Python; single quotes are the point.
# shellcheck disable=SC2016
set -euo pipefail
HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../fixtures/publication" && pwd)"
# shellcheck disable=SC1091
. "$HERE_FIXTURE/update-fixture.sh"
pass=0
fail=0

# Prints one line per broken rule, nothing when the workflow keeps all three.
rules() { # $1 = workflow file
	python3 -I - "$1" <<'PY'
import re, sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
jobs = doc.get("jobs") or {}
SECRET = re.compile(r"(?<!\w)secrets(?:\.|\[)")
BREW = re.compile(r"(^|[\s;&|(])brew(\s|$)")
INSTALL = re.compile(r"\b(apt-get|apt|pip3?|gem|npm|cargo|go)\s+(install|i)\b|\bbrew\b")
ALLOWED_USES = ("actions/checkout@", "actions/download-artifact@", "actions/create-github-app-token@")


def runs(step):
    return [l for l in str(step.get("run", "")).splitlines() if l.strip() and not l.lstrip().startswith("#")]


def text(node):
    return yaml.safe_dump(node)


# (a) who holds the key, and what that job runs
holders = sorted(j for j, job in jobs.items() if SECRET.search(text(job)))
if holders != ["commit"]:
    print(f"(a) the jobs referencing a secret are {holders}, not ['commit']")
commit = jobs.get("commit") or {}
for step in commit.get("steps") or []:
    for line in runs(step):
        if BREW.search(line) or INSTALL.search(line):
            print(f"(a) the commit job runs `{line.strip()}`")
    uses = step.get("uses")
    if uses and not uses.startswith(ALLOWED_USES):
        print(f"(a) the commit job uses {uses}")
for name in ("render", "validate", "commit"):
    if (jobs.get(name) or {}).get("permissions") != {"contents": "read"}:
        print(f"(a) the {name} job does not hold contents: read alone")

# (b) the commit job runs only after both succeeded
needs = commit.get("needs") or []
needs = [needs] if isinstance(needs, str) else needs
for dep in ("render", "validate"):
    if dep not in needs:
        print(f"(b) the commit job does not need {dep}")
if "if" in commit:
    print(f"(b) the commit job carries a condition: {commit['if']}")
for name in ("render", "validate", "commit"):
    job = jobs.get(name) or {}
    if job.get("continue-on-error") or any(s.get("continue-on-error") for s in job.get("steps") or []):
        print(f"(b) the {name} job lets a failure through")

# (c) the digest is checked, from the render job's outputs, before the commit
steps = commit.get("steps") or []
def index(pred):
    return next((n for n, s in enumerate(steps) if pred(s)), None)
place = index(lambda s: any(re.match(r"bash \./scripts/artifacts/formulae-digests\.sh place ", l.strip()) for l in runs(s)))
roster = index(lambda s: any(l.strip() == "bash ./scripts/artifacts/check-formulae.sh" for l in runs(s)))
mint = index(lambda s: str(s.get("uses", "")).startswith("actions/create-github-app-token@"))
publish = index(lambda s: "createCommitOnBranch" in str(s.get("run", "")))
if place is None or publish is None or not place < publish:
    print("(c) no step checks the digests before the commit step")
elif mint is None or not place < mint:
    print("(c) the digests are checked after the key is used")
if roster is None or publish is None or not roster < publish:
    print("(c) the commit job does not hold the files to the roster before the commit step")
if place is not None and (steps[place].get("env") or {}).get("RENDERED_DIGESTS") != "${{ needs.render.outputs.digests }}":
    print("(c) the digests do not come from the render job's outputs")
if any("formulae.sha256" in l for s in steps for l in runs(s)):
    print("(c) the commit job reads the manifest the artifact carries")
render = jobs.get("render") or {}
recorder = next((s for s in render.get("steps") or [] if s.get("id") == "digests"), {})
if (render.get("outputs") or {}).get("digests") != "${{ steps.digests.outputs.digests }}" \
        or not any(l.strip().startswith("bash ./scripts/artifacts/formulae-digests.sh list ") for l in runs(recorder)):
    print("(c) the render job does not record the digests in its outputs")
PY
}

check "the live workflow keeps all three rules" "" "$(rules "$WORKFLOW")"

# Each plant edits a copy of the live workflow, must change it, and must be
# reported under the rule it breaks.
plant() { # $1 = name, $2 = expected text in the report, $3 = python edit of doc
	local copy="$WORK/plant-$1.yml"
	python3 -I - "$WORKFLOW" "$copy" "$3" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
jobs = doc["jobs"]
steps = jobs["commit"]["steps"]
def named(job, prefix):
    return next(s for s in jobs[job]["steps"] if str(s.get("name", "")).startswith(prefix))
exec(sys.argv[3])
open(sys.argv[2], "w").write(yaml.safe_dump(doc, sort_keys=False))
PY
	if [ "$(python3 -I -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1])) == yaml.safe_load(open(sys.argv[2])))' "$WORKFLOW" "$copy")" = True ]; then
		check "plant $1 changed the workflow" "changed" "unchanged"
		return
	fi
	check "plant $1 is reported" "1" "$(rules "$copy" | grep -cF -- "$2" | awk '{print ($1 > 0)}')"
}

plant brew-in-commit "(a) the commit job runs" \
	'c = named("commit", "Check the rendered"); c["run"] += "brew style Formula/*.rb\n"'
plant install-in-commit "(a) the commit job runs" \
	'c = named("commit", "Check the rendered"); c["run"] += "sudo apt-get install -y ruby\n"'
plant mint-in-validate "(a) the jobs referencing a secret are ['commit', 'validate']" \
	'jobs["validate"]["steps"].append(named("commit", "Mint a token"))'
plant third-party-action "(a) the commit job uses" \
	'steps.insert(0, {"uses": "someone/action@0000000000000000000000000000000000000000"})'
plant write-permission "(a) the validate job does not hold contents: read alone" \
	'jobs["validate"]["permissions"] = {"contents": "write"}'
plant unneeded-validate "(b) the commit job does not need validate" \
	'jobs["commit"]["needs"] = ["render"]'
plant always "(b) the commit job carries a condition" \
	'jobs["commit"]["if"] = "${{ always() }}"'
plant ignored-audit "(b) the validate job lets a failure through" \
	'named("validate", "Validate the re-rendered")["continue-on-error"] = True'
plant check-after-commit "(c) no step checks the digests before the commit step" \
	'c = named("commit", "Check the rendered"); steps.remove(c); steps.append(c)'
plant check-after-mint "(c) the digests are checked after the key is used" \
	'c = named("commit", "Check the rendered"); steps.remove(c); steps.insert(steps.index(named("commit", "Commit the update")), c)'
plant no-place "(c) no step checks the digests before the commit step" \
	'c = named("commit", "Check the rendered"); c["run"] = c["run"].replace("bash ./scripts/artifacts/formulae-digests.sh place", ": ./scripts/artifacts/formulae-digests.sh place")'
plant no-roster "(c) the commit job does not hold the files to the roster" \
	'c = named("commit", "Check the rendered"); c["run"] = c["run"].replace("bash ./scripts/artifacts/check-formulae.sh", ":")'
plant digests-from-validate "(c) the digests do not come from the render job's outputs" \
	'named("commit", "Check the rendered")["env"]["RENDERED_DIGESTS"] = "${{ needs.validate.outputs.digests }}"'
plant digests-from-artifact "(c) the commit job reads the manifest the artifact carries" \
	'c = named("commit", "Check the rendered"); c["run"] = c["run"].replace("\"$expected\"\n", "\"$RUNNER_TEMP/rendered/formulae.sha256\"\n")'
plant no-record "(c) the render job does not record the digests" \
	'del jobs["render"]["outputs"]["digests"]'

# --- the check step, executed ------------------------------------------------
RECORD="$WORK/record.sh"
VERIFY="$WORK/verify.sh"
step_script "Record the digest of every rendered file" > "$RECORD"
step_script "Check the rendered bytes against" > "$VERIFY"
check "the record step was extracted from the workflow" "1" "$(grep -c 'formulae-digests.sh list' "$RECORD")"
check "the check step was extracted from the workflow" "1" "$(grep -c 'formulae-digests.sh place' "$VERIFY")"

# Render in one sandbox, as the render job does, and record.
sandbox "$WORK/r" 0 digest
mkdir -p "$WORK/r-tmp"
rc=0; run_step "$RENDER" "$WORK/r" || rc=$?
check "the render changed a digest" "1" "$(output changed)"
rc=0; ( cd "$WORK/r" && RUNNER_TEMP="$WORK/r-tmp" GITHUB_OUTPUT="$WORK/gh-output" bash "$RECORD" ) > "$WORK/out" 2>&1 || rc=$?
check "the record step succeeds" "0" "$rc"
digests="$(output digests)"
head="$(output head)"
check "and records the head it rendered from" "$(git -C "$WORK/r" rev-parse HEAD)" "$head"

# The commit job: a fresh clone of the same head, and the artifact downloaded
# into its temporary directory.
verify() { # $1 = case name; uses $digests and $head
	rm -rf "$WORK/k" "$WORK/k-tmp"
	git clone -q "$WORK/r" "$WORK/k"
	mkdir -p "$WORK/k-tmp"
	cp -R "$WORK/r-tmp/rendered" "$WORK/k-tmp/rendered"
	[ "$1" = good ] || [ "$1" = parent ] || tamper "$1"
	rc=0
	( cd "$WORK/k" && RUNNER_TEMP="$WORK/k-tmp" RENDERED_DIGESTS="$digests" RENDERED_HEAD="$head" bash "$VERIFY" ) \
		> "$WORK/out" 2>&1 || rc=$?
}
tamper() { # $1 = case name
	printf '# appended\n' >> "$WORK/k-tmp/rendered/Formula/podup.rb"
	if [ "$1" = forged ]; then
		( cd "$WORK/k-tmp/rendered" && sha256sum Formula/podup.rb ) > "$WORK/k-tmp/rendered/formulae.sha256"
	fi
}

verify good
check "the recorded bytes pass" "0" "$rc"
check "and are what the checkout now holds" "" "$(diff -r "$WORK/r/Formula" "$WORK/k/Formula")"
check "so the commit step sees the render's change" "Formula/podup.rb" "$(git -C "$WORK/k" diff --name-only)"

verify tampered
check "a byte changed in the artifact is refused" "1" "$rc"
check "and the message says the files are not the recorded ones" "1" "$(grep -c 'are not the ones the render job recorded' "$WORK/out")"
check "and the checkout is untouched" "" "$(git -C "$WORK/k" status --porcelain)"

verify forged
check "a changed artifact carrying its own matching manifest is still refused" "1" "$rc"
check "and the checkout is untouched" "" "$(git -C "$WORK/k" status --porcelain)"

head="0000000000000000000000000000000000000000"
verify parent
check "a checkout at another parent than the render's is refused" "1" "$rc"
check "and the message names the parent" "1" "$(grep -c 'refusing to commit against another parent' "$WORK/out")"
head="$(git -C "$WORK/r" rev-parse HEAD)"

digests=""
verify good
check "no recorded digests is a refusal, not a pass" "1" "$rc"
digests="$(output digests)"

# Bytes the render recorded and the roster refuses: the record step does not
# judge, so the commit job's own roster check is what stops them.
sandbox "$WORK/r" 0 yes
rm -rf "$WORK/r-tmp"; mkdir -p "$WORK/r-tmp"
rc=0; run_step "$RENDER" "$WORK/r" || rc=$?
( cd "$WORK/r" && RUNNER_TEMP="$WORK/r-tmp" GITHUB_OUTPUT="$WORK/gh-output" bash "$RECORD" ) > /dev/null 2>&1
digests="$(output digests)"
head="$(output head)"
verify good
check "recorded bytes the roster refuses are stopped in the commit job" "1" "$rc"
check "by the roster check" "1" "$(grep -c 'do not match what scripts/release/render-formulae.sh emits' "$WORK/out")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
