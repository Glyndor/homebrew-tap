#!/usr/bin/env bash
#
# A push to main that nobody judged is noticed. For every commit of `before..after`, in order:
# R1 one parent, the one before it; R2 it is "of a pull request" only on exact identity (one
# merged pull request with this merge commit into main from this repository, committed by
# web-flow with a verified signature, merged by somebody who does not bypass), and anything
# else is a direct push; R3 a commit of a pull request is on the tree of the head and every
# required check passed on it, from GitHub Actions, every attempt counted; R4 a direct push is
# accepted only from the updater app, signed by GitHub, touching only generated paths, and the
# files of the whole comparison are held to them when every commit is direct; R5 everything that
# fails, does not parse, is cut short or is absent or empty fails.
#
# Each case plants the answers of the API with a fake `gh`; each rule has a case for each way of
# breaking it and the case just inside it.
#
# Requires: jq.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$HERE/scripts/monitoring/check-push-to-main.sh"
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

B=1111111111111111111111111111111111111111
C1=2222222222222222222222222222222222222222
C2=3333333333333333333333333333333333333333
C3=4444444444444444444444444444444444444444
H1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
T1=cccccccccccccccccccccccccccccccccccccccc
T2=dddddddddddddddddddddddddddddddddddddddd
APP='updater[bot]'
mkdir "$WORK/bin" "$WORK/api"
cat >"$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in repos/*) url="$a" ;; esac; done
case "$url" in
	*/compare/*) case "$url" in *page=2*) f=compare-2 ;; *) f=compare ;; esac ;;
	*/commits/*/pulls*) f="pulls-$(printf '%s' "$url" | sed 's|.*/commits/\([^/]*\)/pulls.*|\1|')" ;;
	*/commits/*/check-runs*)
		h="$(printf '%s' "$url" | sed 's|.*/commits/\([^/]*\)/check-runs.*|\1|')"
		n="${url#*check_name=}"; n="${n%%&*}"
		case "$url" in *filter=all*) ;; *) exit 3 ;; esac
		f="checks-$h-$n" ;;
	*/pulls/*) f="pull-${url##*/}" ;;
	*/git/commits/*) f="tree-${url##*/}" ;;
	*/commits/*) f="commit-${url##*/}" ;;
	*) exit 2 ;;
esac
[ ! -e "$API/FAIL-$f" ] || exit 1
[ -e "$API/$f.json" ] || exit 1
cat "$API/$f.json"
GH
chmod +x "$WORK/bin/gh"
printf '# what the updater app writes\nFormula/\n' >"$WORK/paths.txt"
printf '# the updater first\nupdater[bot]\nother-bypasser\n' >"$WORK/actors.txt"
printf '{"checks":["audit gate","shell / test"]}' >"$WORK/ruleset.json"

# A commit as the comparison lists it: <sha> <parent> <author> <committer> <verified>
commit_json() {
	printf '{"sha":"%s","parents":[{"sha":"%s"}],"author":{"login":"%s"},"committer":{"login":"%s"},"commit":{"verification":{"verified":%s}}}' "$1" "$2" "$3" "$4" "$5"
}
# The comparison: one commit per argument "sha:parent:author:committer:verified", and the files of the whole.
compare() { # <total> <files json> <commit specs...>
	local total="$1" fl="$2" list="" sep="" spec; shift 2
	for spec in "$@"; do IFS=: read -r s p a c v <<<"$spec"; list="$list$sep$(commit_json "$s" "$p" "$a" "$c" "$v")"; sep=","; done
	printf '{"total_commits":%s,"commits":[%s],"files":%s}' "$total" "$list" "$fl" >"$WORK/api/compare.json"
}
GEN='[{"filename":"Formula/podup.rb"}]'
tree() { printf '{"tree":{"sha":"%s"}}' "$2" >"$WORK/api/tree-$1.json"; }
passed() { # <head> <name as in the url> <conclusion> <app id>
	printf '{"total_count":1,"check_runs":[{"conclusion":"%s","app":{"id":%s}}]}' "$3" "$4" >"$WORK/api/checks-$1-$2.json"
}
# A commit of a pull request, whole: merged into main from this repository by <merger>, on the tree of its head, every check passed.
pr() { # <sha> [merger]
	local sha="$1" merger="${2-human}"
	printf '[{"number":9,"merged_at":"2026-11-23T10:00:00Z","merge_commit_sha":"%s","base":{"ref":"main"},"head":{"repo":{"full_name":"Glyndor/homebrew-tap"}}}]' "$sha" >"$WORK/api/pulls-$sha.json"
	printf '{"merged_at":"2026-11-23T10:00:00Z","base":{"ref":"main"},"merged_by":{"login":"%s"},"head":{"sha":"%s"}}' "$merger" "$H1" >"$WORK/api/pull-9.json"
	tree "$sha" "$T1"; tree "$H1" "$T1"
	passed "$H1" "audit%20gate" success 15368; passed "$H1" "shell%20%2F%20test" success 15368
}
nopr() { printf '[]' >"$WORK/api/pulls-$1.json"; }
files() { # <sha> <names...>
	local sha="$1" list="" sep=""; shift
	for n in "$@"; do list="$list$sep{\"filename\":\"$n\"}"; sep=","; done
	printf '{"files":[%s]}' "$list" >"$WORK/api/commit-$sha.json"
}
# The default: one commit of a pull request, committed by web-flow, verified.
reset() { rm -f "$WORK"/api/*; compare 1 "$GEN" "$C1:$B:human:web-flow:true"; pr "$C1"; }
# One direct push of the updater app.
app() { reset; compare 1 "$GEN" "$C1:$B:$APP:web-flow:true"; nopr "$C1"; files "$C1" Formula/podup.rb; }
run() { # env overrides
	env PATH="$WORK/bin:$PATH" API="$WORK/api" REPO=Glyndor/homebrew-tap BEFORE="${BEFORE-$B}" AFTER="${AFTER-$C1}" PUSHER="${PUSHER-human}" \
		bash "$script" "${PATHS:-$WORK/paths.txt}" "${ACTORS:-$WORK/actors.txt}" "${RULESET:-$WORK/ruleset.json}" >"$WORK/log" 2>&1
	echo "rc=$?"
}
logged() { grep -c -- "$1" "$WORK/log"; }

reset
check "a commit of a pull request that was judged is accepted" "rc=0" "$(run)"
app
check "a direct push of the updater app that touches only what it writes is accepted" "rc=0" "$(PUSHER=$APP run)"

# R1 -----------------------------------------------------------------------------------------
reset; compare 1 "$GEN" "$C1:$B:human:web-flow:true"; jq '.commits[0].parents += [{"sha":"'"$C2"'"}]' "$WORK/api/compare.json" >"$WORK/t.json" && mv "$WORK/t.json" "$WORK/api/compare.json"
check "R1: a merge commit with two parents is refused" "rc=1" "$(run)"
check "R1: and the log says it is not a single commit on top of the one before" "1" "$(logged 'not a single commit on top')"
reset; compare 1 "$GEN" "$C1:$C2:human:web-flow:true"
check "R1: a commit whose parent is not before is refused (a force-push, a range that is not a line)" "rc=1" "$(run)"
reset; compare 2 "$GEN" "$C1:$B:human:web-flow:true" "$C2:$T1:human:web-flow:true"; pr "$C2"
check "R1: a second commit whose parent is not the first is refused" "rc=1" "$(AFTER=$C2 run)"
reset; compare 2 "$GEN" "$C1:$B:human:web-flow:true" "$C2:$C1:human:web-flow:true"; pr "$C1"; pr "$C2"
check "R1: two commits in a line are accepted" "rc=0" "$(AFTER=$C2 run)"
reset; jq '.commits[0].parents = []' "$WORK/api/compare.json" >"$WORK/t.json" && mv "$WORK/t.json" "$WORK/api/compare.json"
check "R1: a commit with no parent is refused" "rc=1" "$(run)"
Z0=0000000000000000000000000000000000000000
reset; compare 1 "$GEN" "$C1:$Z0:human:web-flow:true"
check "R1: a before of zeros, a new branch, is refused, though its first commit has it as its parent" "rc=1" "$(BEFORE=$Z0 run)"
reset; compare 1 "$GEN" "$C1:a;b:human:web-flow:true"
check "R1: a before that is not a hash is refused, though its first commit has it as its parent" "rc=1" "$(BEFORE='a;b' run)"
reset; check "R1: an after that is not a hash is refused" "rc=1" "$(AFTER=abc run)"
reset; compare 1 "$GEN" "$C2:$B:human:web-flow:true"; pr "$C2"
check "R1: a push that does not end in the commit it says is refused" "rc=1" "$(run)"

# R2 -----------------------------------------------------------------------------------------
reset; compare 1 "$GEN" "$C1:$B:human:someone:true"
check "R2: a commit whose committer is not web-flow is a direct push, and a human's is refused" "rc=1" "$(run)"
check "R2: and the log says it has a pull request that was not judged, and not that it is a direct push" "1" "$(logged 'has a pull request but is not the merge of one that was judged')"
reset; compare 1 "$GEN" "$C1:$B:human:web-flow:false"
check "R2: a commit whose signature GitHub did not verify is a direct push, and a human's is refused" "rc=1" "$(run)"
reset; pr "$C1" "$APP"
check "R2: a pull request merged by the updater app is a direct push, and its author is not the app" "rc=1" "$(PUSHER=$APP run)"
check "R2: and the log says it has a pull request that was not judged" "1" "$(logged 'has a pull request but is not the merge of one that was judged')"
reset; pr "$C1" other-bypasser
check "R2: a pull request merged by another actor that bypasses is a direct push too" "rc=1" "$(run)"
reset; pr "$C1" ""
check "R2: a pull request that nobody merged is not read as judged" "rc=1" "$(run)"
app; pr "$C1" ""
check "R2: a pull request that nobody merged is not read as a direct push of the app either" "rc=1" "$(PUSHER=$APP run)"
reset; printf '{"merged_at":"2026-11-23T10:00:00Z","base":{"ref":"main"},"head":{"sha":"%s"}}' "$H1" >"$WORK/api/pull-9.json"
check "R2: a pull request with no merged_by field is not read as judged" "rc=1" "$(run)"
reset; jq '.[0].base.ref = "develop"' "$WORK/api/pulls-$C1.json" >"$WORK/t.json" && mv "$WORK/t.json" "$WORK/api/pulls-$C1.json"
check "R2: a pull request into another branch does not make the commit one of a pull request" "rc=1" "$(run)"
reset; jq '.[0].merge_commit_sha = "'"$C2"'"' "$WORK/api/pulls-$C1.json" >"$WORK/t.json" && mv "$WORK/t.json" "$WORK/api/pulls-$C1.json"
check "R2: a pull request whose merge commit is another does not make the commit one of a pull request" "rc=1" "$(run)"
reset; jq '.[0].merged_at = null' "$WORK/api/pulls-$C1.json" >"$WORK/t.json" && mv "$WORK/t.json" "$WORK/api/pulls-$C1.json"
check "R2: a pull request that is not merged does not make the commit one of a pull request" "rc=1" "$(run)"
reset; jq '.[0].head.repo.full_name = "someone/homebrew-tap"' "$WORK/api/pulls-$C1.json" >"$WORK/t.json" && mv "$WORK/t.json" "$WORK/api/pulls-$C1.json"
check "R2: a pull request from a fork does not make the commit one of a pull request" "rc=1" "$(run)"
reset; jq '. + .' "$WORK/api/pulls-$C1.json" >"$WORK/t.json" && mv "$WORK/t.json" "$WORK/api/pulls-$C1.json"
check "R2: two pull requests do not make the commit one of a pull request" "rc=1" "$(run)"
reset; compare 1 "$GEN" "$C1:$B::web-flow:true"
check "R2: an author with no login is nobody, and the commit is refused" "rc=1" "$(run)"
reset; touch "$WORK/api/FAIL-pulls-$C1"
check "R2: pull requests that cannot be read are a failure" "rc=1" "$(run)"
reset; rm -f "$WORK/api/pull-9.json"
check "R2: a pull request that cannot be read in full is a failure" "rc=1" "$(run)"
reset; printf '{"merged_at":null,"base":{"ref":"main"},"merged_by":{"login":"human"},"head":{"sha":"%s"}}' "$H1" >"$WORK/api/pull-9.json"
check "R2: a pull request whose own answer says it is not merged is a failure" "rc=1" "$(run)"
reset; printf '{"merged_at":"2026-11-23T10:00:00Z","base":{"ref":"develop"},"merged_by":{"login":"human"},"head":{"sha":"%s"}}' "$H1" >"$WORK/api/pull-9.json"
check "R2: a pull request whose own answer says another base is a failure" "rc=1" "$(run)"

# A commit that has a pull request is never read as a direct push.
app; printf '[{"number":4,"merged_at":null,"merge_commit_sha":null,"base":{"ref":"main"},"head":{"repo":{"full_name":"Glyndor/homebrew-tap"}}}]' >"$WORK/api/pulls-$C1.json"
check "R2: a commit that another pull request only references is refused, though the app pushed it and it writes only generated paths" "rc=1" "$(PUSHER=$APP run)"
check "R2: and the log says it has a pull request that was not judged" "1" "$(logged 'has a pull request but is not the merge of one that was judged')"
app; printf '[{"number":4,"merged_at":"2026-11-23T10:00:00Z","merge_commit_sha":"%s","base":{"ref":"main"},"head":{"repo":{"full_name":"Glyndor/homebrew-tap"}}}]' "$C2" >"$WORK/api/pulls-$C1.json"
check "R2: a commit that a merged pull request has in its history, but not as its merge commit, is refused" "rc=1" "$(PUSHER=$APP run)"
app; printf '{"nope":1}' >"$WORK/api/pulls-$C1.json"
check "R2: pull requests that come back as something that is not a list are a failure" "rc=1" "$(PUSHER=$APP run)"
check "R2: and the log says they cannot be read" "1" "$(logged 'pull requests of .* cannot be read')"

# R3 -----------------------------------------------------------------------------------------
reset; tree "$H1" "$T2"
check "R3: a commit on another tree than the head of its pull request is refused" "rc=1" "$(run)"
check "R3: and the log says what landed is not what was judged" "1" "$(logged 'not on the tree of the head')"
reset; rm -f "$WORK/api/tree-$H1.json"
check "R3: a head whose tree cannot be read is refused" "rc=1" "$(run)"
reset; rm -f "$WORK/api/tree-$C1.json"
check "R3: a commit whose tree cannot be read is refused" "rc=1" "$(run)"
reset; rm -f "$WORK/api/checks-$H1-shell%20%2F%20test.json"
check "R3: a required check with no run on the head is refused" "rc=1" "$(run)"
check "R3: and the log names the check" "1" "$(logged "without 'shell / test' in success")"
reset; passed "$H1" "shell%20%2F%20test" failure 15368
check "R3: a required check that failed is refused" "rc=1" "$(run)"
reset; passed "$H1" "shell%20%2F%20test" success 1
check "R3: a required check from another app is refused" "rc=1" "$(run)"
reset; printf '{"total_count":2,"check_runs":[{"conclusion":"failure","app":{"id":15368}},{"conclusion":"success","app":{"id":15368}}]}' >"$WORK/api/checks-$H1-audit%20gate.json"
check "R3: an aggregator that failed once and passed after is refused, every attempt counts" "rc=1" "$(run)"
reset; printf '{"total_count":3,"check_runs":[{"conclusion":"success","app":{"id":15368}}]}' >"$WORK/api/checks-$H1-audit%20gate.json"
check "R3: a list of checks that is cut short is refused" "rc=1" "$(run)"
reset; printf '{"total_count":0,"check_runs":[]}' >"$WORK/api/checks-$H1-audit%20gate.json"
check "R3: a required check with no run at all is refused" "rc=1" "$(run)"
reset; printf 'not json' >"$WORK/api/checks-$H1-audit%20gate.json"
check "R3: a list of checks that is not JSON is refused" "rc=1" "$(run)"
reset; printf '{"total_count":2,"check_runs":[{"conclusion":"success","app":{"id":15368}},{"conclusion":"failure","app":{"id":99}}]}' >"$WORK/api/checks-$H1-audit%20gate.json"
check "R3: a check of the same name from another app does not take part in the reading" "rc=0" "$(run)"
reset; printf '{"checks":[]}' >"$WORK/empty.json"
check "R3: a copy of the ruleset that lists no required check is refused" "rc=1" "$(RULESET="$WORK/empty.json" run)"
reset; check "R3: a copy of the ruleset that cannot be read is refused" "rc=1" "$(RULESET="$WORK/none.json" run)"

# R4 -----------------------------------------------------------------------------------------
app; check "R4: a direct push of a human that touches only Formula/ is refused" "rc=1" "$(PUSHER=human run)"
check "R4: and the log says an actor that is not authorised" "1" "$(PUSHER=human run >/dev/null; logged 'an actor that is not authorised')"
app; check "R4: a direct push by another actor that bypasses is refused, only the updater app may" "rc=1" "$(PUSHER=other-bypasser run)"
reset; check "R4: a push with nobody named as the pusher is refused, even when its commit is of a pull request" "rc=1" "$(PUSHER='' run)"
app; files "$C1" Formula/podup.rb scripts/release/render-formulae.sh
check "R4: a direct push of the app that touches a script is refused" "rc=1" "$(PUSHER=$APP run)"
check "R4: and the log names the file" "1" "$(logged 'touches scripts/release/render-formulae.sh')"
app; files "$C1" .github/workflows/tests.yml
check "R4: a direct push of the app that touches a workflow is refused" "rc=1" "$(PUSHER=$APP run)"
app; printf '{"files":[{"filename":"Formula/a.rb","previous_filename":"scripts/x.sh"}]}' >"$WORK/api/commit-$C1.json"
check "R4: a rename from outside into Formula/ is refused" "rc=1" "$(PUSHER=$APP run)"
app; printf '{"files":[{"filename":"scripts/x.sh","previous_filename":"Formula/a.rb"}]}' >"$WORK/api/commit-$C1.json"
check "R4: a rename from Formula/ to outside is refused" "rc=1" "$(PUSHER=$APP run)"
app; files "$C1" "" Formula/podup.rb
check "R4: a file with no name among the files of a direct push is refused" "rc=1" "$(PUSHER=$APP run)"
app; files "$C1" Formulary/podup.rb
check "R4: a path that only begins like the generated one is refused" "rc=1" "$(PUSHER=$APP run)"
app; files "$C1" scripts/Formula/podup.sh
check "R4: a path that has the generated one inside it is refused" "rc=1" "$(PUSHER=$APP run)"
app; printf '{"files":[]}' >"$WORK/api/commit-$C1.json"
check "R4: a direct push that touches no file is refused" "rc=1" "$(PUSHER=$APP run)"
app; rm -f "$WORK/api/commit-$C1.json"
check "R4: a direct push whose files cannot be read is refused" "rc=1" "$(PUSHER=$APP run)"
app; jq -nc '{files: [range(0;300) | {filename: "Formula/f\(.).rb"}]}' >"$WORK/api/commit-$C1.json"
check "R4: a direct push with as many files as the API lists at most is refused" "rc=1" "$(PUSHER=$APP run)"
app; compare 1 "$GEN" "$C1:$B:human:web-flow:true"; nopr "$C1"; files "$C1" Formula/podup.rb
check "R4: a direct push whose author is not the app is refused though the pusher is" "rc=1" "$(PUSHER=$APP run)"
app; compare 1 "$GEN" "$C1:$B:$APP:someone:true"; nopr "$C1"; files "$C1" Formula/podup.rb
check "R4: a direct push whose committer is not web-flow is refused" "rc=1" "$(PUSHER=$APP run)"
app; compare 1 "$GEN" "$C1:$B:$APP:web-flow:false"; nopr "$C1"; files "$C1" Formula/podup.rb
check "R4: a direct push whose signature GitHub did not verify is refused" "rc=1" "$(PUSHER=$APP run)"
app; compare 1 '[{"filename":"Formula/podup.rb"},{"filename":"scripts/x.sh"}]' "$C1:$B:$APP:web-flow:true"
check "R4: when every commit is direct, the files of the whole comparison are held to the generated paths" "rc=1" "$(PUSHER=$APP run)"
check "R4: and the log names the file of the comparison" "1" "$(logged 'the push touches scripts/x.sh')"
app; compare 1 '[]' "$C1:$B:$APP:web-flow:true"
check "R4: a comparison with no file is refused" "rc=1" "$(PUSHER=$APP run)"
app; compare 1 '[{"filename":"Formula/a.rb","previous_filename":"scripts/x.sh"}]' "$C1:$B:$APP:web-flow:true"
check "R4: a rename in the comparison from outside is refused" "rc=1" "$(PUSHER=$APP run)"
app; jq -nc '[range(0;300) | {filename: "Formula/f\(.).rb"}]' >"$WORK/t.json"; compare 1 "$(cat "$WORK/t.json")" "$C1:$B:$APP:web-flow:true"
check "R4: a comparison with as many files as can be listed at most is refused" "rc=1" "$(PUSHER=$APP run)"
reset; check "R4: a file of actors that cannot be read is refused, whatever the push is" "rc=1" "$(ACTORS="$WORK/none.txt" run)"
check "R4: and the log says it cannot be read" "1" "$(logged 'none.txt cannot be read')"
reset; printf '# nobody\n' >"$WORK/noactors.txt"; check "R4: a file of actors that lists nobody is refused, whatever the push is" "rc=1" "$(ACTORS="$WORK/noactors.txt" run)"
check "R4: and the log says it lists nothing" "1" "$(logged 'noactors.txt lists nothing')"
reset; check "R4: a file of paths that cannot be read is refused, whatever the push is" "rc=1" "$(PATHS="$WORK/none.txt" run)"
check "R4: and the log says it cannot be read" "1" "$(logged 'none.txt cannot be read')"
reset; printf '# nothing\n' >"$WORK/nopaths.txt"; check "R4: a file of paths that lists nothing is refused, whatever the push is" "rc=1" "$(PATHS="$WORK/nopaths.txt" run)"
check "R4: and the log says it lists nothing" "1" "$(logged 'nopaths.txt lists nothing')"
app; printf '# the first is not a login\n\nupdater[bot]\n' >"$WORK/actors2.txt"; check "R4: blank and comment lines are not logins, the updater is the first login" "rc=0" "$(PUSHER=$APP ACTORS="$WORK/actors2.txt" run)"
app; printf '[bot]\nupdater[bot]\n' >"$WORK/actors3.txt"; check "R4: the pusher has to be the first login of the list exactly" "rc=1" "$(PUSHER=$APP ACTORS="$WORK/actors3.txt" run)"

# A mixed push: the whole comparison is held to the paths only when every commit is direct.
reset; compare 2 '[{"filename":"Formula/podup.rb"},{"filename":"scripts/x.sh"}]' "$C1:$B:$APP:web-flow:true" "$C2:$C1:human:web-flow:true"; nopr "$C1"; files "$C1" Formula/podup.rb; pr "$C2"
check "a push of a commit of the app and then a pull request that was judged is accepted" "rc=0" "$(AFTER=$C2 PUSHER=$APP run)"

# R5 -----------------------------------------------------------------------------------------
reset; touch "$WORK/api/FAIL-compare"
check "R5: a comparison that cannot be read is a failure" "rc=1" "$(run)"
reset; printf 'not json' >"$WORK/api/compare.json"
check "R5: a comparison that is not JSON is a failure" "rc=1" "$(run)"
reset; printf '{"total_commits":1,"commits":[]}' >"$WORK/api/compare.json"
check "R5: a comparison with no list of files is a failure" "rc=1" "$(run)"
reset; compare 5 "$GEN" "$C1:$B:human:web-flow:true"
check "R5: a list of commits cut short, with no second page, is a failure" "rc=1" "$(run)"
reset; compare 3 "$GEN" "$C1:$B:human:web-flow:true" "$C2:$C1:human:web-flow:true"; pr "$C1"; pr "$C2"; pr "$C3"
printf '{"total_commits":3,"commits":[%s],"files":%s}' "$(commit_json "$C3" "$C2" human web-flow true)" "$GEN" >"$WORK/api/compare-2.json"
check "R5: a push of three commits on two pages is read whole" "rc=0" "$(AFTER=$C3 run)"
rm -f "$WORK/api/compare-2.json"
check "R5: a second page that cannot be read is a failure" "rc=1" "$(AFTER=$C3 run)"
reset; compare 1 "$GEN" "$C1:$B:human:web-flow:true" "$C2:$C1:human:web-flow:true"; pr "$C1"; pr "$C2"
check "R5: more commits than the comparison counts are a failure" "rc=1" "$(AFTER=$C2 run)"
reset; compare 300 "$GEN" "$C1:$B:human:web-flow:true"
check "R5: a push with more commits than the cap is an explicit failure" "rc=1" "$(run)"
check "R5: and the log says how many and what the cap is" "1" "$(logged 'has 300 commits, more than the 200')"
reset; compare 200 "$GEN" "$C1:$B:human:web-flow:true"
check "R5: a push at the cap whose list is cut short is a failure" "rc=1" "$(run)"
reset; compare 3 "$GEN" "$C1:$B:human:web-flow:true"; printf '{"total_commits":3,"commits":[],"files":[]}' >"$WORK/api/compare-2.json"
check "R5: a page that is empty before the count is reached is a failure, not a loop" "rc=1" "$(AFTER=$C3 run)"
check "R5: and the log says the page is empty" "1" "$(logged 'is empty before the count')"
reset; compare 0 "$GEN"
check "R5: a push with no commit is a failure" "rc=1" "$(run)"
reset; check "R5: no repository is a failure" "rc=1" "$(env PATH="$WORK/bin:$PATH" API="$WORK/api" REPO= BEFORE=$B AFTER=$C1 PUSHER=human bash "$script" "$WORK/paths.txt" "$WORK/actors.txt" "$WORK/ruleset.json" >/dev/null 2>&1; echo "rc=$?")"
reset; check "the same push with the right inputs passes again" "rc=0" "$(run)"

echo
echo "passed: $pass  failed: $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
