#!/usr/bin/env bash
# Execute the real scope block in disposable git repositories, not a copy of
# its decision logic. No Homebrew or network is needed. PyYAML is installed by CI.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
python3 - "$HERE" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import yaml

root = Path(sys.argv[1])
doc = yaml.safe_load((root / ".github/workflows/audit.yml").read_text())
scope = doc["jobs"]["scope"]
audit = doc["jobs"]["audit"]
step = next(s for s in scope["steps"] if s.get("id") == "scope")
passed = failed = 0


def check(name, expected, actual):
	global passed, failed
	if expected == actual:
		passed += 1
		print(f"ok    {name}")
	else:
		failed += 1
		print(f"FAIL  {name}: expected {expected!r}, got {actual!r}")


check("scope uses Linux", "ubuntu-latest", scope["runs-on"])
check("scope has a short bound", 2, scope["timeout-minutes"])
checkout = next(s for s in scope["steps"] if s.get("uses", "").startswith("actions/checkout@"))
check("scope fetches the merge parent", 2, checkout["with"]["fetch-depth"])
check("scope does not persist credentials", False, checkout["with"]["persist-credentials"])
check("scope exposes its decision", "${{ steps.scope.outputs.run_audit }}", scope["outputs"]["run_audit"])
check("required check name survives", "brew audit", audit["name"])
check("audit depends on scope", "scope", audit["needs"])
check("audit runs on a true decision, or when scope itself failed", "always() && (needs.scope.result != 'success' || needs.scope.outputs.run_audit == 'true')", audit["if"])
check("audit stays on macOS", "macos-latest", audit["runs-on"])
triggers = doc.get("on", doc.get(True))
check("PR trigger has no paths filter", None, triggers["pull_request"])

with tempfile.TemporaryDirectory() as work:
	work = Path(work)
	output = work / "output"

	def git(repo, *args):
		return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)

	def repo(name):
		p = work / name
		git(work, "init", "-q", "-b", "main", str(p))
		git(p, "config", "user.name", "Scope test")
		git(p, "config", "user.email", "scope@example.invalid")
		git(p, "config", "commit.gpgsign", "false")
		(p / "Formula").mkdir()
		(p / "Formula/podup.rb").write_text("formula\n")
		git(p, "add", ".")
		git(p, "commit", "-qm", "base")
		return p

	def commit(p):
		git(p, "add", "-A")
		git(p, "commit", "--allow-empty", "-qm", "change")

	def run(p, event="pull_request"):
		output.write_text("")
		env = dict(os.environ, GITHUB_EVENT_NAME=event, GITHUB_OUTPUT=str(output))
		result = subprocess.run(["bash", "-c", step["run"]], cwd=p, env=env, capture_output=True, text=True)
		if result.returncode:
			return f"exit {result.returncode}: {result.stderr}"
		return output.read_text().strip()

	p = repo("docs")
	(p / "docs").mkdir()
	(p / "docs/guide.md").write_text("docs\n")
	commit(p)
	check("docs only skips macOS", "run_audit=false", run(p))
	for event in ("push", "schedule", "workflow_dispatch"):
		check(f"{event} always audits", "run_audit=true", run(p, event))

	for name in ("Formula/podup.rb", "Formula/nested/new.rb", ".github/workflows/audit.yml"):
		p = repo(name.replace("/", "-"))
		f = p / name
		f.parent.mkdir(parents=True, exist_ok=True)
		f.write_text("changed\n")
		commit(p)
		check(f"{name} audits", "run_audit=true", run(p))

	p = repo("unreadable")
	check("unreadable diff audits", "run_audit=true", run(p))
	commit(p)
	check("empty diff audits", "run_audit=true", run(p))

	for destination in ("Formula/renamed.rb", "docs/moved.rb"):
		p = repo(destination.replace("/", "-"))
		(p / destination).parent.mkdir(parents=True, exist_ok=True)
		git(p, "mv", "Formula/podup.rb", destination)
		commit(p)
		check(f"formula renamed to {destination} audits", "run_audit=true", run(p))

	p = repo("merge")
	git(p, "checkout", "-qb", "topic")
	(p / "Formula/podup.rb").write_text("changed\n")
	commit(p)
	git(p, "checkout", "-q", "main")
	git(p, "merge", "--no-ff", "-qm", "merge", "topic")
	check("PR merge compares against its first parent", "run_audit=true", run(p))

print(f"\n{passed} passed, {failed} failed")
print(f"DONE audit-scope.test.sh {passed} {failed}")
sys.exit(1 if failed else 0)
PY
