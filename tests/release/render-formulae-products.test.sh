#!/usr/bin/env bash
# PRODUCTS is repository-controlled, but its fields become paths and Ruby.
# The renderer refuses names and metadata that would become a path or Ruby code.
# Never evaluate a generated formula: ruby -c is the only Ruby invocation.
set -euo pipefail
HERE_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../fixtures/release" && pwd)"
# shellcheck disable=SC1091
. "$HERE_FIXTURE/render-fixture.sh"
pass=0
fail=0
if ! command -v ruby >/dev/null; then
	echo "UNVERIFIED: ruby is required for syntax-only checks" >&2
fi
publish Glyndor/podup v9.9.9 podup-darwin-arm64 podup-darwin-x86_64

# Quote each row as shell data. The shared awk writer interprets backslashes;
# using it here would mutate the very bytes these tests are meant to exercise.
prepare() { # $1=field (zero-based), $2=value
	new_root "$WORK/hostile"
	python3 - "$GENERATOR" "$WORK/hostile/scripts/release/render-formulae.sh" "$PODUP" "$1" "$2" <<'PY'
from pathlib import Path
import shlex, sys
source, target, row, field, value = sys.argv[1:]
fields = row.split('|')
fields[int(field)] = value
text = Path(source).read_text()
start = text.index('PRODUCTS=(')
end = text.index('\n)', start) + 2
Path(target).write_text(text[:start] + 'PRODUCTS=(\n\t' + shlex.quote('|'.join(fields)) + '\n)' + text[end:])
PY
	chmod +x "$WORK/hostile/scripts/release/render-formulae.sh"
}

render() {
	rc=0
	run "$WORK/hostile/scripts/release/render-formulae.sh" "$WORK/hostile" || rc=$?
}

syntax() { # $1=formula path; parsing must never execute its contents
	local status=0
	ruby -c -- "$1" > "$WORK/ruby.out" 2>&1 || status=$?
	printf '%s' "$status"
}

prepare 1 pod-up
render
check "a hyphenated product name renders" "0" "$rc"
# The syntax check needs ruby. CI installs it, so there a missing ruby is a
# failure; on a machine without it the check is reported as unverified, not
# counted as passed.
if command -v ruby >/dev/null; then
	check "the positive formula parses without evaluation" "0" "$(syntax "$WORK/hostile/Formula/pod-up.rb")"
elif [ -n "${CI:-}" ]; then
	check "ruby is available to parse the positive formula in CI" "present" "missing"
else
	echo "UNVERIFIED  the positive formula parses without evaluation (no ruby on this machine)"
fi
contains "the installed binary uses the declared name" "$WORK/hostile/Formula/pod-up.rb" 'bin.install asset => "pod-up"'

# Each hostile value must be refused before anything is written, with an error
# that names the entry; none of them may leave a formula anywhere in the root.
refused() { # $1=what $2=field index $3=value $4=expected message fragment
	prepare "$2" "$3"
	render
	check "$1 is refused" "3" "$rc"
	contains "$1: the error names the problem" "$WORK/out" "$4"
	check "$1 writes no formula anywhere" "0" "$(find "$WORK/hostile" -name '*.rb' | wc -l)"
}

refused "traversal" 1 '../outside' 'invalid formula name'
check "traversal leaves nothing outside Formula" "0" "$([ -f "$WORK/hostile/outside.rb" ] && echo 1 || echo 0)"
mkdir -p "$WORK/hostile/Formula/a"
refused "a nested name, even where the directory exists" 1 'a/b' 'invalid formula name'
for name in '-foo' 'with space' 'pod"up' 'pod\up' 'pód-up' 'UPPER'; do
	refused "name [$name]" 1 "$name" 'invalid formula name'
done

prepare 1 $'pod\nup'
render
check "a newline truncates the row and is refused" "3" "$rc"
contains "the refusal identifies the first missing field" "$WORK/out" 'has no cls'
check "a truncated name writes no Ruby" "0" "$(find "$WORK/hostile" -name '*.rb' | wc -l)"

# Parseable injected Ruby is still unsafe, so the class name is held to a
# constant. The marker must never be created in either case.
marker="$WORK/should-never-exist"
refused "a Ruby class containing a semicolon" 2 "Podup; File.write(\"$marker\", \"executed\")" 'invalid class name'
check "and nothing executed it" "0" "$([ -e "$marker" ] && echo 1 || echo 0)"
refused "a lowercase class" 2 'podup' 'invalid class name'

# Licence, description and version check are written inside Ruby quotes.
for field in 3 4 9; do
	refused "a quote in metadata field $field" "$field" 'text"quoted' 'would end or escape a Ruby string'
	refused "a backslash in metadata field $field" "$field" 'path\name' 'would end or escape a Ruby string'
	refused "an interpolation in metadata field $field" "$field" 'text#{1}' 'would end or escape a Ruby string'
done
prepare 4 $'line one\nline two'
render
check "a newline description truncates the row and is refused" "3" "$rc"
contains "the description newline refusal names the missing asset" "$WORK/out" 'has no mac_arm'
check "a truncated description writes no Ruby" "0" "$(find "$WORK/hostile" -name '*.rb' | wc -l)"

# Ordinary punctuation stays legal: the policy must not refuse the real roster.
prepare 4 'Run Compose projects on rootless Podman (fast, simple)'
render
check "an ordinary description with punctuation renders" "0" "$rc"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
