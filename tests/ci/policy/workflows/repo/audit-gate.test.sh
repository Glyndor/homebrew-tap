#!/usr/bin/env bash
# The check a ruleset requires from audit.yml is the `audit gate` job, because a
# job skipped by the scope decision reports Success whatever the reason it was
# skipped. This runs the real step of the gate with the values GitHub would give
# it and holds it to three rules:
#
#   * a scope job that did not succeed fails the gate, whatever the audit did,
#     because nothing then says the audit was not needed;
#   * an audit skipped without the scope job saying `false` fails the gate;
#   * an audit skipped because the scope job said `false` passes it, and so does
#     an audit that ran and passed.
#
# A cancelled needs fails it too. No Homebrew or network is needed. PyYAML is
# installed by CI.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
python3 -I - "$HERE" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

import yaml

root = Path(sys.argv[1])
doc = yaml.safe_load((root / ".github/workflows/audit.yml").read_text())
gate = doc["jobs"]["gate"]
audit = doc["jobs"]["audit"]
step = gate["steps"][0]
passed = failed = 0


def check(name, expected, actual):
	global passed, failed
	if expected == actual:
		passed += 1
		print(f"ok    {name}")
	else:
		failed += 1
		print(f"FAIL  {name}: expected {expected!r}, got {actual!r}")


check("the gate is the check a ruleset names", "audit gate", gate["name"])
check("the gate runs whatever the other jobs did", "always()", gate.get("if"))
check("the gate waits for the scope job and the audit", ["scope", "audit"], gate.get("needs"))
check("the gate has no continue-on-error", None, gate.get("continue-on-error"))
check("the gate is bounded", 5, gate["timeout-minutes"])
check("the gate runs on a named image", "ubuntu-26.04", gate["runs-on"])
check("the gate is a single step", 1, len(gate["steps"]))
check("the gate step has no condition of its own", None, step.get("if"))
check("the audit keeps the name it always had", "brew audit", audit["name"])
check("the gate reads the scope result from env", "${{ needs.scope.result }}", step["env"]["SCOPE"])
check("the gate reads the scope answer from env", "${{ needs.scope.outputs.run_audit }}", step["env"]["RUN_AUDIT"])
check("the gate reads the audit result from env", "${{ needs.audit.result }}", step["env"]["AUDIT"])
check("nothing of the event is interpolated into the script", False, "${{" in step["run"])


def verdict(scope, run_audit, audit_result):
	env = dict(os.environ, SCOPE=scope, RUN_AUDIT=run_audit, AUDIT=audit_result)
	done = subprocess.run(["bash", "-c", step["run"]], env=env, capture_output=True, text=True)
	return done.returncode == 0


# (scope result, run_audit output, audit result) -> does the gate pass
cases = [
	("success", "false", "skipped", True, "an audit the scope job found unneeded passes"),
	("success", "true", "success", True, "an audit that ran and passed passes"),
	("success", "", "success", True, "an audit that ran for want of an answer, and passed, passes"),
	("success", "true", "skipped", False, "an audit skipped although the scope job asked for it fails"),
	("success", "", "skipped", False, "an audit skipped with no answer from the scope job fails"),
	("success", "garbage", "skipped", False, "an audit skipped on an answer that is neither true nor false fails"),
	("success", "false", "success", False, "an audit that ran against the scope answer is an inconsistent run and fails"),
	("success", "true", "failure", False, "a failed audit fails"),
	("success", "false", "failure", False, "a failed audit fails whatever the scope said"),
	("success", "true", "cancelled", False, "a cancelled audit fails"),
	("failure", "", "skipped", False, "a failed scope job fails even though the audit was skipped"),
	("failure", "", "success", False, "a failed scope job fails even though the audit passed"),
	("failure", "false", "skipped", False, "a failed scope job fails whatever it printed"),
	("cancelled", "", "skipped", False, "a cancelled scope job fails"),
	("skipped", "", "skipped", False, "a skipped scope job fails"),
]
for scope, run_audit, audit_result, expected, name in cases:
	check(name, expected, verdict(scope, run_audit, audit_result))

# The audit job itself starts unless the scope job said `false`, so a failed or
# silent scope job leaves it running and the gate red.
check("the audit starts when the scope output is missing", True, "!= 'false'" in audit["if"])
check("the audit never starts on a cancelled run", True, "!cancelled()" in audit["if"])
check("the audit does not wait for the scope job to have succeeded", False, "result" in audit["if"])
check("the audit does not read the answer as a true", False, "== 'true'" in audit["if"])

print(f"\n{passed} passed, {failed} failed")
print(f"DONE audit-gate.test.sh {passed} {failed}")
sys.exit(1 if failed else 0)
PY
