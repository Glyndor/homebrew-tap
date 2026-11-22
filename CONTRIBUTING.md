# Contributing to Glyndor/homebrew-tap

This repository has its own guide because the organisation's shared one
describes a `topic → develop → main` flow that does not exist here. Following
it would tell you to target a branch this repository does not have, and it
states that direct pushes to `main` are blocked with no exceptions, which is
false here, and deliberately so. See below.

Contributions are invitation-only. Bug reports and ideas through issues are
welcome; unsolicited pull requests are not accepted.

## What this repository is

It is the Homebrew tap for Glyndor's products. It carries no product source:
`Formula/*.rb` is generated from each product's latest signed release, with the
release signature verified before anything is written. Edit
`scripts/release/render-formulae.sh`, never the formulae themselves: the next scheduled
run overwrites them, so a hand edit disappears without a trace.

The renderer verifies the Ed25519 release signature, and the ML-DSA-65
signature a release may carry beside it. The second one is a hybrid and never
a replacement, so the Ed25519 signature is checked first and always. No product
carries that second signature yet, so every release today is admitted on the
Ed25519 signature alone.

**Its git content IS the published artifact.** A commit on `main` is what
`brew install` reads. There is no build step between them and no CDN in front.

## The bot commits straight to main, and that is not an oversight

`update.yml` regenerates `Formula/` from each product's latest signed release and
commits the result to `main` directly, through the GraphQL
`createCommitOnBranch` mutation.

It cannot open a pull request instead: the organisation forbids GitHub Actions
from creating or approving them, and that setting is locked org-wide. A commit
that no pull request produced has no checks run on it, so the push needs a
bypass actor on the ruleset. `github-actions[bot]` cannot be one; a GitHub App
can. `glyndor-updater` is that app, installed on this repository with
`contents: write` and nothing else. The workflow's `commit` job mints a
short-lived token from the app's private key (`UPDATER_APP_PRIVATE_KEY`, a repository secret; the id is
the variable `UPDATER_APP_ID`) on every scheduled run, so a removed
installation or a broken key turns into a red run on the next schedule, not at
the next release.

The ruleset on `main` otherwise applies to everyone, humans included, with no
bypass for them: pull request required (squash only), required checks with the
branch up to date, `required_signatures`, linear history and CodeQL. The app's
bypass covers the bot's push and nothing a human can do. Commits made through
`createCommitOnBranch` are GitHub-signed, which is how they satisfy
`required_signatures` without a signing key in this repository.

**The validation that runs INSIDE `update.yml` before the commit is the only
gate between a bad render and `brew install`**, because the bot's push skips the
required checks. It is covered by `tests/publication/update/update-workflow.test.sh`, which
extracts the workflow's own `run:` blocks and executes them as they ship rather
than against a copy.

The workflow runs in three jobs, and only `commit` ever holds the app's key.
`render` renders the formulae and records their SHA-256 in its job outputs;
`validate` runs `brew style` and `brew audit --strict`, which can install Ruby
gems, so it holds no secret; `commit` runs no `brew`, commits only files that
match the recorded digests, and needs both. Keep any new `brew` command, or any
install, out of the `commit` job: `tests/publication/update/update-key-isolation.test.sh`
and the `workflow-lint` check refuse it.

`dco-on-main.yml` stays as detection for anything that lands without a pull
request: an unsigned human commit would be a red run within a minute.

## Manual release rollback

The renderer rejects a release older than the version in the served formula.
For an intentional rollback, take two pull requests. First merge one that adds a
line `Formula/<name>.rb <committed version> <version to go back to>` to
`scripts/artifacts/approved-rollbacks.txt`: the permission is read from the base
branch, so it cannot arrive together with the rollback. Then make the desired
signed release `latest`, run
`ALLOW_RELEASE_DOWNGRADE=1 ./scripts/release/render-formulae.sh` locally and review the
diff before submitting it through the normal branch flow. The version gate lets
exactly that formula go between exactly those two versions and refuses anything
else; a malformed line makes it fail closed. The renderer bypass leaves
signature, digest and provenance verification enabled and logs a warning naming
the product, served version and candidate version. Only the exact value `1`
enables it. `update.yml` never sets it, including on `workflow_dispatch`. The
rollback pull request must also delete the approval line: an approval is single-use,
and the gate refuses a tree that is already at the version a line allowed. A pull
request that rolls something back may only delete approval lines; adding or changing
one in the same change is refused, so the next permission always lands on its own. A
malformed approvals file on the base branch grants nothing, which lets the pull
request that repairs it pass.

The renderer reads the release it renders, so the rollback run needs more than the
suites do: `gh`, authenticated and able to read releases and to verify
attestations, `curl`, and `python3-cryptography`. None of them is in the list of
packages above, and no suite stands in for them.

## Branch flow

```
topic branch ──PR──▶ main
```

There is no `develop`. Branch from `main`, open a pull request against
`main`, squash-merge back.

`Closes #N` auto-closes, because the fix lands on the default branch.

## Before you open a pull request

- **An issue first.** Labels are the tracking system; there is no board. Apply
  `type:`, `prio:`, `effort:`, `status:` and `area:` where they fit.
- **Sign every commit off.** `git commit -s`. The `dco` check is required on
  pull requests.
- **Commits are signed**, GPG or SSH. `required_signatures` is enforced on
  `main`, and rebase-merge is disabled because GitHub re-creates rebased
  commits without signatures.
- **Conventional Commit title** on the pull request.

## Tests

The suites need `shellcheck`, `python3-yaml` and `ruby` installed, the packages `tests.yml` lists for CI. The ML-DSA-65 setup below also needs `python3-venv`, which Debian and Ubuntu package apart from `python3`. There shellcheck is the pinned release the shellcheck job uses, and a pull request installs only what the suites it selects need (`scripts/quality/scope/suite-dependencies.txt`).

```sh
fail=0
suite=$(find tests -name '*.test.sh' -type f | sort)
# The completeness check takes the other test files as arguments and runs them
# itself, so this command runs each suite exactly once. On its own it only
# prints its usage.
# shellcheck disable=SC2086
# A runner that is not executable must fail the command, not skip the suites.
if [ -x tests/ci/suites/check-suite-completeness.test.sh ]; then
  tests/ci/suites/check-suite-completeness.test.sh $(grep -v check-suite-completeness <<< "$suite") || fail=1
else
  echo "FAILED: tests/ci/suites/check-suite-completeness.test.sh is not executable"; fail=1
fi
find . -type f \( -name '*.sh' -o -name '*.bash' \) -not -path './.git/*' -print0 | xargs -0 shellcheck || fail=1
[ "$fail" -eq 0 ] && echo "all green" || echo "SOMETHING FAILED"
[ "$fail" -eq 0 ]
```

Keep the last line. The runner carries on past a failure -- it runs every suite and
counts the failures -- but its exit status says only that something failed. The
`FAIL` lines it prints are what say which, and they scroll. The final test turns
them back into an exit status a script can read, a pre-push hook included.

The command runs every suite under `tests/`, which is the `shell` job of
`tests.yml` plus the ML-DSA-65 suite below, and its `find` reaches the same
`.sh` and `.bash` files as the `shellcheck` job of CI. Three things stay with CI.
That job also lints extensionless files whose first line is a shell shebang; it
installs one `shellcheck` release pinned by version and checksum, where your
local one is whatever you have installed; and it lints the shell inside the
workflows, which `find` cannot see. Run
`bash ./scripts/quality/lint/lint-workflow-shell.sh` for that last part.

`tests/release/release-signature/release-signature-mldsa.test.sh` also needs
`cryptography` 50.0.2 or later, for ML-DSA-65, which no Ubuntu release packages
yet. Without it that suite fails and says so, and the command above goes red.
Install the pinned wheel into a virtual environment that still sees the system
packages, and put it first on `PATH` before running the command:

```bash
python3 -m venv --system-site-packages ~/.cache/tap-mldsa
~/.cache/tap-mldsa/bin/python -m pip install --require-hashes --only-binary=:all: \
  -r scripts/release/render-requirements.txt
export PATH="$HOME/.cache/tap-mldsa/bin:$PATH"
```

CI runs that suite in its own job, `ML-DSA-65 verifier` in `tests.yml`. The job
always starts and reports under that name, and decides in its first step whether
anything the suite reads changed: when nothing did, the wheel install and the
suite are skipped and the job says so in its summary. It asks the same question
on a pull request and on a push to main, and any doubt runs the suite.

**Every script in `scripts/` needs a test.**
`scripts/quality/coverage/check-test-coverage.sh` fails when one does not, itself included --
it lives in `scripts/`, so deleting its test makes it report itself.

**Where a script of `scripts/quality/` goes.** The folder is split by what the
script decides, and `tests/quality/` mirrors it with the test at the same depth
as its script, which the coverage check above enforces:

| Folder | What its scripts decide |
|---|---|
| `hygiene/` | that the tree agrees with the rules the repository states: `.editorconfig` and the references in `docs/` |
| `lint/` | static rules over workflows and shell: action pins, the shell inside `run:` blocks, a test job that cannot be switched off, tooling next to a secret |
| `scope/` | which jobs and suites a change can affect, with the maps they read |
| `coverage/` | that every script has a test and every suite is run by a workflow, with the list of suites that cannot be |

**Every test must be wired into a workflow.**
`tests/ci/suites/ci-runs-every-test.test.sh` fails when one is not. An unregistered test
sits in `tests/`, passes by hand, and reads as coverage while CI never runs
it. That happened in the sibling `apt` repository and went unnoticed for a day.
So does the `workflow-lint` check, which runs `scripts/quality/coverage/check-suites-wired.sh`
outside the test job: a pull request that drops the watcher from the list along
with other suites leaves the test job green, and turns that check red.
A suite that cannot run on a pull request goes in `scripts/quality/coverage/suite-exemptions.txt`
with its reason. That list is read from the base commit too, so an entry takes
effect from the pull request after the one that adds it.

**A new suite needs an entry in `scripts/quality/scope/suite-scope.txt`.**
On a pull request the runner skips the suites whose paths the change does not
touch, so a suite with no entry would run every time and
`tests/quality/scope/ci-job-scope-suites.test.sh` fails until it has one. List every
path the suite reads: a missing path lets a change merge without the suite that
should have judged it, while an extra one only costs a run. A change to the map,
to `scripts/quality/scope/ci-job-scope.sh` or to the runner runs everything, and both
files are shared byte for byte with the sibling channel repository, so they
change in both together. A suite that only a job of its own runs, such as the
ML-DSA-65 one, has its entry here too: that job asks
`ci-job-scope.sh suite-needed` before it installs anything.

**A test you have not watched fail is not a test.** Before claiming a check
works, delete or invert the control it covers and confirm it goes red for the
reason it names. Four ways that goes wrong: the change you made changed nothing; it changed
something the test does not look at; the test went red, but for a reason other
than the one it names; or the same tool that made the change also confirmed it.
Confirm from something that took no part in the change, and read the failure
message, not the colour.

Assert **which** failure fired, never that some failure did. The scripts run
under `set -euo pipefail` and stop at the first error. Many suites do not: they
start with `set -u` or `set -uo pipefail`, count their own failures and carry on,
so a mistake in one of them is a `FAIL` line, not an exit. Read those lines, not
only the exit status.

Two things a green local run does not prove, both learned the hard way:

**Git has its own exec bit and it is the one CI reads.** With
`core.fileMode=false` set, `chmod +x` never reaches the index; the file works in
your shell and the runner answers exit 126, taking the rest of the `&&` chain
with it. `git ls-files -s tests/` shows the truth, `ls -l` does not, and
`git update-index --chmod=+x tests/<name>.test.sh` fixes it.

**The editorconfig check only sees tracked files.** That is deliberate, and a
test pins it, so a new file with no final newline is clean until you commit it
and red immediately after. Stage first, then check.

**A new guard brings its catalogue entry.** A change that adds a refusal under
`scripts/` adds the line of `tests/mutation/catalog.txt` that breaks it and names the
suite that notices; `tests/mutation/run-mutations.sh <id>` runs that one entry.
`tests/mutation/catalog-reaches-every-script.test.sh` fails a script that no entry
mutates at all. A guard added to a file that already has entries is for the review to
catch, because a count per file cannot tell one guard from another.

## Workflows

| file | what a red means |
|---|---|
| `tests.yml` | four jobs. `shell`: a suite or shellcheck. `ML-DSA-65 verifier`: the second signature verified with real ML-DSA-65 keys, in a virtual environment built from `scripts/release/render-requirements.txt`, so a red there can be that pinned wheel failing to install as well as the verifier. `products match the generator`: `Formula/` no longer matches `PRODUCTS`, a formula is not what the generator emits, or one goes back to an older release. `brew style`: Homebrew's style rules reject a formula |
| `audit.yml` | Homebrew's own rules reject the rendered formulae |
| `pr-hygiene.yml` | the pull request itself is malformed |
| `freshness.yml` | something scheduled stopped happening elsewhere, or a tool pinned in a reusable fell behind its upstream release |
| `dco.yml` | a commit of the pull request has no `Signed-off-by` trailer |
| `line-limit.yml` | a source file, or a `.txt` list or map, is over the hard limit of 500 lines of code; passing the soft limit of 300 only warns |
| `workflow-lint.yml` | `actionlint` found a mistake in a workflow, a suite under `tests/` is run by no workflow, a caller can switch the required test job off, or a job that holds a secret installs third-party tooling |
| `update.yml` | the scheduled regeneration, which commits to `main` |
| `drift.yml` | a copy this repository shares with a sibling channel no longer agrees: a reusable workflow, the renderer's verification logic, or one of the scripts and tests the tap and the bucket carry as exact copies |
| `dco-on-main.yml` | a human commit reached `main` without a `Signed-off-by` trailer; detection after the push, not prevention |
| `mutation.yml` | a guard of the scripts stopped dying when it was broken on purpose: the suite that watches it no longer notices |

Every reusable lives in `.github/workflows/reusable-*.yml` as a copy kept identical in logic to the
copies in the sibling channels (`scripts/monitoring/check-reusable-drift.sh` compares
them). The scripts and tests listed in `scripts/monitoring/channel-shared-paths.txt` are
copies kept identical to the bucket's (`scripts/monitoring/check-channel-drift.sh` compares them).
Nothing from the siblings is executed: the three drift watchers fetch their copies over https
from `raw.githubusercontent.com` to compare them, never to run them.

**Job ids are load-bearing.** A required status check is named
`<caller job id> / <inner job name>`, so renaming a job renames its check.
Move jobs between files freely; renaming one is a ruleset change.

## Security

Never open a public issue for a vulnerability. Use the Security tab →
**Report a vulnerability**. The organisation's `SECURITY.md` applies here and
is deliberately not duplicated.
