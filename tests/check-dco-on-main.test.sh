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

run() { # $1=repo $2=before $3=after
	( cd "$1" && "$CHECK" "$2" "$3" ) >"$WORK/out" 2>&1
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
check "and the run says it was skipped and why" "1" "$(said 'authored by github-actions[bot]')"

# --- the exemption keys on the author, not the message ----------------------
#
# If it matched the bot's subject line instead, copying that line would be all
# it took to walk past the check.
D="$(repo impostor)"; B="$(base_of "$D")"
commit "$D" "Jose" "jose@test.invalid" \
	"chore: update formulae from the latest signed releases" no
rc=0; run "$D" "$B" "$(base_of "$D")" || rc=$?
check "a human using the bot's exact subject is still reported" "1" "$rc"

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
