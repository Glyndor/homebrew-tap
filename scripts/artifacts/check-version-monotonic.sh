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


class BadApprovals(Exception):
    pass


def parse_approvals(text, where):
    """(path, from, to) triples; every line is checked, so one bad line stops the gate."""
    entries = []
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 3 or not fields[0].lower().endswith(".rb"):
            raise BadApprovals(f"{where}:{number}: malformed line, and a malformed approvals file stops the gate "
                 f"for every pull request until it is fixed; expected '<formula path> <from> <to>'")
        for version in fields[1:]:
            if not re.fullmatch(PATTERN, version):
                raise BadApprovals(f"{where}:{number}: {version!r} is not a valid SemVer release version")
        entries.append(tuple(fields))
    return entries


def core(version):
    """The version without build metadata, which SemVer precedence ignores."""
    return version.split("+", 1)[0]


def approved_rollbacks(base):
    """(path, from, to) triples written in the approvals file at BASE, as written.

    A malformed file at BASE grants nothing and says so, rather than stopping every pull
    request: otherwise the very pull request that repairs the file could not pass.
    """
    exists = subprocess.run(["git", "cat-file", "-e", f"{base}:{APPROVALS}"],
                            capture_output=True).returncode == 0
    if not exists:
        return set()
    text = git("show", f"{base}:{APPROVALS}")
    try:
        return set(parse_approvals(text, f"{APPROVALS} at {base}"))
    except BadApprovals as error:
        print(f"::warning::{error}; the file grants nothing until it is repaired", file=sys.stderr)
        return set()


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
rolled_back = 0
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
        if any(n == name and core(a) == core(old_version) and core(b) == core(new_version)
               for n, a, b in approved):
            print(f"::warning::{name}: rollback from {old_version} to {new_version} "
                  f"is approved in {APPROVALS} on {base}", file=sys.stderr)
            rolled_back += 1
            continue
        fail(f"{name}: version {new_version} is below the one already committed on the base branch")
# An approval is single-use: once the tree is already at the version it allowed, the
# line has to go, or it would quietly allow the same rollback again later. The
# rollback pull request removes it; the base still holds it, which is what let the
# rollback through.
if os.path.exists(APPROVALS):
    with open(APPROVALS, encoding="utf-8") as handle:
        try:
            tree_entries = parse_approvals(handle.read(), APPROVALS)
        except BadApprovals as error:
            fail(f"{error}; a malformed approvals file stops the gate for every pull request until it is fixed")
        for path, came_from, goes_to in tree_entries:
            try:
                with open(path, encoding="utf-8") as target:
                    here = version_of(target.read(), path)
            except FileNotFoundError:
                continue
            if core(here) == core(goes_to):
                fail(f"{APPROVALS}: the approval for {path} ({came_from} -> {goes_to}) has been used, "
                     f"the file is already at {here}; remove the line in the rollback pull request")
    # The permission has to be a change of its own: a pull request that rolls something
    # back may only delete lines, never add or alter one, or it could install the
    # permission for the next rollback, or for another file, in the same change.
    if rolled_back:
        carried = sorted(set(tree_entries) - approved)
        if carried:
            fail(f"{APPROVALS}: a pull request that rolls back cannot also add or change an approval "
                 f"line (found {' | '.join(' '.join(e) for e in carried)}); land the permission first, as its own change")
if rolled_back:
    print(f"checked {len(names)} committed formulas against {base}: {rolled_back} approved rollback(s)")
else:
    print(f"checked {len(names)} committed formulas against {base}: none goes back")
PY
