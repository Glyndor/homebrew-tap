#!/usr/bin/env bash
#
# Tests for the shell inside .github/workflows/update.yml.
#
# That workflow decides, on every scheduled run, whether to commit to `main`,
# and it commits without a pull request, so its decisions are the last thing
# standing between a bad render and `brew install`. Three of them are ours
# rather than GitHub's:
#
#   - the generator's exit code becomes `partial`, and only an unexpected code
#     aborts the run; exit 3 (some products skipped) must carry on so the
#     products that did render still reach users
#   - `changed` decides whether anything is committed at all
#   - an emptied Formula/ must never be committed
#
# The `run:` blocks are extracted from the workflow and executed as they ship,
# rather than copied here. A copy would pass while the workflow rots.
#
# Not covered, and not coverable without the Actions engine: the `if:`
# conditions wiring these outputs to the later steps, and the createCommitOnBranch
# call itself. Those are asserted by reading the workflow, not by running it.
#
# Requires: python3, git.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKFLOW="$HERE/.github/workflows/update.yml"
WORK="$(mktemp -d)"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

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

# Pull one step's `run:` body out of the workflow, dedented, so it can be run.
step_script() { # $1=step name substring
	python3 - "$WORKFLOW" "$1" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(lines) if "name: " + sys.argv[2] in l)
run = next(i for i, l in enumerate(lines) if i > start and l.strip() == "run: |")
body = []
for line in lines[run + 1:]:
    if not line.strip():
        body.append("")
        continue
    if not line.startswith(" " * 10):
        break
    body.append(line[10:])
print("\n".join(body))
PY
}

# A repository the step can run in: a git repo with a committed Formula/ and a
# stub generator whose behaviour each case chooses.
sandbox() { # $1=path $2=generator exit code $3=writes? (yes|no|empty|del|del-multi)
	local dir="$1" code="$2" mode="$3"
	rm -rf "$dir"; mkdir -p "$dir/scripts" "$dir/scripts/release" "$dir/scripts/artifacts" "$dir/Formula"
	# The validate step runs scripts/artifacts/check-formulae.sh before brew, so
	# the sandbox carries the real check, the committed formula it accepts and
	# the real roster (the stub generator below declares the same PRODUCTS), and
	# the step is exercised with the code that ships.
	cp "$HERE/Formula/podup.rb" "$dir/Formula/podup.rb"
	cp "$HERE/scripts/artifacts/check-formulae.sh" "$HERE/scripts/artifacts/check-formulae.py" "$dir/scripts/artifacts/"
	# `del-multi` adds a second tracked formula so a deletion can leave the
	# channel with one left, exercising the deletion-only-but-survivor path
	# without also tripping the empty-channel refusal.
	if [ "$mode" = "del-multi" ]; then
		printf 'class Zzz < Formula\nend\n' > "$dir/Formula/zzz.rb"
	fi
	cat > "$dir/scripts/release/render-formulae.sh" <<SH
#!/usr/bin/env bash
$(awk '/^PRODUCTS=\(/ { inside = 1; print; next } inside && /^\)/ { print; exit } inside { print }' "$HERE/scripts/release/render-formulae.sh")
case "$mode" in
	yes)       printf 'class Podup < Formula\n  # changed\nend\n' > "$dir/Formula/podup.rb" ;;
	new)       printf 'class Zzz < Formula\nend\n' > "$dir/Formula/zzz.rb" ;;
	empty)     rm -f "$dir"/Formula/*.rb ;;
	del)       rm -f "$dir/Formula/podup.rb" ;;
	del-multi) rm -f "$dir/Formula/podup.rb" ;;
esac
exit $code
SH
	chmod +x "$dir/scripts/release/render-formulae.sh"
	git -C "$dir" init -q
	git -C "$dir" -c user.email=t@t -c user.name=t add -A
	git -C "$dir" -c user.email=t@t -c user.name=t commit -qm init
	# Re-apply after the commit, so the working tree differs from HEAD the way
	# it does in a real run.
	:
}

run_step() { # $1=script $2=dir ; sets GITHUB_OUTPUT, returns the step's status
	: > "$WORK/gh-output"
	( cd "$2" && GITHUB_OUTPUT="$WORK/gh-output" bash "$1" ) > "$WORK/out" 2>&1
}

output() { # $1=key
	awk -F= -v k="$1" '$1 == k { print $2 }' "$WORK/gh-output"
}

RENDER="$WORK/render.sh"
VALIDATE="$WORK/validate.sh"
COMMIT="$WORK/commit.sh"
step_script "Render formulae" > "$RENDER"
step_script "Validate the re-rendered formulae" > "$VALIDATE"
step_script "Commit the update to main" > "$COMMIT"


# Stub `gh`: log args + stdin, exit 0. The step passes the GraphQL query on
# stdin (`--input -`); the path `STUB_DIR` carries the location back to the
# caller. `STUB_DIR` is set per-invocation so the stub does not depend on a
# shared file path.
stub_gh() { # $1=dir
	local dir="$1"
	mkdir -p "$dir"
	cat > "$dir/gh" <<'GHSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_DIR/.args"
cat > "$STUB_DIR/.stdin"
exit 0
GHSTUB
	chmod +x "$dir/gh"
}


# expectedHeadOid is the only thing that stops a slow run from overwriting a
# faster one. Play GitHub's side with a stub that keeps the branch head in a
# file, accepts a mutation only when it names the current head, and advances the
# head when it accepts one. Run the step twice from the same checkout: the
# second names a head that is no longer current.
race_gh() { # $1=dir
	mkdir -p "$1"
	cat > "$1/gh" <<'RACE'
#!/usr/bin/env bash
payload="$(cat)"
exec 9>"$STUB_DIR/.lock"
flock 9
# The head is read from the variable the QUERY binds to expectedHeadOid, not from
# a variable name assumed here: a query that pins another value and leaves
# variables.head correct must not look right.
bound="$(jq -r '.query' <<<"$payload" | sed -nE 's/.*expectedHeadOid:\$([A-Za-z_]+).*/\1/p')"
if [ -z "$bound" ]; then
	echo "gh: the query does not bind expectedHeadOid to a variable." >&2
	exit 1
fi
want="$(jq -r --arg v "$bound" '.variables[$v] // empty' <<<"$payload")"
current="$(cat "$STUB_DIR/.remote-head")"
if [ "$want" != "$current" ]; then
	echo "gh: Expected branch to point to \"$want\" but it did not." >&2
	exit 1
fi
echo "advanced-by-$$" > "$STUB_DIR/.remote-head"
echo "$want" >> "$STUB_DIR/.accepted"
exit 0
RACE
	chmod +x "$1/gh"
}


run_race() {
	( cd "$WORK/h" && PATH="$WORK/race:$PATH" STUB_DIR="$WORK/race" REPO="Glyndor/homebrew-tap" \
		GH_TOKEN="dummy" bash "$COMMIT" ) > "$WORK/out" 2>&1
}
