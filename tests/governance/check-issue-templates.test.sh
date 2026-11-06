#!/usr/bin/env bash
#
# Tests for scripts/governance/check-issue-templates.sh -- the check that keeps the
# bug report template asking for this channel's platform and install method.
#
# The template it guards was copied from another channel and never adapted: it
# asked for a Linux distribution and offered `install.sh`, neither of which
# exists here. Both directions are exercised below -- a template that names
# this channel is accepted, and every way of being wrong again is refused with
# a message that says which one it was. A check that only refused things would
# pass every refusal and fail the acceptance, which is why the acceptance comes
# first and why each refusal asserts the reason and not just the exit code.
#
# The refusals run against fixture trees, not against this repository's own
# template, so they can be exercised without breaking the repository. The last
# case runs against the real template: that is the one that goes red when the
# template drifts, and it is the reason this test exists.
#
# Requires: bash, awk, grep, sed, find.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$HERE/scripts/governance/check-issue-templates.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"; pass=$((pass + 1))
	else
		echo "FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

run() { # $1=tree -> rc in $rc, output in $out
	rc=0
	out="$(bash "$CHECK" "$1" 2>&1)" || rc=$?
}

said() { printf '%s' "$out" | grep -qF "$1" && echo 1 || echo 0; }

# A tree the check can read: the template, a README, and one product file per
# channel layout. Both layouts are here so the fixture does not have to know
# which one this channel uses.
fixture() { # $1=name $2=template file $3=README file -> prints the tree path
	local d="$WORK/$1"
	rm -rf "$d"
	mkdir -p "$d/.github/ISSUE_TEMPLATE" "$d/Formula" "$d/bucket"
	cp "$2" "$d/.github/ISSUE_TEMPLATE/bug_report.yml"
	cp "$3" "$d/README.md"
	: > "$d/Formula/podup.rb"
	: > "$d/bucket/podup.json"
	echo "$d"
}

# --- the fixtures ------------------------------------------------------------

cat > "$WORK/good-template.yml" <<'YAML'
name: Bug report
description: Report a bug or unexpected behavior
body:
  - type: input
    id: os
    attributes:
      label: Operating system
      description: macOS version and architecture, plus your Homebrew version (`brew --version`).
      placeholder: e.g. macOS 15 Apple Silicon, macOS 14 Intel
  - type: input
    id: version
    attributes:
      label: Version
      description: Project version and how you installed it.
      placeholder: e.g. 5.16.0 (brew install glyndor/tap/podup)
YAML

cat > "$WORK/good-readme.md" <<'MARKDOWN'
# Glyndor Homebrew tap

## Install

```bash
brew install glyndor/tap/podup
```
MARKDOWN

# The template as it was found: a Linux distribution and an install method that
# does not exist in this channel.
cat > "$WORK/foreign-template.yml" <<'YAML'
name: Bug report
description: Report a bug or unexpected behavior
body:
  - type: input
    id: os
    attributes:
      label: Operating system
      placeholder: e.g. Ubuntu 24.04, Debian 13, Fedora 42
  - type: input
    id: version
    attributes:
      label: Version
      description: Project version and how you installed it.
      placeholder: v0.3.1 (install.sh)
YAML

# Only the operating system field is wrong: another channel's distributions.
cat > "$WORK/other-os-template.yml" <<'YAML'
name: Bug report
description: Report a bug or unexpected behavior
body:
  - type: input
    id: os
    attributes:
      label: Operating system
      placeholder: e.g. Ubuntu 24.04, Debian 13, Fedora 42
  - type: input
    id: version
    attributes:
      label: Version
      description: Project version and how you installed it.
      placeholder: e.g. 5.16.0 (brew install glyndor/tap/podup)
YAML

# Only the version field is wrong: an install method this channel does not have.
cat > "$WORK/foreign-method-template.yml" <<'YAML'
name: Bug report
description: Report a bug or unexpected behavior
body:
  - type: input
    id: os
    attributes:
      label: Operating system
      description: macOS version and architecture, plus your Homebrew version (`brew --version`).
      placeholder: e.g. macOS 15 Apple Silicon, macOS 14 Intel
  - type: input
    id: version
    attributes:
      label: Version
      description: Project version and how you installed it.
      placeholder: v0.3.1 (install.sh)
YAML

# The platform is named and a distribution is offered next to it. This tap
# serves Linux too, so that is not wrong here.
cat > "$WORK/linux-example-template.yml" <<'YAML'
name: Bug report
description: Report a bug or unexpected behavior
body:
  - type: input
    id: os
    attributes:
      label: Operating system
      description: macOS version and architecture, plus your Homebrew version (`brew --version`).
      placeholder: e.g. macOS 15 Apple Silicon, Ubuntu 24.04 (Linux via this tap)
  - type: input
    id: version
    attributes:
      label: Version
      description: Project version and how you installed it.
      placeholder: e.g. 5.16.0 (brew install glyndor/tap/podup)
YAML

# The platform is named, but the package manager's version is not asked for.
cat > "$WORK/no-manager-template.yml" <<'YAML'
name: Bug report
description: Report a bug or unexpected behavior
body:
  - type: input
    id: os
    attributes:
      label: Operating system
      description: macOS version and architecture.
      placeholder: e.g. macOS 15 Apple Silicon, macOS 14 Intel
  - type: input
    id: version
    attributes:
      label: Version
      description: Project version and how you installed it.
      placeholder: e.g. 5.16.0 (brew install glyndor/tap/podup)
YAML

# The version field names a command that starts like the README's one.
cat > "$WORK/drifted-version-template.yml" <<'YAML'
name: Bug report
description: Report a bug or unexpected behavior
body:
  - type: input
    id: os
    attributes:
      label: Operating system
      description: macOS version and architecture, plus your Homebrew version (`brew --version`).
      placeholder: e.g. macOS 15 Apple Silicon, macOS 14 Intel
  - type: input
    id: version
    attributes:
      label: Version
      description: Project version and how you installed it.
      placeholder: e.g. 5.16.0 (brew install glyndor/tap/podup-nightly)
YAML

# The manager is named in a different case.
cat > "$WORK/manager-case-template.yml" <<'YAML'
name: Bug report
description: Report a bug or unexpected behavior
body:
  - type: input
    id: os
    attributes:
      label: Operating system
      description: macOS version and architecture, plus your Brew version.
      placeholder: e.g. macOS 15 Apple Silicon, macOS 14 Intel
  - type: input
    id: version
    attributes:
      label: Version
      description: Project version and how you installed it.
      placeholder: e.g. 5.16.0 (brew install glyndor/tap/podup)
YAML

# The template has no operating system field at all.
cat > "$WORK/no-os-template.yml" <<'YAML'
name: Bug report
description: Report a bug or unexpected behavior
body:
  - type: input
    id: version
    attributes:
      label: Version
      description: Project version and how you installed it.
      placeholder: e.g. 5.16.0 (brew install glyndor/tap/podup)
YAML

# A README that documents no install command.
cat > "$WORK/no-install-readme.md" <<'MARKDOWN'
# Glyndor Homebrew tap

## Upgrades

Upgrades arrive with `brew upgrade`.
MARKDOWN

# --- a template that names this channel is accepted --------------------------

D="$(fixture good "$WORK/good-template.yml" "$WORK/good-readme.md")"
run "$D"
check "a template that names this channel passes" "0" "$rc"
check "and the run says which install command it checked" "1" \
	"$(said 'brew install glyndor/tap/podup')"

# --- the template as it was found is refused ---------------------------------

D="$(fixture foreign "$WORK/foreign-template.yml" "$WORK/good-readme.md")"
run "$D"
check "the template that asked for a Linux distribution and install.sh is refused" "1" "$rc"
check "and says which platform it wanted" "1" "$(said 'macOS')"
check "and names the install method that does not exist here" "1" "$(said 'install.sh')"

# --- one field at a time, so each refusal names its own reason ---------------

D="$(fixture other-os "$WORK/other-os-template.yml" "$WORK/good-readme.md")"
run "$D"
check "an operating system field with another channel's distributions is refused" "1" "$rc"
check "and says which platform it wanted" "1" "$(said 'macOS')"
check "and does not blame the install method" "0" "$(said 'install.sh')"

D="$(fixture foreign-method "$WORK/foreign-method-template.yml" "$WORK/good-readme.md")"
run "$D"
check "a version field that names install.sh is refused" "1" "$rc"
check "and names the method that does not exist here" "1" "$(said 'install.sh')"
check "and does not blame the operating system field" "0" "$(said 'does not name macOS')"

D="$(fixture linux-example "$WORK/linux-example-template.yml" "$WORK/good-readme.md")"
run "$D"
check "a distribution named next to the platform is accepted, because this tap serves Linux too" "0" "$rc"

D="$(fixture manager-case "$WORK/manager-case-template.yml" "$WORK/good-readme.md")"
run "$D"
check "a manager written in another case is accepted" "0" "$rc"

D="$(fixture no-manager "$WORK/no-manager-template.yml" "$WORK/good-readme.md")"
run "$D"
check "an operating system field that does not ask for the manager version is refused" "1" "$rc"
check "and names the manager" "1" "$(said 'does not ask for the brew version')"

D="$(fixture drifted-version "$WORK/drifted-version-template.yml" "$WORK/good-readme.md")"
run "$D"
check "a version field that names another command is refused" "1" "$rc"
check "and names the command the README documents" "1" \
	"$(said 'brew install glyndor/tap/podup')"

# --- what it cannot read is a failure, not a pass ---------------------------

D="$(fixture no-os "$WORK/no-os-template.yml" "$WORK/good-readme.md")"
run "$D"
check "a template without an operating system field is refused" "1" "$rc"
check "and names the field it could not find" "1" "$(said "id 'os'")"

D="$(fixture no-install "$WORK/good-template.yml" "$WORK/no-install-readme.md")"
run "$D"
check "a README without an install command is refused" "1" "$rc"
check "and says the install command could not be found" "1" \
	"$(said "no install command for a served product")"

run "$WORK/no-such-tree"
check "a tree with no template at all is refused" "1" "$rc"
check "and says the file is not there" "1" "$(said 'no .github/ISSUE_TEMPLATE/bug_report.yml')"

# --- this repository's own template -----------------------------------------

run "$HERE"
check "this repository's own bug report template passes" "0" "$rc"
check "and the run names this channel's platform" "1" "$(said 'macOS')"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
