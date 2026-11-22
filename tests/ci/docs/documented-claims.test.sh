#!/usr/bin/env bash
#
# What CONTRIBUTING.md and docs/threat-model.md tell a contributor to run, and the
# files they send them to, has to be there and has to work as written.
# documented-test-command.test.sh runs the one command the Tests section gives. This
# reads the rest:
#
#   * every repository path the documents name in backticks exists. A file that is
#     described but not versioned is found by the reader, not by a gate: the rollback
#     procedure sent the reader to a list that was not in the tree;
#   * the packages the Tests section lists are enough for the blocks after it: a block
#     that starts a virtual environment needs python3-venv, which Debian and Ubuntu
#     package apart from python3, and the rollback needs gh and curl, which no suite uses;
#   * when threat-model.md counts checkouts against persist-credentials, the two commands
#     it prints give the same number on a tree that names the option in prose, which is
#     what made them differ once.
#
# Each rule is first shown refusing a planted document, beside the accepted one, and
# then reads this repository's. A document that prints no pair of counts fails.
#
# Requires: bash, git, grep, awk, sed.
# The planted documents and the grep patterns are text, with `$` and backticks in them on purpose.
# shellcheck disable=SC2016
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"
		pass=$((pass + 1))
	else
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

# --- the paths a document names exist ---------------------------------------------
# A path is a backticked span that starts at a top-level folder of the repository and
# holds no placeholder, wildcard or variable. `path#name` is the path.
missing_paths() { # $1=document $2=repository root
	local span path
	grep -oE '`(scripts|tests|docs|\.github)/[A-Za-z0-9_./#-]+`' "$1" | tr -d '`' | sort -u | while IFS= read -r span; do
		path="${span%%#*}"
		[ -e "$2/$path" ] || printf '%s\n' "$path"
	done
}

mkdir -p "$WORK/tree/scripts/a"
: > "$WORK/tree/scripts/a/there.sh"
printf 'Run `scripts/a/there.sh` and read `scripts/a/there.sh#name`, then `scripts/a/gone.txt`.\nAlso `tests/<name>.test.sh` and `scripts/*.sh`.\n' > "$WORK/doc.md"
check "a path the document names that is not in the tree is reported" "scripts/a/gone.txt" "$(missing_paths "$WORK/doc.md" "$WORK/tree")"
: > "$WORK/tree/scripts/a/gone.txt"
check "the same document is accepted once the file is versioned" "" "$(missing_paths "$WORK/doc.md" "$WORK/tree")"
# docs/threat-model.md names files of the products and of the sibling channel as well, so
# it is not read here; the two documents a contributor starts from are.
for doc in CONTRIBUTING.md README.md; do
	[ -f "$HERE/$doc" ] || continue
	check "every path $doc names exists" "" "$(missing_paths "$HERE/$doc" "$HERE")"
done

# --- the packages are enough for the blocks -------------------------------------------
# Prints one line per command the document gives that its package list does not cover.
prerequisites() { # $1=document
	local need
	need="$(grep -m1 -E '^The suites need' "$1" || true)"
	if grep -q 'python3 -m venv' "$1" && ! printf '%s' "$need" | grep -q 'python3-venv'; then
		echo "python3 -m venv is documented and python3-venv is not in the package list"
	fi
	if grep -q 'ALLOW_RELEASE_DOWNGRADE=1' "$1"; then
		grep -qE '`gh`' "$1" || echo "the rollback runs the renderer and gh is not named"
		grep -qE '`curl`' "$1" || echo "the rollback runs the renderer and curl is not named"
	fi
}

printf 'The suites need `shellcheck`.\n\n```sh\npython3 -m venv x\n```\n' > "$WORK/venv-missing.md"
printf 'The suites need `shellcheck` and `python3-venv`.\n\n```sh\npython3 -m venv x\n```\n' > "$WORK/venv-listed.md"
printf 'Run `ALLOW_RELEASE_DOWNGRADE=1 ./render.sh`.\n' > "$WORK/rollback-bare.md"
printf 'Run `ALLOW_RELEASE_DOWNGRADE=1 ./render.sh`; it needs `gh` and `curl`.\n' > "$WORK/rollback-named.md"
check "a virtual environment block without python3-venv in the list is reported" \
	"python3 -m venv is documented and python3-venv is not in the package list" "$(prerequisites "$WORK/venv-missing.md")"
check "the same block with python3-venv listed is accepted" "" "$(prerequisites "$WORK/venv-listed.md")"
check "a rollback that does not name gh and curl is reported" \
	"the rollback runs the renderer and gh is not named
the rollback runs the renderer and curl is not named" "$(prerequisites "$WORK/rollback-bare.md")"
check "the same rollback naming them is accepted" "" "$(prerequisites "$WORK/rollback-named.md")"
check "CONTRIBUTING.md lists what its blocks need" "" "$(prerequisites "$HERE/CONTRIBUTING.md")"

# --- the counts of the verification block agree -------------------------------------------
# The block prints a pair of `git grep` commands; each is run as written.
documented_counts() { # $1=document $2=repository root -> "<n> <m>", or nothing when the block has none
	local one two a b
	one="$(grep -E "^git grep .*persist-credentials" "$1" | head -1 | sed 's/[[:space:]]\{2,\}#.*$//')"
	two="$(grep -E "^git grep .*actions/checkout@" "$1" | head -1 | sed 's/[[:space:]]\{2,\}#.*$//')"
	[ -n "$one" ] && [ -n "$two" ] || return 0
	a="$(cd "$2" && bash -c "$one")"
	b="$(cd "$2" && bash -c "$two")"
	printf '%s %s\n' "$a" "$b"
}

counts_agree() { # $1=document $2=repository root -> 1 when the two documented counts are equal and not empty
	local first second
	read -r first second <<<"$(documented_counts "$1" "$2")"
	[ "$first" = "$second" ] && [ -n "$first" ] && echo 1 || echo 0
}

mkdir -p "$WORK/repo/.github/workflows"
cat > "$WORK/repo/.github/workflows/w.yml" <<'YAML'
# persist-credentials: false is set on the checkout below, and the check that reads it is
# ./tests/ci/policy/workflows/persist-credentials.test.sh
jobs:
  j:
    steps:
      - uses: actions/checkout@0000000000000000000000000000000000000000 # v1
        with:
          persist-credentials: false
      - run: ./tests/ci/policy/workflows/persist-credentials.test.sh
YAML
git -C "$WORK/repo" init -q -b main
git -C "$WORK/repo" add -A
BLOCK='git grep -h '"'persist-credentials: false'"' .github/workflows | grep -vc '"'^[[:space:]]*#'"'    # equals the next line
git grep -h '"'actions/checkout@'"' .github/workflows | grep -vc '"'^[[:space:]]*#'"'              # equals the line above'
printf '```sh\n%s\n```\n' "$BLOCK" > "$WORK/block.md"
check "the documented counts agree on a tree whose comments and test names say persist-credentials" "1 1" "$(documented_counts "$WORK/block.md" "$WORK/repo")"
NAIVE='git grep -n '"'persist-credentials'"' .github/workflows | wc -l    # equals the next line
git grep -h '"'actions/checkout@'"' .github/workflows | wc -l   # equals the line above'
printf '```sh\n%s\n```\n' "$NAIVE" > "$WORK/naive.md"
check "the counts the document used to print disagree on that tree" "4 1" "$(documented_counts "$WORK/naive.md" "$WORK/repo" | tr -s ' ')"
check "and that is not an agreement" "0" "$(counts_agree "$WORK/naive.md" "$WORK/repo")"
check "while the documented ones are" "1" "$(counts_agree "$WORK/block.md" "$WORK/repo")"
# The document has to print the pair, in the form the helper runs: a block with no pair
# leaves the check with nothing to read, and a check that reads nothing proves nothing.
check "docs/threat-model.md prints both counts as git grep commands" "1" \
	"$(grep -qE '^git grep .*persist-credentials' "$HERE/docs/threat-model.md" && grep -qE '^git grep .*actions/checkout@' "$HERE/docs/threat-model.md" && echo 1 || echo 0)"
check "the documented counts agree on this repository" "1" "$(counts_agree "$HERE/docs/threat-model.md" "$HERE")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
