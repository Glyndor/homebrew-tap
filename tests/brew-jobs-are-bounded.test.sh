#!/usr/bin/env bash
#
# Every job that runs `brew` is bounded, and brew is told not to update itself.
#
# `brew style` on pull request #56 started at 16:39:48 and was killed at
# 17:24:48: forty-five minutes of wall time, on a one-line change the tool does
# not read, because brew updated itself first over a slow network and the job
# had no bound. The sibling job in the same file had both variables and a
# ten-minute limit and finished in forty seconds on the same commit.
#
# That rule lived in tests.yml as a comment, and update.yml -- the job that
# commits to `main` every hour -- ran the same tool with neither variable and no
# bound for weeks. A rule in prose is followed where somebody remembered it.
# This test reads every workflow and refuses a job that invokes `brew` without
# `timeout-minutes` and without `HOMEBREW_NO_AUTO_UPDATE` reachable from the
# job (job `env:` or workflow `env:`).
#
# Comments are not invocations: a job whose only mention of brew is in a `#`
# line is not held to the rule, so the planted fixture below has to be a real
# `run:` line, and the check is shown reporting it before the live workflows
# are read. Without that control this test would agree with any tree.
#
# Requires: python3 with PyYAML (the same interpreter tests.yml already
# installs nothing for; python3-yaml is on the runner image).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

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

# Prints one line per offending job: "<file> job <id>: <what is missing>".
# Exit 1 when any line was printed, 0 otherwise.
audit() { # $1=workflows dir
	python3 - "$1" <<'PY'
import glob, os, re, sys
import yaml

root = sys.argv[1]
bad = 0
for path in sorted(glob.glob(os.path.join(root, "*.yml"))):
	with open(path) as f:
		doc = yaml.safe_load(f) or {}
	top_env = doc.get("env") or {}
	for job_id, job in (doc.get("jobs") or {}).items():
		if not isinstance(job, dict):
			continue
		runs = [s.get("run", "") for s in (job.get("steps") or []) if isinstance(s, dict)]
		# Strip comment lines before looking for brew, so a `# brew ...` note
		# in a run block does not put the job under the rule.
		code = "\n".join(
			l for r in runs for l in str(r).splitlines() if not l.lstrip().startswith("#")
		)
		if not re.search(r"(^|[\s;&|(])brew\s", code):
			continue
		env = dict(top_env)
		env.update(job.get("env") or {})
		missing = []
		if "timeout-minutes" not in job:
			missing.append("timeout-minutes")
		if "HOMEBREW_NO_AUTO_UPDATE" not in env:
			missing.append("HOMEBREW_NO_AUTO_UPDATE")
		if missing:
			bad += 1
			print(f"{os.path.basename(path)} job {job_id}: missing {', '.join(missing)}")
sys.exit(1 if bad else 0)
PY
}

# --- the control: a planted violation is reported ---------------------------
mkdir -p "$WORK/planted"
cat > "$WORK/planted/bad.yml" <<'EOF'
name: bad
on: push
jobs:
  style:
    runs-on: ubuntu-latest
    steps:
      - run: brew style Formula/*.rb
  only-a-comment:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: |
          # brew is only mentioned here
          echo fine
  bounded:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    env:
      HOMEBREW_NO_AUTO_UPDATE: "1"
    steps:
      - run: brew audit --strict x
EOF
rc=0; out="$(audit "$WORK/planted")" || rc=$?
check "a brew job with neither bound nor variable is reported" "1" "$rc"
check "and the report names the job and what it lacks" "1" \
	"$(printf '%s\n' "$out" | grep -c 'bad.yml job style: missing timeout-minutes, HOMEBREW_NO_AUTO_UPDATE')"
check "a job that only mentions brew in a comment is not held to the rule" "0" \
	"$(printf '%s\n' "$out" | grep -c 'only-a-comment')"
check "a bounded job with the variable is not reported" "0" \
	"$(printf '%s\n' "$out" | grep -c 'job bounded')"

# A workflow-level env: satisfies the variable half.
mkdir -p "$WORK/toplevel"
cat > "$WORK/toplevel/top.yml" <<'EOF'
name: top
on: push
env:
  HOMEBREW_NO_AUTO_UPDATE: "1"
jobs:
  style:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: brew style Formula/*.rb
EOF
rc=0; audit "$WORK/toplevel" >/dev/null || rc=$?
check "a workflow-level env satisfies the variable half" "0" "$rc"

# --- the live workflows -----------------------------------------------------
rc=0; out="$(audit "$HERE/.github/workflows")" || rc=$?
check "every job in this repository that runs brew is bounded and told not to update" "0" "$rc"
[ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/        /'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
