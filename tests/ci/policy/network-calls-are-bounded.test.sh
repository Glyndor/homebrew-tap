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
# Comments do not carry arguments. Each curl must carry its own deadline on
# the physical line that starts the invocation, even when the call continues.
#
# Like tests/quality/lint-workflow-shell.test.sh, the check is shown red against a
# planted violation before the live tree is read, so a test that ignored
# its input still has to do this by passing.
#
# Requires: python3, coreutils, grep.

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
# Tokenize each physical command line with shell quoting and comments, then
# inspect each curl separately. Keep the deadline beside curl on that line;
# a deadline supplied only on a continuation remains a policy violation.
audit() { # $1=scripts dir
	python3 - "$1" <<'PY'
import glob, os, re, shlex, sys

root = sys.argv[1]
# These options consume the following word, even when it looks like a flag.
VALUE_OPTIONS = {"--user-agent", "-A", "--header", "-H", "--output", "-o",
                 "--url", "--data", "-d", "--connect-timeout", "--proto-redir",
                 "--max-filesize", "--retry", "--retry-delay", "--retry-max-time"}

def bounded(argv):
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            break
        if arg == "--max-time" or arg.startswith("--max-time="):
            value = arg.split("=", 1)[1] if "=" in arg else (argv[i + 1] if i + 1 < len(argv) else "")
            if re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", value):
                return float(value) > 0
            return bool(re.fullmatch(r"\$(?:[A-Za-z_]\w*|\{[A-Za-z_]\w*\})", value))
        i += 2 if arg in VALUE_OPTIONS else 1
    return False

bad = 0
paths = sorted(glob.glob(os.path.join(root, "**", "*.sh"), recursive=True))
for path in paths:
    for lineno, line in enumerate(open(path), start=1):
        if not re.search(r"(?:^|[^A-Za-z0-9_/])curl\s", line) or line.lstrip().startswith("#"):
            continue
        # A trailing backslash continues the call but is not an argument.
        line = line.rstrip("\n").removesuffix("\\")
        lexer = shlex.shlex(line, posix=True, punctuation_chars=";&|()")
        lexer.whitespace_split = True
        try:
            words = list(lexer)  # shlex removes unquoted comments, preserving quoted '#'.
        except ValueError as error:
            print(f"{os.path.basename(path)}:{lineno}: cannot parse curl: {error}")
            bad += 1
            continue
        for i, word in enumerate(words):
            if word != "curl":
                continue
            end = next((j for j in range(i + 1, len(words))
                        if set(words[j]) <= set(";&|()")), len(words))
            if bounded(words[i + 1:end]):
                continue
            bad += 1
            print(f"{os.path.basename(path)}:{lineno}: missing --max-time on curl invocation")
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

# A deadline belongs to one invocation, never to a comment or its neighbour.
# shellcheck disable=SC2016 # literal shell input for the parser
for call in \
	'curl -fsSL "$url" # --max-time 60' \
	'curl --max-time 60 "$url"; curl -fsSL "$url2"' \
	'curl -fsSL "$url"; curl --max-time 60 "$url2"'; do
	printf '%s\n' "$call" > "$WORK/fake/f.sh"
	rc=0; out="$(audit "$WORK/fake")" || rc=$?
	check "rejects ineffective deadline: $call" "1" "$rc"
	check "one invocation lacks a deadline" "1" "$(printf '%s\n' "$out" | grep -c 'missing --max-time')"
done

# shellcheck disable=SC2016 # literal shell input for the parser
printf '%s\n' 'curl --max-time 60 "https://example.test/#fragment"; curl --max-time=30 "$url"' > "$WORK/fake/f.sh"
rc=0; audit "$WORK/fake" >/dev/null || rc=$?
check "two bounded invocations and a quoted hash pass" "0" "$rc"

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
