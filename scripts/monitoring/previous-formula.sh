#!/usr/bin/env bash
#
# Print the commit of the formula the tap had before the one it has now, so that an upgrade from it can be tried.
#
# Usage: previous-formula.sh <formula path>      (run in a checkout with the history of the branch)
#
# The version of a formula is the tag its urls name: Formula/podup.rb carries no `version` line, and the updater
# writes `.../releases/download/v6.0.0/...`. This reads that tag from the file at HEAD and walks the commits that
# changed the file, newest first, until one holds a lower version by the order of SemVer (a pre-release is below
# its release, numeric identifiers are below text ones, build metadata is ignored). The same version rendered
# again is not a previous one, and neither is a commit where the file has no url.
#
# Prints "<sha> <version>" and exits 0. Exit 3 when no commit of the history holds a lower version (an upgrade
# cannot be tried, and that is not a pass). Exit 1 for anything else: no such file at HEAD, no readable version,
# a version that is not SemVer, git failing.
set -euo pipefail

file="${1:?usage: previous-formula.sh <formula path>}"

python3 -I - "$file" <<'PY'
import re
import subprocess
import sys

file = sys.argv[1]
URL = re.compile(r'url "https://github\.com/[^"/]+/[^"/]+/releases/download/v?([^/"]+)/')
SEMVER = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?")


def fail(message):
    print(f"::error::previous-formula: {message}", file=sys.stderr)
    sys.exit(1)


def git(*args):
    done = subprocess.run(["git", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if done.returncode:
        raise OSError(done.stderr.decode("utf-8", "replace").strip() or "git failed")
    return done.stdout.decode("utf-8", "replace")


def version_of(text):
    found = {m.group(1) for m in URL.finditer(text)}
    return found.pop() if len(found) == 1 else None


def key(version):
    m = SEMVER.fullmatch(version)
    if not m:
        fail(f"{version} is not a SemVer version")
    pre = m.group(4)
    ids = [(0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split(".")] if pre else []
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), 0 if pre else 1, ids)


try:
    now = version_of(git("show", "HEAD:" + file))
except OSError as e:
    fail(f"{file} cannot be read at HEAD ({e})")
if now is None:
    fail(f"{file} at HEAD names no single release in its urls, so its version is not known")
current = key(now)
try:
    revisions = git("log", "--format=%H", "--", file).split()
except OSError as e:
    fail(f"the history of {file} cannot be read ({e})")
for sha in revisions:
    try:
        before = version_of(git("show", sha + ":" + file))
    except OSError:
        continue
    if before is not None and key(before) < current:
        print(sha, before)
        sys.exit(0)
print(f"previous-formula: no commit of the history of {file} holds a version below {now}", file=sys.stderr)
sys.exit(3)
PY
