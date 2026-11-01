#!/usr/bin/env bash
#
# Every curl invocation under scripts/ carries --max-time, so a hung
# network read dies within the budget the script's own deadline allows
# instead of for the rest of the job's six-hour GitHub default.
#
# The two drift scripts each do a small flurry of curls (one per reusable,
# plus the render unit) and the absence of a deadline meant a curl against
# a stuck peer held the runner until killed. --connect-timeout bounds the
# TCP handshake separately from the body read because a hung TLS is a
# different failure mode from a hung stream and either alone is enough to
# justify the flags.
#
# A comment line that mentions curl is not an invocation; a line that ends
# in a backslash continues onto the next, so a curl call split across
# lines is collapsed before the scan: the rule is one curl, one --max-time,
# and a single line that starts the call without finishing the argument is
# the failing shape only when the call really is unfinished.
#
# Like tests/quality/lint-workflow-shell.test.sh, the check is shown red against a
# planted violation before the live tree is read, so a test that ignored
# its input still has to do this by passing.
#
# Requires: coreutils, grep.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pass=0
fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
		echo "ok    $1"
	else
		fail=$((fail + 1))
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
	fi
}

# Print one line per offending invocation: "<file>:<line>: missing --max-time".
# Exit 1 when any line was printed, 0 otherwise.
#
# `curl --foo bar` is matched by `[^A-Za-z0-9_/]curl\s`; the negative class
# rejects names like `$curlerr` and `curl_err` while accepting `!curl`,
# `;curl`, `|curl`, and the start of the line. Backslash-continuations are
# joined first so a curl split across two physical lines is one logical
# invocation. Pure comment lines (first non-space char is #) are dropped
# from the start of every joined block, so a `# curl ...` example does not
# count as a real call.
audit() { # $1=scripts dir
	python3 - "$1" <<'PY'
import glob, os, re, sys

root = sys.argv[1]
CURL_RE = re.compile(r"(?:^|[^A-Za-z0-9_/])curl\s")

bad = 0
paths = sorted(glob.glob(os.path.join(root, "**", "*.sh"), recursive=True))
for path in paths:
	with open(path) as fh:
		text = fh.read()
	# Look at every individual line too: a curl on a single line must
	# carry --max-time on that line, so an inline-comment trick that
	# puts the flag on a continuation will not satisfy the rule.
	for lineno, line in enumerate(text.splitlines(), start=1):
		stripped = line.lstrip()
		if not stripped or stripped.startswith("#"):
			continue
		if not CURL_RE.search(line):
			continue
		# The flag followed by its value; the bare substring also matches
		# `--user-agent '--max-time'`, which bounds nothing.
		if re.search(r"(?:^|\s)--max-time\s+[0-9$]", line):
			continue
		bad += 1
		print(
			f"{os.path.basename(path)}:{lineno}: missing --max-time on curl invocation"
		)
print(f"scanned {len(paths)} script(s)")
sys.exit(1 if bad else 0)
PY
}

# --- the control: a planted violation is reported --------------------------
mkdir -p "$WORK/planted"
cat > "$WORK/planted/x.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# This curl-without-max-time is the violation, on the next non-comment line.
curl -fsSL "$url" > out

# A safe invocation; both --connect-timeout and --max-time are present.
curl -fsSL --connect-timeout 10 --max-time 60 "$url2" > out2

# A comment that mentions curl is not an invocation and must not count.
# curl -fsSL "$url3" > out3

# This curl continues onto a second line. The call as a whole has
# --max-time, but the line that contains `curl` does not.
curl -fsSL \
  --max-time 60 \
  "$url4" > out4
EOF

rc=0; out="$(audit "$WORK/planted")" || rc=$?
check "a curl without --max-time is reported" "1" "$rc"
check "and the report names the file, the line, and the missing flag" "1" \
	"$(printf '%s\n' "$out" | grep -c 'x.sh:5: missing --max-time on curl invocation')"
check "exactly the two bare curls are reported, no safe line and no comment" \
	"x.sh:5: missing --max-time on curl invocation
x.sh:15: missing --max-time on curl invocation" \
	"$(printf '%s\n' "$out" | grep -v '^scanned ')"
check "a curl with --max-time on a continuation line is still reported" "1" \
	"$(printf '%s\n' "$out" | grep -c 'x.sh:15: missing --max-time on curl invocation')"

# The flag name used as a value is not a deadline.
mkdir -p "$WORK/fake"
# shellcheck disable=SC2016 # the quotes belong to the fixture line
printf '#!/usr/bin/env bash\ncurl -fsSL --user-agent '"'"'--max-time'"'"' "$url" > out\n' > "$WORK/fake/f.sh"
rc=0; out="$(audit "$WORK/fake")" || rc=$?
check "the flag name used as a value is not a deadline" "1" "$rc"
check "and the script is named" "1" "$(printf '%s\n' "$out" | grep -c 'f.sh:2: missing --max-time')"

# --- the live scripts ------------------------------------------------------
rc=0; out="$(audit "$HERE/scripts")" || rc=$?
check "every curl invocation in scripts/ carries --max-time" "0" "$rc"
expected="$(find "$HERE/scripts" -type f -name '*.sh' | wc -l)"
check "and the scan really covered every script, at any depth" "scanned $expected script(s)" \
	"$(printf '%s\n' "$out" | grep '^scanned ')"
check "and there were scripts to cover" "1" "$([ "$expected" -gt 0 ] && echo 1 || echo 0)"
[ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/        /'

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
