#!/usr/bin/env bash
#
# update.yml installs the cryptography wheel that ML-DSA-65 needs only once the
# renderer holds an ML-DSA-65 key, and its render step then runs the renderer on
# that wheel's python.
#
# Until the key exists the render job must behave exactly as before: no venv, no
# pip, nothing from PyPI. The day a key is committed, in either slot, it must
# install the hash-pinned wheel, or the first release that carries a second
# signature would be refused every hour on a library without ML-DSA. Both halves
# are decided by shell in the workflow, so the two steps are extracted as they
# ship and run here: the install step against a stubbed sudo and python3 that
# record what they were asked to do, and the render step in a scratch repository
# whose renderer records the python3 it was given. Each decision is then removed
# from a copy of the workflow, and the case it guards has to notice.
#
# The file is the same in Glyndor/homebrew-tap and Glyndor/scoop-bucket
# (scripts/monitoring/channel-shared-paths.txt): the renderer's name is read
# from the install step itself, and the render step is the one named `Render`.
#
# Requires: python3, git.
set -u

HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
WF="$HERE/.github/workflows/update.yml"
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

extract() { # $1=workflow file $2=start of the step name -> its run: body, dedented
	python3 -I - "$1" "$2" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(lines) if l.strip().startswith("- name: " + sys.argv[2]))
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
INSTALL="Install the signature verifier"
RENDER="Render "

extract "$WF" "$INSTALL" > "$WORK/install.sh"
RENDERER="$(grep -oE 'scripts/release/render-[a-z]+\.sh' "$WORK/install.sh" | head -1)"
check "the install step was extracted and names the renderer it reads" "1 1" \
	"$(grep -c 'apt-get install' "$WORK/install.sh") $([ -f "$HERE/$RENDERER" ] && echo 1 || echo 0)"

# The pip install is one line: the workflow-lint isolation check reads it a line
# at a time, so a --require-hashes on a continuation line would not be seen.
check "the pip install carries --require-hashes and --only-binary on its own line" "1 0" \
	"$(grep -c 'pip install .*--require-hashes .*--only-binary=:all: -r scripts/release/render-requirements.txt$' "$WORK/install.sh") $(grep -c 'pip install.*\\$' "$WORK/install.sh")"

# --- the install step ---------------------------------------------------------
#
# sudo records its arguments and succeeds. python3 handles `-m venv <dir>` by
# creating <dir>/bin/python, which records its arguments as the pip call; any
# other use of python3 is refused, so the step cannot reach the real one.
mkdir -p "$WORK/stub"
cat > "$WORK/stub/sudo" <<'SH'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$LOG"
SH
cat > "$WORK/stub/python3" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -m ] && [ "${2:-}" = venv ] && [ -n "${3:-}" ]; then
	printf 'venv %s\n' "$3" >> "$LOG"
	mkdir -p "$3/bin"
	printf '#!/usr/bin/env bash\nprintf "pip %%s\\n" "$*" >> "$LOG"\nexit "${PIP_RC:-0}"\n' > "$3/bin/python"
	chmod +x "$3/bin/python"
	exit 0
fi
printf 'python3 %s\n' "$*" >> "$LOG"
exit 1
SH
chmod +x "$WORK/stub/sudo" "$WORK/stub/python3"

# keyed <slot line>: the committed renderer with one line replaced, on stdout.
keyed() { python3 -I - "$HERE/$RENDERER" "$1" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
name = sys.argv[2].lstrip("# ").split("=", 1)[0]
text, n = re.subn(r"^" + name + r'="[^"\n]*"$', lambda m: sys.argv[2], text, count=1, flags=re.M)
assert n == 1, name
sys.stdout.write(text)
PY
}
install_run() { # $1=step file $2=renderer text -> rc; the log is $WORK/log
	local d="$WORK/install"
	rm -rf "$d"; mkdir -p "$d/scripts/release" "$d/rt"
	printf '%s' "$2" > "$d/$RENDERER"
	: > "$WORK/log"
	(cd "$d" && LOG="$WORK/log" RUNNER_TEMP="$d/rt" PATH="$WORK/stub:$PATH" bash -e "$1" >"$WORK/out" 2>&1)
}
said() { grep -c -- "$1" "$WORK/log" || true; }
PIP='^pip -m pip install --quiet --disable-pip-version-check --require-hashes --only-binary=:all: -r scripts/release/render-requirements.txt$'

committed_key="$(grep -cE '^RELEASE_PQ_PUBKEY2?_B64="[^"]+"$' "$HERE/$RENDERER")"
rc=0; install_run "$WORK/install.sh" "$(cat "$HERE/$RENDERER")" || rc=$?
if [ "$committed_key" -ne 0 ]; then
	echo "not run - the committed renderer installs nothing (it holds an ML-DSA-65 key now)"
else
	check "with the committed renderer, which holds no ML-DSA-65 key, the step succeeds" "0" "$rc"
	check "and it installs the same distribution package as before" "1" \
		"$(said '^sudo apt-get install -y -qq python3-cryptography$')"
	check "and it creates no venv and runs no pip" "0 0" "$(said '^venv ') $(said '^pip ')"
fi

rc=0; install_run "$WORK/install.sh" "$(keyed 'RELEASE_PQ_PUBKEY_B64="AAAA"')" || rc=$?
check "a key in the first slot creates the venv outside the workspace" "0 1" \
	"$rc $(said "^venv $WORK/install/rt/mldsa-venv\$")"
check "and installs the wheel pinned by hash, binary only, from the requirements file" "1" "$(said "$PIP")"
check "and still installs the distribution package" "1" "$(said '^sudo apt-get install -y -qq python3-cryptography$')"
rc=0; install_run "$WORK/install.sh" "$(keyed 'RELEASE_PQ_PUBKEY2_B64="AAAA"')" || rc=$?
check "a key in the second slot alone installs it too" "0 1 1" "$rc $(said '^venv ') $(said "$PIP")"
rc=0; install_run "$WORK/install.sh" "$(keyed '# RELEASE_PQ_PUBKEY_B64="AAAA"')" || rc=$?
check "a key named only in a comment installs nothing" "0 0 0" "$rc $(said '^venv ') $(said '^pip ')"
rc=0; PIP_RC=1 install_run "$WORK/install.sh" "$(keyed 'RELEASE_PQ_PUBKEY_B64="AAAA"')" || rc=$?
check "a pip install that fails stops the step" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

# The controls: the decision forced either way, and the case that guards it red.
decision='^\( *\)if grep -qE .*_B64=.*scripts/release/render-[a-z]*\.sh; then$'
sed "s|$decision|\\1if true; then|" "$WF" > "$WORK/wf-always.yml"
check "the always-install sabotage changed the workflow" "1" "$(cmp -s "$WF" "$WORK/wf-always.yml" && echo 0 || echo 1)"
extract "$WORK/wf-always.yml" "$INSTALL" > "$WORK/install-always.sh"
install_run "$WORK/install-always.sh" "$(keyed 'RELEASE_PQ_PUBKEY_B64=""')" || true
check "without the decision a renderer with no key installs from PyPI (the refusal is the decision's)" "1" "$(said '^pip ')"
sed "s|$decision|\\1if false; then|" "$WF" > "$WORK/wf-never.yml"
extract "$WORK/wf-never.yml" "$INSTALL" > "$WORK/install-never.sh"
install_run "$WORK/install-never.sh" "$(keyed 'RELEASE_PQ_PUBKEY_B64="AAAA"')" || true
check "and with it forced off a committed key installs nothing (the install is the decision's)" "0" "$(said '^pip ')"

# --- the render step ----------------------------------------------------------
#
# A scratch repository whose renderer records the python3 it finds first on
# PATH and renders nothing, so the rest of the step sees no change. The venv
# stand-in's python3 is a file that only has to exist and be executable.
render_run() { # $1=step file $2=with|without venv, or unset RUNNER_TEMP -> rc
	local d="$WORK/render"
	rm -rf "$d"; mkdir -p "$d/scripts/release" "$d/rt"
	git -C "$d" init -q
	printf '#!/usr/bin/env bash\ncommand -v python3 > "%s"\n' "$WORK/used" > "$d/$RENDERER"
	if [ "$2" = with ]; then
		mkdir -p "$d/rt/mldsa-venv/bin"
		printf '#!/usr/bin/env bash\nexit 0\n' > "$d/rt/mldsa-venv/bin/python3"
		chmod +x "$d/rt/mldsa-venv/bin/python3"
	fi
	rm -f "$WORK/used"
	(
		cd "$d" || exit 1
		if [ "$2" = unset ]; then unset RUNNER_TEMP; else export RUNNER_TEMP="$d/rt"; fi
		GITHUB_OUTPUT="$WORK/github-output" bash -e "$1" >"$WORK/out" 2>&1
	)
}
used() { cat "$WORK/used" 2>/dev/null || echo none; }

extract "$WF" "$RENDER" > "$WORK/render.sh"
check "the render step was extracted and runs the renderer" "1" \
	"$(grep -c "^bash \./$RENDERER || rc=\$?\$" "$WORK/render.sh")"
rc=0; render_run "$WORK/render.sh" with || rc=$?
check "with the venv present the render step succeeds" "0" "$rc"
check "and the renderer runs on the venv's python" "$WORK/render/rt/mldsa-venv/bin/python3" "$(used)"
rc=0; render_run "$WORK/render.sh" without || rc=$?
check "without it the renderer runs on the system python, as before" "0 $(command -v python3)" "$rc $(used)"
rc=0; render_run "$WORK/render.sh" unset || rc=$?
check "and the step runs where RUNNER_TEMP is not set at all" "0" "$rc"

# shellcheck disable=SC2016 # the workflow's own text, matched literally
sed 's|^\( *\)PATH="$mldsa_venv/bin:$PATH"$|\1:|' "$WF" > "$WORK/wf-nopath.yml"
check "the no-PATH sabotage changed the workflow" "1" "$(cmp -s "$WF" "$WORK/wf-nopath.yml" && echo 0 || echo 1)"
extract "$WORK/wf-nopath.yml" "$RENDER" > "$WORK/render-nopath.sh"
render_run "$WORK/render-nopath.sh" with || true
check "without the PATH line the venv is not used (the use is the line's)" "$(command -v python3)" "$(used)"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
