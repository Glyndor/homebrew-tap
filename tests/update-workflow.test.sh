#!/usr/bin/env bash
#
# Tests for the shell inside .github/workflows/update.yml.
#
# That workflow decides, on every scheduled run, whether to commit to `main` —
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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
sandbox() { # $1=path $2=generator exit code $3=writes? (yes|no|empty)
	local dir="$1" code="$2" mode="$3"
	rm -rf "$dir"; mkdir -p "$dir/scripts" "$dir/Formula"
	printf 'class Podup < Formula\nend\n' > "$dir/Formula/podup.rb"
	cat > "$dir/scripts/render-formulae.sh" <<SH
#!/usr/bin/env bash
case "$mode" in
	yes)   printf 'class Podup < Formula\n  # changed\nend\n' > "$dir/Formula/podup.rb" ;;
	empty) rm -f "$dir"/Formula/*.rb ;;
esac
exit $code
SH
	chmod +x "$dir/scripts/render-formulae.sh"
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
step_script "Render formulae" > "$RENDER"
step_script "Validate the re-rendered formulae" > "$VALIDATE"

check "the render step was extracted from the workflow" "1" \
	"$(grep -c 'render-formulae.sh' "$RENDER")"
check "the validate step was extracted from the workflow" "1" \
	"$(grep -c 'refusing to commit an empty tap' "$VALIDATE")"

# --- exit code becomes `partial` -------------------------------------------

sandbox "$WORK/a" 0 yes
rc=0; run_step "$RENDER" "$WORK/a" || rc=$?
check "a clean render exits 0" "0" "$rc"
check "and reports partial=0" "0" "$(output partial)"
check "and reports changed=1 when the formula moved" "1" "$(output changed)"

sandbox "$WORK/b" 0 no
rc=0; run_step "$RENDER" "$WORK/b" || rc=$?
check "an unchanged render reports changed=0" "0" "$(output changed)"
check "and says so in the log" "1" "$(grep -c 'No formula changed' "$WORK/out")"

sandbox "$WORK/c" 3 yes
rc=0; run_step "$RENDER" "$WORK/c" || rc=$?
check "exit 3 does NOT abort the step" "0" "$rc"
check "and reports partial=1" "1" "$(output partial)"
check "and still reports the products that rendered" "1" "$(output changed)"

# Anything else is a failure before any product was reached, and must stop the
# run rather than be mistaken for a partial success.
sandbox "$WORK/d" 5 no
rc=0; run_step "$RENDER" "$WORK/d" || rc=$?
check "an unexpected exit code aborts the step" "5" "$rc"
check "and sets no partial output" "" "$(output partial)"
check "and sets no changed output" "" "$(output changed)"

sandbox "$WORK/e" 1 no
rc=0; run_step "$RENDER" "$WORK/e" || rc=$?
check "exit 1 also aborts rather than committing" "1" "$rc"

# --- the empty-tap guard ----------------------------------------------------

# The guard fires before brew is set up, which is what lets it be exercised at
# all outside a runner: brew is not installed here, so reaching `brew style`
# would exit 127 instead. A 1 with the message is proof the guard ran first.
sandbox "$WORK/f" 0 no
# The validate step runs after the generator, so empty the directory here
# rather than through the stub — this step never invokes it.
rm -f "$WORK/f"/Formula/*.rb
rc=0; run_step "$VALIDATE" "$WORK/f" || rc=$?
check "an emptied Formula/ fails validation" "1" "$rc"
check "and the error says why" "1" \
	"$(grep -c 'refusing to commit an empty tap' "$WORK/out")"

# The mirror image: with a formula present the guard must NOT fire, and the step
# must go on to brew.
#
# What happens once it gets there is deliberately not asserted. The exit code
# past the guard depends on whether brew is installed -- 127 where it is absent,
# 1 where it rejects a stub formula -- so pinning it would test the machine
# rather than the workflow. This assertion WAS written as `127`: it passed
# locally and failed on the runner, where brew exists.
sandbox "$WORK/g" 0 no
rc=0; run_step "$VALIDATE" "$WORK/g" || rc=$?
check "a populated Formula/ does not trip the empty-tap guard" "0" \
	"$(grep -c 'refusing to commit an empty tap' "$WORK/out")"
check "and the step got past the guard to brew" "yes" \
	"$(grep -qiE 'brew|linuxbrew' "$WORK/out" && echo yes || echo no)"

# --- the wiring, asserted by reading the workflow ---------------------------
# These conditions are evaluated by the Actions engine, so they can be read but
# not executed here. Reading them still catches the wiring being dropped.

check "both later steps are gated on changed" "2" \
	"$(grep -c "if: steps.render.outputs.changed == '1'" "$WORKFLOW")"
check "the failure step is gated on partial" "1" \
	"$(grep -c "if: steps.render.outputs.partial == '1'" "$WORKFLOW")"
check "the failure step is last, after the commit" "1" \
	"$(awk '/name: Commit the update/ { c = NR } /name: Fail if any product was skipped/ { f = NR } END { print (c && f && f > c) ? 1 : 0 }' "$WORKFLOW")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
