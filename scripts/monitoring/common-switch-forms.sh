#!/usr/bin/env bash
#
# The part of switch-rule-forms.json that the two channel repositories have to agree on.
#
#   common-switch-forms.sh <mine> <sibling> <list> <mine-out> <sibling-out>
#
# The forms of a few jobs are of each repository: its update and the report of what its app pushed wait for jobs that
# only it has. <list> names them, one 'section<TAB>workflow<TAB>job' per line (differing-switch-forms.txt, itself a
# shared copy). Both files are written out without those entries, and everything else of them, for the caller to compare
# as text. An entry of the list under which the two files say the same is refused: it would leave a job out of the
# comparison for nothing. So is anything that cannot be read.
set -euo pipefail

[ "$#" -eq 5 ] || { echo "::error::usage: common-switch-forms.sh <mine> <sibling> <list> <mine-out> <sibling-out>" >&2; exit 2; }
python3 -I - "$@" <<'PY'
import json
import sys

mine_path, sibling_path, list_path, mine_out, sibling_out = sys.argv[1:]
SECTIONS = ("conditional_jobs", "step_conditions")


def stop(message):
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def forms(path):
    def once(pairs):
        keys = [k for k, _ in pairs]
        if len(set(keys)) != len(keys):
            raise ValueError("a key is written twice")
        return dict(pairs)

    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle, object_pairs_hook=once)
    except (OSError, ValueError) as error:
        stop(f"{path} cannot be read as the forms of the switch rule: {error}")
    if not isinstance(data, dict) or any(
            not isinstance(data.get(s), list) or any(not isinstance(e, dict) or "file" not in e or "job" not in e for e in data[s])
            for s in SECTIONS):
        stop(f"{path} does not hold the lists {' and '.join(SECTIONS)} of entries with a file and a job")
    return data


try:
    with open(list_path, encoding="utf-8") as handle:
        lines = [line for line in handle.read().split("\n") if line.strip() and not line.startswith("#")]
except OSError as error:
    stop(f"cannot read {list_path}: {error.strerror}")
differing = []
for line in lines:
    fields = line.split("\t")
    if len(fields) != 3 or fields[0] not in SECTIONS or not all(fields):
        stop(f"{list_path}: '{line}' is not 'section<TAB>workflow<TAB>job', with a section of {' or '.join(SECTIONS)}")
    if tuple(fields) in differing:
        stop(f"{list_path} lists '{line}' twice")
    differing.append(tuple(fields))

mine, sibling = forms(mine_path), forms(sibling_path)


def entries(data, section, workflow, job):
    return [e for e in data[section] if (e["file"], e["job"]) == (workflow, job)]


for section, workflow, job in differing:
    if entries(mine, section, workflow, job) == entries(sibling, section, workflow, job):
        stop(f"{list_path} leaves {section} of {job} in {workflow} out of the comparison and the two copies say the same there: take the line off")
for data, out in ((mine, mine_out), (sibling, sibling_out)):
    for section in SECTIONS:
        data[section] = [e for e in data[section] if (section, e["file"], e["job"]) not in differing]
    with open(out, "w", encoding="utf-8") as handle:
        for key, value in data.items():
            # One entry a line, so that a difference names the entry it is in.
            handle.write(f"{json.dumps(key)}:\n")
            items = value if isinstance(value, list) else [value]
            for item in items:
                handle.write("  " + json.dumps(item) + "\n")
PY
