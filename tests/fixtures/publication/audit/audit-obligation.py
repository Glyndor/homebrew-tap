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


def obligation(job, step):
	# The only condition allowed is the one the commit step carries too: no
	# formula changed, so there is nothing to audit and nothing to publish.
	# Any other condition (false, always(), a different output) can switch the
	# audit off while the commit still happens.
	if "if" in step and step["if"] != "steps.render.outputs.changed == '1'":
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


def order(doc, mode):
	job = doc["jobs"]["audit"] if mode == "audit" else next(iter(doc["jobs"].values()))
	steps = job["steps"]
	audit = next((n for n, s in enumerate(steps) if first(lines(s), "brew audit") is not None), None)
	if audit is None:
		return "the audit step has no link or no audit command" if mode == "audit" else "no step runs brew audit"
	if mode == "update":
		commit = next((n for n, s in enumerate(steps)
			if any("createCommitOnBranch" in line for line in lines(s))), None)
		if commit is None:
			return "no step creates the commit"
		if audit >= commit:
			return "the audit does not run before the commit"
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
	return obligation(job, steps[audit])


if __name__ == "__main__":
	print(order(yaml.safe_load(Path(sys.argv[1]).read_text()), sys.argv[2]))
