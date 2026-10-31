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
run overwrites them, so a hand edit survives until the next hourly run and
then disappears without a trace.

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
`contents: write` and nothing else. The job mints a short-lived token from the
app's private key (`UPDATER_APP_PRIVATE_KEY`, a repository secret; the id is
the variable `UPDATER_APP_ID`) on every scheduled run, so a removed
installation or a broken key turns into a red run within the hour.

The ruleset on `main` otherwise applies to everyone, humans included, with no
bypass for them: pull request required (squash only), required checks with the
branch up to date, `required_signatures`, linear history and CodeQL. The app's
bypass covers the bot's push and nothing a human can do. Commits made through
`createCommitOnBranch` are GitHub-signed, which is how they satisfy
`required_signatures` without a signing key in this repository.

**The validation that runs INSIDE `update.yml` before the commit is the only
gate between a bad render and `brew install`**, because the bot's push skips the
required checks. It is covered by `tests/publication/update-workflow.test.sh`, which
extracts the workflow's own `run:` blocks and executes them as they ship rather
than against a copy.

`dco-on-main.yml` stays as detection for anything that lands without a pull
request: an unsigned human commit would be a red run within a minute.

## Manual release rollback

The renderer rejects a release older than the version in the served formula.
For an intentional rollback, make the desired signed release `latest`, then run
`ALLOW_RELEASE_DOWNGRADE=1 ./scripts/release/render-formulae.sh` locally and review the
diff before submitting it through the normal branch flow. This bypass leaves
signature, digest and provenance verification enabled and logs a warning naming
the product, served version and candidate version. Only the exact value `1`
enables it. `update.yml` never sets it, including on `workflow_dispatch`.

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

```sh
fail=0
for t in tests/*.test.sh; do "./$t" || { echo "FAILED: $t"; fail=1; }; done
shellcheck scripts/*.sh tests/*.sh || fail=1
[ "$fail" -eq 0 ] && echo "all green" || echo "SOMETHING FAILED"
[ "$fail" -eq 0 ]
```

That last line is there because the loop cannot fail on its own. Running all of
the tests rather than halting at the first failure is the right local behaviour,
and the cost is the exit status: `$?` comes from `echo`, so a run with four
failures and a clean run look identical to anything reading it, a pre-push hook
included. The workflow chains the same scripts with `&&`, which is why CI has
never been able to miss one.

**Every script in `scripts/` needs a test.**
`scripts/quality/check-test-coverage.sh` fails when one does not, itself included --
it lives in `scripts/`, so deleting its test makes it report itself.

**Every test must be wired into a workflow.**
`tests/ci/suites/ci-runs-every-test.test.sh` fails when one is not. An unregistered test
sits in `tests/`, passes by hand, and reads as coverage while CI never runs
it. That happened in the sibling `apt` repository and went unnoticed for a day.

**A test you have not watched fail is not a test.** Before claiming a check
works, delete or invert the control it covers and confirm it goes red for the
reason it names. Four ways that goes wrong: the change you made changed nothing; it changed
something the test does not look at; the test went red, but for a reason other
than the one it names; or the same tool that made the change also confirmed it.
Confirm from something that took no part in the change, and read the failure
message, not the colour.

Assert **which** failure fired, never that some failure did. Everything runs
under `set -euo pipefail`, so almost any mistake exits non-zero.

Two things a green local run does not prove, both learned the hard way:

**Git has its own exec bit and it is the one CI reads.** With
`core.fileMode=false` set, `chmod +x` never reaches the index; the file works in
your shell and the runner answers exit 126, taking the rest of the `&&` chain
with it. `git ls-files -s tests/` shows the truth, `ls -l` does not, and
`git update-index --chmod=+x tests/<name>.test.sh` fixes it.

**The editorconfig check only sees tracked files.** That is deliberate, and a
test pins it, so a new file with no final newline is clean until you commit it
and red immediately after. Stage first, then check.

## Workflows

| file | what a red means |
|---|---|
| `tests.yml` | the suite, shellcheck, PRODUCTS/Formula drift, or `brew style` |
| `audit.yml` | Homebrew's own rules reject the rendered formulae |
| `pr-hygiene.yml` | the pull request itself is malformed |
| `freshness.yml` | something scheduled stopped happening elsewhere |
| `dco.yml`, `line-limit.yml`, `workflow-lint.yml` | one rule each |
| `update.yml` | the hourly regeneration, which commits to `main` |
| `drift.yml` | this repository's copy of a reusable workflow, or of the renderer's verification logic, no longer agrees with its sibling channels |
| `dco-on-main.yml` | a human commit reached `main` without a `Signed-off-by` trailer; detection after the push, not prevention |

Every reusable lives in `.github/workflows/reusable-*.yml` as a copy taken from
a named `Glyndor/.github` tag. Nothing is pulled remotely.

**Job ids are load-bearing.** A required status check is named
`<caller job id> / <inner job name>`, so renaming a job renames its check.
Move jobs between files freely; renaming one is a ruleset change.

## Security

Never open a public issue for a vulnerability. Use the Security tab →
**Report a vulnerability**. The organisation's `SECURITY.md` applies here and
is deliberately not duplicated.
