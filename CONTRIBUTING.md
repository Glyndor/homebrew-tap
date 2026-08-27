# Contributing to Glyndor/homebrew-tap

This repository has its own guide because the organisation's shared one
describes a `topic → develop → main` flow that does not exist here. Following
it would tell you to target a branch this repository does not have, and it
states that direct pushes to `main` are blocked with no exceptions -- which is
false here, and deliberately so. See below.

Contributions are invitation-only. Bug reports and ideas through issues are
welcome; unsolicited pull requests are not accepted.

## What this repository is

It is the Homebrew tap for Glyndor's products. It carries no product source:
`Formula/*.rb` is generated from each product's latest signed release, with the
release signature verified before anything is written. Edit
`scripts/render-formulae.sh`, never the formulae themselves: the next scheduled
run overwrites them, so a hand edit survives until the following morning and
then disappears without a trace.

**Its git content IS the published artifact.** A commit on `main` is what
`brew install` reads. There is no build step between them and no CDN in front.

## The bot commits straight to main, and that is not an oversight

`update.yml` regenerates `Formula/` from each product's latest signed release and
commits the result to `main` directly, through the GraphQL
`createCommitOnBranch` mutation.

It cannot open a pull request instead: the organisation forbids GitHub Actions
from creating or approving them, and that setting is locked org-wide. And a
required status check would reject the push, because checks have not run on a
commit that no pull request produced.

So this repository's ruleset omits require-pull-request and required checks. The
compensating controls are `required_signatures` -- every commit on `main` is
verified, and `createCommitOnBranch` commits are GitHub-signed -- plus the
validation that runs INSIDE `update.yml` before the commit lands.

**That validation is the only gate between a bad render and `brew install`.** It is
covered by `tests/update-workflow.test.sh`, which extracts the workflow's own
`run:` blocks and executes them as they ship rather than against a copy.

One consequence is open and tracked: dropping required checks also dropped the
DCO gate for human pull requests. See the repository's issues.

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
- **Sign every commit off** -- `git commit -s`. The `dco` check runs on pull
  requests but is **not** required by the ruleset here, for the reason above, so
  it relies on you.
- **Commits are signed**, GPG or SSH. `required_signatures` is enforced on
  `main`, and rebase-merge is disabled because GitHub re-creates rebased
  commits without signatures.
- **Conventional Commit title** on the pull request.

## Tests

```sh
for t in tests/*.test.sh; do "./$t" || echo "FAILED: $t"; done
shellcheck scripts/*.sh tests/*.sh
```

**Every script in `scripts/` needs a test.**
`scripts/check-test-coverage.sh` fails when one does not, itself included --
it lives in `scripts/`, so deleting its test makes it report itself.

**Every test must be wired into a workflow.**
`tests/ci-runs-every-test.test.sh` fails when one is not. An unregistered test
sits in `tests/`, passes by hand, and reads as coverage while CI never runs
it. That happened in the sibling `apt` repository and went unnoticed for a day.

**A test you have not watched fail is not a test.** Before claiming a check
works, delete or invert the control it covers and confirm it goes red for the
reason it names. Four ways that goes wrong are written up in
`standards/testing`.

Assert **which** failure fired, never that some failure did. Everything runs
under `set -euo pipefail`, so almost any mistake exits non-zero.

## Workflows

| file | what a red means |
|---|---|
| `tests.yml` | the suite, shellcheck, PRODUCTS/README/Formula drift, or `brew style` |
| `audit.yml` | Homebrew's own rules reject the rendered formulae |
| `pr-hygiene.yml` | the pull request itself is malformed |
| `freshness.yml` | something scheduled stopped happening elsewhere |
| `dco.yml`, `line-limit.yml`, `workflow-lint.yml` | one rule each |
| `update.yml` | the daily regeneration, which commits to `main` |

Every reusable lives in `.github/workflows/reusable-*.yml` as a copy taken from
a named `Glyndor/.github` tag. Nothing is pulled remotely.

**Job ids are load-bearing.** A required status check is named
`<caller job id> / <inner job name>`, so renaming a job renames its check.
Move jobs between files freely; renaming one is a ruleset change.

## Security

Never open a public issue for a vulnerability. Use the Security tab →
**Report a vulnerability**. The organisation's `SECURITY.md` applies here and
is deliberately not duplicated.
