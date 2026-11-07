#!/usr/bin/env python3
"""The comparison behind scripts/artifacts/check-formulae.sh.

usage: check-formulae.py <roster-block> <repo-root> <formula>...

It prints one tab-separated record per line: "ok<TAB>file" for a formula that
matches its roster row, "file<TAB>message" for a problem, and a last
"VERDICT<TAB>n" that counts the problems. The shell wrapper finds the formulae,
cuts the roster out of the generator and turns the records into annotations.
"""
import os
import re
import sys

FIELDS = ("repo", "formula", "cls", "licence", "desc",
          "mac_arm", "mac_intel", "linux_arm", "linux_intel", "version_check")
ROSTER = "scripts/release/render-formulae.sh"
VERSION_RE = re.compile(r"^[0-9](?:[0-9A-Za-z.+-]*[0-9A-Za-z.+-])?$")
DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")
URL_RE = re.compile(r"^https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/([^/]+)$")
# Statements the generator never writes, and what each of them would do. Named
# so the message says what the statement is, not only that it is not allowed.
RUNS = ("system", "exec", "post_install", "pre_install", "post_upgrade", "livecheck")
OTHERS = ("resource", "patch", "depends_on", "devel", "head", "bottle", "service")


def add(problems, number, field, message):
    problems.append("line %d: %s: %s" % (number, field, message))


def hint(line):
    """What a statement the generator does not write would do."""
    if "`" in line:
        return "; a backtick runs a command"
    match = re.match(r"[A-Za-z_][A-Za-z0-9_]*", line)
    word = match.group(0) if match else ""
    if word in RUNS:
        return "; `%s` runs code on the user's machine" % word
    return "; `%s` changes what the install does" % word if word in OTHERS else ""


def asset_expr(arm, intel):
    """The Ruby expression the generator writes for one platform."""
    if arm != "-" and intel != "-":
        return 'Hardware::CPU.arm? ? "%s" : "%s"' % (arm, intel)
    if arm == "-" and intel == "-":
        return None
    return '"%s"' % (arm if arm != "-" else intel)


def install_body(row):
    """The statements the generator writes inside `def install`."""
    mac = asset_expr(row["mac_arm"], row["mac_intel"])
    linux = asset_expr(row["linux_arm"], row["linux_intel"])
    if mac and linux:
        body = ["asset = if OS.mac?", mac, "else", linux, "end"]
    else:
        body = ["asset = " + (mac or linux)]
    body.append('bin.install asset => "%s"' % row["formula"])
    return body


class Reader(object):
    """The formula's lines, compared with what the generator writes."""

    def __init__(self, text):
        self.lines = [(number, line.strip()) for number, line in enumerate(text.split("\n"), 1)
                      if line.strip() and not line.strip().startswith("#")]
        self.at = 0
        self.broken = False
        self.problems = []

    def take(self):
        if self.at >= len(self.lines):
            return None, None
        number, line = self.lines[self.at]
        self.at += 1
        return number, line

    def want(self, wanted, field, caution=True):
        """The next line must be exactly what the generator writes there."""
        if self.broken:
            return None
        number, line = self.take()
        if line is None:
            self.broken = True
            self.problems.append("body: the formula ends early; the generator writes `%s` here" % wanted)
            return None
        if line != wanted:
            self.broken = True
            detail = hint(line) if caution else ""
            said = "the generator does not write it%s" % detail if detail else "the generator writes `%s`" % wanted
            self.problems.append("line %d: %s: the formula says `%s`; %s" % (number, field, line, said))
        return line

    def want_shape(self, pattern, field, wanted):
        """The next line must have the shape the generator writes there."""
        if self.broken:
            return None
        number, line = self.take()
        match = re.fullmatch(pattern, line) if line is not None else None
        if match is None:
            self.broken = True
            self.problems.append("line %d: %s: the formula says `%s`; the generator writes %s" % (number or 0, field, line, wanted))
            return None
        return match.group(1)

    def want_end(self):
        """Nothing may follow the class."""
        if self.broken:
            return
        number, line = self.take()
        if line is not None:
            self.problems.append("line %d: body: the formula says `%s`; the generator writes nothing after the class" % (number, line))


def read_roster(path):
    """The rows of the PRODUCTS table, and the problems reading it."""
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError as error:
        return [], ["cannot read the PRODUCTS roster in %s: %s" % (ROSTER, error)]
    rows = []
    problems = []
    inside = False
    for number, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not inside:
            if not stripped.startswith("PRODUCTS=("):
                continue
            inside = True
            stripped = stripped[len("PRODUCTS=("):].strip()
            if stripped.endswith(")"):
                stripped = stripped[:-1].strip()
        if stripped.startswith(")"):
            break
        if not stripped:
            continue
        match = re.fullmatch(r'"([^"]*)",?', stripped)
        if match is None:
            problems.append("the PRODUCTS roster in %s line %d is not a quoted row: %s" % (ROSTER, number, stripped))
            continue
        rows.append(match.group(1))
    if not inside:
        return [], ["no PRODUCTS roster in %s" % ROSTER]
    return rows, problems


def build_row(raw, number):
    """One roster row, validated the way the generator validates its own."""
    values = raw.split("|")
    if len(values) != len(FIELDS):
        return None, ["the PRODUCTS roster in %s line %d has %d fields, not %d" % (ROSTER, number, len(values), len(FIELDS))]
    row = dict(zip(FIELDS, values))
    problems = []
    for name in ("licence", "desc", "version_check"):
        value = row[name]
        if not value or any(bad in value for bad in ('"', "\\", "#{", "#$", "#@")):
            problems.append("the PRODUCTS row for %s has a %s that is empty or would end or escape a Ruby string" % (row["formula"], name))
    row["slots"] = {}
    for name, arm, intel in (("on_macos", row["mac_arm"], row["mac_intel"]), ("on_linux", row["linux_arm"], row["linux_intel"])):
        for arch, asset in (("on_arm", arm), ("on_intel", intel)):
            if asset != "-":
                row["slots"][(name, arch)] = asset
    if not row["slots"]:
        problems.append("the PRODUCTS row for %s publishes no asset for any platform" % row["formula"])
        # The renderer refuses such a row, so no formula can be rendered from
        # it. The row is unusable rather than merely wrong: checking a formula
        # against it would compare it with nothing.
        return None, problems
    row["assets"] = sorted(set(row["slots"].values()))
    row["arches"] = {name: [arch for arch in ("on_arm", "on_intel") if (name, arch) in row["slots"]]
                     for name in ("on_macos", "on_linux")}
    return row, problems


def parse(text, row):
    """Compare the formula with what the generator writes for this row."""
    reader = Reader(text)
    reader.want("class %s < Formula" % row["cls"], "class")
    reader.want('desc "%s"' % row["desc"], "desc")
    reader.want('homepage "https://github.com/%s"' % row["repo"], "homepage")
    reader.want('license "%s"' % row["licence"], "license")
    for name in ("on_macos", "on_linux"):
        if not row["arches"][name]:
            continue
        reader.want("%s do" % name, "body")
        for arch in row["arches"][name]:
            reader.want("%s do" % arch, "body")
            reader.want_shape(r'url "(.*)"', "url", "a release asset url")
            reader.want_shape(r'sha256 "(.*)"', "sha256", "a digest")
            reader.want("end", "body")
        reader.want("end", "body")
    reader.want("def install", "body")
    for statement in install_body(row):
        reader.want(statement, "install body")
    reader.want("end", "body")
    reader.want("test do", "body")
    reader.want('system "#{bin}/%s", "%s"' % (row["formula"], row["version_check"]), "test body", False)
    reader.want("end", "body")
    reader.want("end", "body")
    reader.want_end()
    return reader.problems


def check_formula(path, row):
    """Every way this formula can disagree with the roster row."""
    problems = []
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        return ["cannot read the formula: %s" % error]
    if "\r" in text:
        return ["the formula uses CRLF line endings"]
    lines = text.split("\n")
    header = ["# typed: false", "# frozen_string_literal: true", "", "# Generated by scripts/release/render-formulae.sh from the signed release of %s." % row["repo"],
              "# Do not edit by hand: edit the generator and re-run the update workflow."]
    for index, value in enumerate(header):
        actual = lines[index] if index < len(lines) else "(the file ends)"
        if actual != value:
            add(problems, index + 1, "header", "expected `%s`, found `%s`" % (value, actual))
    problems.extend(parse(text, row))
    # The urls and the digests are read again, here, over the whole file and
    # with the block each one sits in: the shape of a formula says which
    # platform a url belongs to, and the asset that platform must have is
    # what the roster row declares for it.
    context = []
    tags = []
    for number, line in enumerate(text.split("\n"), 1):
        stripped = line.strip()
        if stripped.endswith(" do"):
            context.append(stripped[:-3])
            continue
        if stripped == "end":
            if context:
                context.pop()
            continue
        match = re.fullmatch(r'(url|sha256) "(.*)"', stripped)
        if match is None:
            continue
        kind, value = match.group(1), match.group(2)
        if kind == "sha256":
            if not DIGEST_RE.match(value):
                add(problems, number, "sha256", "`%s` is not 64 lowercase hexadecimal characters" % value)
            continue
        url = URL_RE.match(value)
        if url is None:
            add(problems, number, "url", "`%s` is not a release asset url of the form https://github.com/<repo>/releases/download/<tag>/<asset>" % value)
            continue
        repo, tag, asset = url.groups()
        if repo != row["repo"]:
            add(problems, number, "url", "the url names the repository %s; the roster row for %s declares %s" % (repo, row["formula"], row["repo"]))
        if asset not in row["assets"]:
            add(problems, number, "url", "the url names the asset %s; the roster row declares %s" % (asset, ", ".join(row["assets"])))
        slot = tuple(context[-2:])
        if slot in row["slots"] and asset != row["slots"][slot]:
            add(problems, number, "url", "the %s/%s block names the asset %s; the roster row declares %s for that slot" % (slot[0], slot[1], asset, row["slots"][slot]))
        if not tag.startswith("v") or not VERSION_RE.match(tag[1:]):
            add(problems, number, "url", "the tag %s is not the plain version the generator emits" % tag)
        if tags and tag != tags[0]:
            add(problems, number, "url", "the tag %s differs from the tag %s the other urls of this formula use" % (tag, tags[0]))
        tags.append(tag)
    return problems


roster_path, repo_root = sys.argv[1], sys.argv[2]
rows, problems = read_roster(roster_path)
records = [(ROSTER, problem) for problem in problems]
if not problems and not rows:
    records.append((ROSTER, "the PRODUCTS roster in %s is empty; refusing to pass vacuously" % ROSTER))
by_name = {}
for number, raw in enumerate(rows, start=1):
    row, row_problems = build_row(raw, number)
    records.extend((ROSTER, problem) for problem in row_problems)
    if row is None:
        continue
    if row["formula"] in by_name:
        records.append((ROSTER, "the PRODUCTS roster declares %s twice" % row["formula"]))
        continue
    by_name[row["formula"]] = row
def shown(text):
    # Nothing that came from a file name or a formula may carry a newline or a
    # tab into the records below: they are line and field separators, and a
    # name such as "a.rb\nok\tb.rb" would otherwise forge a record.
    return text.encode("unicode_escape", "backslashreplace").decode("ascii")


for path in sys.argv[3:]:
    relative = os.path.relpath(path, repo_root)
    product = os.path.splitext(os.path.basename(path))[0]
    if os.path.islink(path):
        records.append((relative, "the formula is a symlink; the tap must hold its own formulae"))
        continue
    row = by_name.get(product)
    if row is None:
        records.append((relative, "the PRODUCTS roster declares no product named %s" % product))
        continue
    found = check_formula(path, row)
    if found:
        records.extend((relative, message) for message in found)
    else:
        records.append(("ok", relative))
for marker, message in records:
    print("%s\t%s" % (shown(marker), shown(message)))
# The verdict is counted here, where the records are made, and not recovered
# from the text that carries them.
print("VERDICT\t%d" % sum(1 for marker, _ in records if marker != "ok"))
