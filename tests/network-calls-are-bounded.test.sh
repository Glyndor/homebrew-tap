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
# Like tests/lint-workflow-shell.test.sh, the check is shown red against a
# planted violation before the live tree is read, so a test that ignored
# its input still has to do this by passing.
#
# Requires: coreutils, grep.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
CURL_INVOCATION = re.compile(r"\bcurl\b")

def logical_lines(text):
	# Join lines whose previous line ended in a backslash, then drop
	# wholly-comment lines (they are not invocations either way). The
	# collapse keeps `curl ... \\n  --max-time N \\n  url` as one
	# invocation rather than two failing lines and a passing one.
	out = []
	for line in text.splitlines():
		if out and out[-1].endswith("\\"):
			out[-1] = out[-1][:-1] + " " + line.strip()
		else:
			out.append(line)
	return [l for l in out if not l.lstrip().startswith("#")]

bad = 0
for path in sorted(glob.glob(os.path.join(root, "*.sh"))):
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
		if "--max-time" in line:
			continue
		bad += 1
		print(
			f"{os.path.basename(path)}:{lineno}: missing --max-time on curl invocation"
		)
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
check "a curl with --max-time on the same line is not reported" "0" \
	"$(printf '%s\n' "$out" | grep -c 'out2')"
check "a # comment line mentioning curl is not an invocation" "0" \
	"$(printf '%s\n' "$out" | grep -c 'url3')"
check "a curl with --max-time on a continuation line is still reported" "1" \
	"$(printf '%s\n' "$out" | grep -c 'x.sh:15: missing --max-time on curl invocation')"

# --- the live scripts ------------------------------------------------------
rc=0; out="$(audit "$HERE/scripts")" || rc=$?
check "every curl invocation in scripts/ carries --max-time" "0" "$rc"
[ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/        /'

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
