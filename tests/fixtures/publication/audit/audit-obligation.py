#!/usr/bin/env python3
"""Check audit ordering and exercise failure propagation in an isolated tap."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import yaml


def first(lines, prefix):
	return next((i for i, line in enumerate(lines) if line.startswith(prefix)), None)


def lines(step):
	return [line.strip() for line in step.get("run", "").splitlines()
		if line.strip() and not line.lstrip().startswith("#")]


# A job-level condition that calls one of these runs the job whatever its
# dependencies concluded, so a commit job carrying one commits after a failed
# audit. `cancelled()` covers `!cancelled()`.
STATUS_FUNCTIONS = ("always()", "cancelled()", "failure()")


def obligation(job, step, allowed_if=None):
	# The only condition allowed is the one the commit step carries too: no
	# formula changed, so there is nothing to audit and nothing to publish.
	# Any other condition (false, always(), a different output) can switch the
	# audit off while the commit still happens.
	if "if" in step and step["if"] != allowed_if:
		return "the audit step is conditional"
	if step.get("continue-on-error", False) is not False:
		return "the audit step ignores failure"
	if job.get("continue-on-error", False) is not False:
		return "the audit job ignores failure"
	with tempfile.TemporaryDirectory() as tmp:
		root = Path(tmp)
		(root / "Formula").mkdir()
		(root / "Formula/probe.rb").touch()
		(root / "bin").mkdir()
		# update.yml validates the formulae before it reaches brew. That check has
		# its own suite (tests/artifacts/check-formulae.test.sh); here it is a
		# no-op, because this probe only follows the order of link, trust and
		# audit and a probe formula would not satisfy the real check.
		(root / "scripts/artifacts").mkdir(parents=True)
		stub = root / "scripts/artifacts/check-formulae.sh"
		stub.write_text("#!/usr/bin/env bash\nexit 0\n")
		stub.chmod(0o755)
		(root / "homebrew").mkdir()
		brew = root / "bin/brew"
		brew.write_text("""#!/usr/bin/env bash
case "$1" in
  --repository) printf '%s\\n' "$PROBE_ROOT/homebrew" ;;
  shellenv|style) : ;;
  trust) echo trust >> "$PROBE_ROOT/trace" ;;
  audit) echo audit >> "$PROBE_ROOT/trace"; exit 71 ;;
  *) exit 90 ;;
esac
""")
		brew.chmod(0o755)
		env = dict(os.environ, PROBE_ROOT=tmp, GITHUB_WORKSPACE=tmp,
			tap_dir=str(root / "homebrew/tap"), PATH=f"{root / 'bin'}:{os.environ['PATH']}")
		# The update step uses this absolute runner path for shellenv only.
		# Resolve it to the same fake brew used by the rest of the step.
		script = step["run"].replace("/home/linuxbrew/.linuxbrew/bin/brew", str(brew))
		result = subprocess.run(["bash", "-eo", "pipefail", "-c", script],
			cwd=tmp, env=env, capture_output=True, timeout=10)
		trace = (root / "trace").read_text().splitlines() if (root / "trace").exists() else []
		if "audit" not in trace:
			return "the audit is not reached"
		if result.returncode == 0:
			return "the audit failure is swallowed"
	return "ok"


def find(jobs, needle):
	# The first (job id, step index) whose run lines start with, or for the
	# commit contain, the needle.
	for job_id, job in jobs.items():
		for n, step in enumerate(job.get("steps") or []):
			ls = lines(step)
			if (first(ls, needle) is not None if needle == "brew audit"
					else any(needle in line for line in ls)):
				return job_id, n
	return None, None


def update_order(jobs):
	# The audit and the commit live in different jobs, and the commit job must
	# need the audit job with the default rule: a job runs only when the jobs
	# it needs succeeded, unless its own condition calls a status function.
	# The shape of one job with the audit step before the commit step is still
	# understood, so the failure message says what moved.
	audit_job, audit = find(jobs, "brew audit")
	if audit_job is None:
		return None, "no step runs brew audit"
	commit_job, commit = find(jobs, "createCommitOnBranch")
	if commit_job is None:
		return None, "no step creates the commit"
	if commit_job == audit_job:
		if audit >= commit:
			return None, "the audit does not run before the commit"
		return (audit_job, audit), None
	needs = jobs[commit_job].get("needs") or []
	needs = [needs] if isinstance(needs, str) else needs
	if audit_job not in needs:
		return None, "the commit job does not need the audit job"
	condition = str(jobs[commit_job].get("if", ""))
	if any(fn in condition for fn in STATUS_FUNCTIONS):
		return None, "the commit job runs whatever the audit concluded"
	return (audit_job, audit), None


def order(doc, mode):
	allowed_if = None
	if mode == "update":
		found, problem = update_order(doc["jobs"])
		if problem:
			return problem
		job = doc["jobs"][found[0]]
		steps = job["steps"]
		audit = found[1]
		commit_job, commit = find(doc["jobs"], "createCommitOnBranch")
		allowed_if = doc["jobs"][commit_job]["steps"][commit].get("if")
	else:
		job = doc["jobs"]["audit"]
		steps = job["steps"]
		audit = next((n for n, s in enumerate(steps) if first(lines(s), "brew audit") is not None), None)
		if audit is None:
			return "the audit step has no link or no audit command"
	ls = lines(steps[audit])
	link, trust, command = first(ls, "ln -s"), first(ls, "brew trust glyndor/tap"), first(ls, "brew audit")
	if mode == "audit" and link is None:
		return "the audit step has no link or no audit command"
	if mode == "audit" and trust is None:
		return "the audit step never trusts the tap"
	if link is None or trust is None or not link < trust < command:
		return "the order is not link, trust, audit"
	if mode == "update" and "--strict" not in ls[command]:
		return "the audit is not strict"
	return obligation(job, steps[audit], allowed_if)


if __name__ == "__main__":
	print(order(yaml.safe_load(Path(sys.argv[1]).read_text()), sys.argv[2]))
