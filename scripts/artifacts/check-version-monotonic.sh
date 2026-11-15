#!/usr/bin/env bash
#
# A pull request must not lower the version of a formula that is already
# committed. The renderer refuses a rollback when it renders, but a hand edit,
# or a render that was hijacked, can write an older tag in the urls with matching
# assets and digests, and check-formulae.sh accepts it because it holds a formula
# to its roster row, not to what the base branch already says. A formula has no
# version field: the version is the tag of its urls, without the leading v.
#
# Usage: check-version-monotonic.sh <base commit> [formula directory]
#
# Compares Formula/**/*.rb in the working tree with the same files at the base
# commit, with the SemVer precedence release_order uses in render-formulae.sh:
# pre-release below stable, numeric identifiers below text, build metadata
# ignored. An equal version passes; a formula new in the tree passes; a version
# that is not SemVer, in either side, is an error, so the gate cannot be
# bypassed by writing something it cannot order.
#
# A deliberate rollback is the one exception, and it takes two reviewed steps. A
# line `<formula path> <committed version> <version to roll back to>` in
# scripts/artifacts/approved-rollbacks.txt, read from the BASE commit and never
# from the pull request, permits exactly that formula to go from exactly that
# version to exactly that one. The line has to be merged first, as its own change,
# so the rollback cannot arrive together with the permission for it. A malformed
# line is an error. Anything not named there is still refused.
set -euo pipefail

base="${1:?usage: check-version-monotonic.sh <base commit> [formula directory]}"
dir="${2:-Formula}"

python3 -I - "$base" "$dir" <<'PY'
import os, re, subprocess, sys

base, directory = sys.argv[1:]
PATTERN = (r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
           r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
           r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?")


def fail(message):
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def git(*args):
    done = subprocess.run(["git", *args], capture_output=True, text=True)
    if done.returncode != 0:
        fail(f"git {' '.join(args)}: {done.stderr.strip()}")
    return done.stdout


def precedence(version, where):
    match = re.fullmatch(PATTERN, version) if isinstance(version, str) else None
    if not match:
        fail(f"{where}: {version!r} is not a valid SemVer release version")
    major, minor, patch, pre = match.groups()
    identifiers = [] if pre is None else pre.split(".")
    if any(i.isdigit() and len(i) > 1 and i[0] == "0" for i in identifiers):
        fail(f"{where}: invalid numeric pre-release in {version!r}")
    return (int(major), int(minor), int(patch), pre is None,
            tuple((0, int(i)) if i.isdigit() else (1, i) for i in identifiers))


APPROVALS = "scripts/artifacts/approved-rollbacks.txt"


def approved_rollbacks(base):
    """(formula, from, to) triples written in the approvals file at BASE."""
    done = subprocess.run(["git", "show", f"{base}:{APPROVALS}"],
                          capture_output=True, text=True)
    if done.returncode != 0:
        return set()
    approved = set()
    for number, raw in enumerate(done.stdout.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 3 or not fields[0].endswith(".rb"):
            fail(f"{APPROVALS}:{number} at {base}: expected '<formula path> <from> <to>'")
        precedence(fields[1], f"{APPROVALS}:{number}")
        precedence(fields[2], f"{APPROVALS}:{number}")
        approved.add(tuple(fields))
    return approved


TAG = re.compile(r"/releases/download/v([^/\s\"']+)/")


def version_of(text, where):
    tags = sorted(set(TAG.findall(text)))
    if len(tags) != 1:
        fail(f"{where}: expected the urls to name one release tag, found {len(tags)}")
    return tags[0]


git("rev-parse", "--verify", f"{base}^{{commit}}")
# A pathspec is read from the working directory, so a run from a subfolder saw
# no formula at all and approved every rollback. Everything below is relative
# to the root of the repository.
os.chdir(git("rev-parse", "--show-toplevel").strip())
names = [n for n in git("ls-tree", "-r", "--name-only", base, "--", directory + "/").split("\n")
         if n.lower().endswith(".rb")]
if not names:
    fail(f"no formula under {directory}/ at {base}: nothing was compared, and a gate that compares nothing approves everything")
approved = approved_rollbacks(base)
for name in names:
    try:
        with open(name, encoding="utf-8") as handle:
            current = handle.read()
    except FileNotFoundError:
        continue
    old_version = version_of(git("show", f"{base}:{name}"), f"{name} at {base}")
    old = precedence(old_version, f"{name} at {base}")
    new_version = version_of(current, name)
    if precedence(new_version, name) < old:
        if (name, old_version, new_version) in approved:
            print(f"::warning::{name}: rollback from {old_version} to {new_version} "
                  f"is approved in {APPROVALS} on {base}", file=sys.stderr)
            continue
        fail(f"{name}: version {new_version} is below the one already committed on the base branch")
print(f"checked {len(names)} committed formulae against {base}: none goes back")
PY
