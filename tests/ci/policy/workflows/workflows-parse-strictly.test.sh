#!/usr/bin/env bash
# The workflows, and every other YAML file GitHub reads from `.github`, are read
# here the way GitHub reads them, because a validator that reads them more
# loosely misses what GitHub runs.
#
# Two things the rules that parse the workflows (check-test-job-not-switchable.sh,
# check-tooling-isolation.sh) cannot see for themselves:
#
#   * a key written twice in one mapping. PyYAML keeps the last and says nothing,
#     so a rule that reads `if:` or `needs:` of a job reads one of the two the
#     author wrote, and which of them GitHub runs is not the rule's business;
#   * a workflow or action file the rules did not list. They read
#     `.github/workflows/*.yml` and `*.yaml`; a file under `.github/actions/`, or
#     any `.yml` or `.yaml` anywhere under `.github`, is counted here by one
#     enumerator (rglob over both suffixes) and has to parse strictly as well.
#
# The loader refuses a duplicate key in any mapping, anchors and merge keys
# included, and the checker is shown to refuse it on planted files first.
# Requires: bash, python3 with PyYAML.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
python3 -I - "$HERE" <<'PY'
import sys
import tempfile
from pathlib import Path

import yaml

passed = failed = 0


class Strict(getattr(yaml, "CSafeLoader", yaml.SafeLoader)):
    def construct_mapping(self, node, deep=False):
        seen = set()
        for key_node, _ in node.value:
            key = self.construct_object(key_node, deep=True)
            if isinstance(key, (list, dict)):
                continue
            if key in seen:
                raise yaml.YAMLError(f"duplicate key {key!r} at line {key_node.start_mark.line + 1}")
            seen.add(key)
        return super().construct_mapping(node, deep)


def yaml_files(root):
    """The one enumerator: every .yml and .yaml under .github, workflows and actions alike."""
    base = Path(root) / ".github"
    return sorted(p for p in base.rglob("*") if p.is_file() and p.suffix in (".yml", ".yaml"))


def problems(root):
    found = []
    for path in yaml_files(root):
        try:
            yaml.load(path.read_text(), Loader=Strict)
        except yaml.YAMLError as exc:
            found.append(f"{path.relative_to(root)}: {exc}")
    return found


def check(label, expected, actual):
    global passed, failed
    if expected == actual:
        passed += 1
        print(f"ok    {label}")
    else:
        failed += 1
        print(f"FAIL  {label}: expected {expected!r}, got {actual!r}")


def planted(name, text):
    with tempfile.TemporaryDirectory() as root:
        target = Path(root) / ".github" / name
        target.parent.mkdir(parents=True)
        target.write_text(text)
        return problems(root), [str(p.relative_to(root)) for p in yaml_files(root)]


sound = "jobs:\n  a:\n    if: x\n    needs: b\n"
check("a file with no duplicate key is accepted", ([], [".github/workflows/w.yml"]), planted("workflows/w.yml", sound))
dup_if = "jobs:\n  a:\n    if: x\n    needs: b\n    if: always()\n"
check("a job with two if: is refused, naming the key and the line",
      (["workflows/w.yml: duplicate key 'if' at line 5"], [".github/workflows/w.yml"]),
      (lambda r: ([m.replace(".github/", "") for m in r[0]], r[1]))(planted("workflows/w.yml", dup_if)))
dup_job = "jobs:\n  a:\n    if: x\n  a:\n    if: y\n"
check("a job id written twice is refused", 1, len(planted("workflows/w.yml", dup_job)[0]))
check("a workflow written with the .yaml suffix is enumerated and read", 1, len(planted("workflows/w.yaml", dup_if)[0]))
check("a file under .github/actions is enumerated and read", 1, len(planted("actions/x/action.yml", dup_if)[0]))
check("a .yaml file in a folder nobody listed is enumerated and read", 1, len(planted("other/deep/x.yaml", dup_if)[0]))
check("the same key at two levels is not a duplicate", 0, len(planted("workflows/w.yml", "a:\n  if: 1\nb:\n  if: 2\n")[0]))

check("every YAML file of this repository is read strictly", [], problems(sys.argv[1]))
check("and the enumerator sees at least the workflows", True, len(yaml_files(sys.argv[1])) >= 1)

print(f"\n{passed} passed, {failed} failed")
print(f"DONE workflows-parse-strictly.test.sh {passed} {failed}")
sys.exit(1 if failed else 0)
PY
