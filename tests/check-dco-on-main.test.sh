#!/usr/bin/env bash
#
# Tests for scripts/check-dco-on-main.sh -- the detector that reports a human
# commit reaching `main` without a Signed-off-by trailer.
#
# The bot exemption is the case worth having twice. It must skip commits the bot
# authored, and it must NOT skip a human commit that merely resembles one: if
# the exemption keyed on the message rather than the author, anyone could evade
# the check by copying the bot's subject line.
#
# Requires: git.
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$HERE/scripts/check-dco-on-main.sh"
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

repo() { # $1=name -> prints the repo path, with one base commit
	local d="$WORK/$1"
	rm -rf "$d"; mkdir -p "$d"
	git -C "$d" init -q
	git -C "$d" config user.email base@test.invalid
	git -C "$d" config user.name Base
	echo base > "$d/f"; git -C "$d" add -A
	git -C "$d" commit -qm "base

Signed-off-by: Base <base@test.invalid>"
	echo "$d"
}

commit() { # $1=repo $2=author name $3=email $4=subject $5=signed(yes|no)
	local d="$1" who="$2" mail="$3" subj="$4" signed="$5"
	echo "$RANDOM" > "$d/f"
	git -C "$d" add -A
	local msg="$subj"
	[ "$signed" = yes ] && msg="$subj

Signed-off-by: $who <$mail>"
	git -C "$d" -c user.name="$who" -c user.email="$mail" commit -qm "$msg"
}

run() { # $1=repo $2=before $3=after [$4=pusher]
	( cd "$1" && "$CHECK" "$2" "$3" ${4+"$4"} ) >"$WORK/out" 2>&1
}
said() { grep -qF "$1" "$WORK/out" && echo 1 || echo 0; }
base_of() { git -C "$1" rev-parse HEAD; }

# --- a signed human commit passes -------------------------------------------
#
# First, so every refusal below is not satisfied by a checker that refuses
# everything.
D="$(repo signed)"; B="$(base_of "$D")"
commit "$D" "Jose" "jose@test.invalid" "feat: a thing" yes
rc=0; run "$D" "$B" "$(base_of "$D")" || rc=$?
check "a signed human commit passes" "0" "$rc"

# --- an unsigned human commit is reported -----------------------------------
D="$(repo unsigned)"; B="$(base_of "$D")"
commit "$D" "Jose" "jose@test.invalid" "feat: a thing" no
rc=0; run "$D" "$B" "$(base_of "$D")" || rc=$?
check "an unsigned human commit fails" "1" "$rc"
check "and says the trailer is what is missing" "1" "$(said 'without a Signed-off-by trailer')"
check "and names the author" "1" "$(said 'Jose')"
check "and says it is detection, not prevention" "1" "$(said 'already on main')"

# --- the bot is exempt ------------------------------------------------------
D="$(repo bot)"; B="$(base_of "$D")"
commit "$D" "github-actions[bot]" "41898282+github-actions[bot]@users.noreply.github.com" \
	"chore: update formulae from the latest signed releases" no
rc=0; run "$D" "$B" "$(base_of "$D")" || rc=$?
check "an unsigned bot commit passes" "0" "$rc"
# No pusher here, so this exercises the fallback path, and the message has to
# say which signal it used. "skipped" is not enough when there are two reasons
# a commit can be skipped and one of them is weaker.
check "and the run says which signal exempted it" "1" \
	"$(said 'author field says github-actions[bot] (weak signal)')"

# --- the exemption keys on the author, not the message ----------------------
#
# If it matched the bot's subject line instead, copying that line would be all
# it took to walk past the check.
D="$(repo impostor)"; B="$(base_of "$D")"
commit "$D" "Jose" "jose@test.invalid" \
	"chore: update formulae from the latest signed releases" no
rc=0; run "$D" "$B" "$(base_of "$D")" || rc=$?
check "a human using the bot's exact subject is still reported" "1" "$rc"

# --- the author field is not an identity -------------------------------------
#
# `git -c user.name='github-actions[bot]' commit` produces a commit whose author
# field says the bot. The first version of this script exempted it. Anyone able
# to push could evade the check by editing one line of git config.
#
# The exemption now keys on WHO PUSHED, which comes from GitHub's event payload
# and cannot be set locally. This case is the one I should have written first:
# I tested that copying the bot's SUBJECT did not work, and never tested the
# field that is easier to set.
D="$(repo spoof)"; B="$(base_of "$D")"
commit "$D" "github-actions[bot]" "attacker@evil.invalid" "feat: not really the bot" no
rc=0; run "$D" "$B" "$(base_of "$D")" "Jose" || rc=$?
check "a commit whose author field impersonates the bot is still reported" "1" "$rc"
check "and the run names who actually pushed" "1" "$(said 'pushed by Jose')"

# The other direction: a real bot push is exempt even though the same commit
# carries no trailer. Without this the case above is satisfied by a script that
# reports everything.
D="$(repo realbot)"; B="$(base_of "$D")"
commit "$D" "github-actions[bot]" "41898282+github-actions[bot]@users.noreply.github.com" \
	"chore: update formulae from the latest signed releases" no
rc=0; run "$D" "$B" "$(base_of "$D")" "github-actions[bot]" || rc=$?
check "a push by the bot is exempt" "0" "$rc"
check "and says the exemption came from the push, not the commit" "1" \
	"$(said 'pushed by github-actions[bot]')"

# A human push of an unsigned commit is reported whatever the commit says.
D="$(repo humanpush)"; B="$(base_of "$D")"
commit "$D" "Jose" "jose@test.invalid" "feat: a thing" no
rc=0; run "$D" "$B" "$(base_of "$D")" "Jose" || rc=$?
check "a human push of an unsigned commit is reported" "1" "$rc"

# --- no pusher supplied: weaker signal, said out loud -----------------------
#
# Running by hand has no event payload. Falling back is fine; falling back
# silently is how the weaker rule quietly becomes the real one.
D="$(repo nopusher)"; B="$(base_of "$D")"
commit "$D" "github-actions[bot]" "x@y.invalid" "chore: whatever" no
rc=0; run "$D" "$B" "$(base_of "$D")" || rc=$?
check "with no pusher it falls back to the author field" "0" "$rc"
check "and warns that the signal is the weaker one" "1" "$(said 'falling back to the commit author field')"

# --- one unsigned among several ---------------------------------------------
D="$(repo mixed)"; B="$(base_of "$D")"
commit "$D" "Jose" "jose@test.invalid" "feat: one" yes
commit "$D" "Jose" "jose@test.invalid" "feat: two" no
commit "$D" "Jose" "jose@test.invalid" "feat: three" yes
rc=0; run "$D" "$B" "$(base_of "$D")" || rc=$?
check "one unsigned commit among several fails the run" "1" "$rc"
check "and names the offending subject only" "1" "$(said 'feat: two')"

# --- a zero before-sha checks the tip, not all of history -------------------
#
# GitHub reports a branch's first push, and some force pushes, with a zero
# before-sha. Walking the whole history there would report every pre-existing
# commit, which is noise nobody would read twice.
D="$(repo firstpush)"; commit "$D" "Jose" "jose@test.invalid" "feat: tip" yes
rc=0; run "$D" "0000000000000000000000000000000000000000" "$(base_of "$D")" || rc=$?
check "a zero before-sha passes when the tip is signed" "0" "$rc"
check "and checks exactly one commit" "1" \
	"$(grep -c '1 human commit(s) checked' "$WORK/out")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
