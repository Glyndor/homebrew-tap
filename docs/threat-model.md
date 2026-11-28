# Threat model

What this tap protects, against whom, with which control, and how each control
is known to work. The README says what to install and what the checksum in a
formula rests on; this page is the assessor's view: one row per threat, the
control that answers it, and the evidence that the control is real. Residual
risks come last, on purpose.

A reference on this page names the thing it points at -- a function, a
constant, a job, a heading -- and never a line number. The references were
recorded as `path:line` on 2026-09-02 and were true that day; the renderer
grew, moved directory, and the numbers went on pointing at unrelated code
while this page still read as if it were current. Nothing noticed, because a
line number in a Markdown document is not a link and nothing resolves it.
`scripts/quality/hygiene/check-doc-anchors.sh` resolves every reference below and
fails when one does not, so a moved function is caught by the build instead of
by the next reader.

Evidence is of three kinds: a **test** is a case under `tests/` that fails when the
control is removed from the file it covers; a **workflow** is a job that runs
on every push, pull request or schedule, and here that is weaker than it sounds,
because the updater app bypasses the required checks on `main`; human pull
requests must pass them (`CONTRIBUTING.md#Branch flow`); a
**measurement** is a number or an outcome read off
a file or a run, with the date.

## What the tap is, and is not

There is no server. `brew install glyndor/tap/podup` clones this repository from
GitHub and reads `Formula/podup.rb` out of the clone (`README.md#Install`,
`README.md#What you are trusting`). The git content of `main` is the published
artifact, which is why the update lands as a commit rather than as a file on a
bucket (`.github/workflows/update.yml#commit`). The
binaries stay on each product's GitHub release; the formula pins their URL and
SHA-256 (`Formula/podup.rb#Podup`). Nothing is
pushed here by a product. The update workflow also accepts a `repository_dispatch`
event of type `release`, which starts the same run ahead of the hourly one;
sending it takes a token with write access to this repository, and the run reads
no part of the event, so it moves an update forward in time and cannot change what
is published (`.github/workflows/update.yml#update`,
`tests/publication/update/update-workflow.test.sh#the update workflow reads nothing from a repository_dispatch payload`).

## Assets

| Asset | Where | Why it matters |
|---|---|---|
| The formulae | `Formula/*.rb` on `main` | what `brew` executes as the installing user |
| The rendered checksums | `sha256` lines inside each formula (`Formula/podup.rb#Podup`) | the only thing that binds a download to the release the tap verified |
| The organization's release key (public half) | `scripts/release/render-formulae.sh#RELEASE_PUBKEY_B64`, with a second slot at `scripts/release/render-formulae.sh#RELEASE_PUBKEY2_B64` | the trust anchor that admits a release into the tap |
| The organization's ML-DSA-65 release key (public half) | `scripts/release/render-formulae.sh#RELEASE_PQ_PUBKEY_B64`, with a second slot at `scripts/release/render-formulae.sh#RELEASE_PQ_PUBKEY2_B64` and the list of products whose second signature is required at `scripts/release/render-formulae.sh#RELEASE_PQ_REQUIRED` | the second half of the hybrid release signature; empty today, and no product carries that signature yet |
| `main` itself | this repository | every `brew update` reads it, and the bot writes to it without a pull request |

## Trust boundaries and actors

- **A product's GitHub release.** Untrusted until its `SHA256SUMS.sig` verifies
  against a configured key (`scripts/release/release-signature.sh#verify_sha256sums`). Its assets
  are attacker-influenced by definition: whoever can publish a release controls
  them (`scripts/release/render-formulae.sh#hash_of`).
- **GitHub.** Hosts the repository, serves the release assets, runs the
  workflows, and signs the bot's commits through `createCommitOnBranch`
  (`.github/workflows/update.yml#Commit the update to main (GitHub-signed)`). One trust domain; see Out of scope.
- **The update bot.** `update.yml` runs on an hourly schedule that GitHub
  often runs late, in four jobs that each hold a
  read-only `GITHUB_TOKEN` (`contents: read`). `render` renders the formulae
  and records their SHA-256 in its job outputs (`.github/workflows/update.yml#render`),
  `validate` runs `brew style` and `brew audit --strict` on them on Linux
  (`.github/workflows/update.yml#validate`), `validate-macos` runs the audit on
  the macOS spec (`.github/workflows/update.yml#validate-macos`), and `commit`
  commits them (`.github/workflows/update.yml#commit`). The write goes through a token
  minted for the `glyndor-updater` GitHub App (`contents: write` on this
  repository only) by `actions/create-github-app-token`, from a long-lived
  private key held as the repository secret `UPDATER_APP_PRIVATE_KEY`, and only
  the `commit` job references it. The app is a bypass actor on the `main`
  ruleset and commits through `createCommitOnBranch`. A leaked key would let its
  holder push to `main` past the required checks, which is why the key is the
  credential that matters here.
- **A human with Write.** Opens pull requests. The ruleset requires a pull
  request, the status checks listed in
  `tests/ci/policy/workflows/repo/required-checks-are-emitted.test.sh` (the audit's is `audit gate`) with the
  branch up to date, signed commits and CodeQL, and gives humans no bypass.
- **A user running `brew install`, on macOS or Linux.** Trusts this repository's `main`,
  Homebrew, and their own machine. The tap cannot reach past the second.

## Threats and controls

### Admission: what a formula is allowed to say

| Threat | Control | Evidence |
|---|---|---|
| A tampered or substituted release asset (a binary swapped after publication, or a `SHA256SUMS` rewritten to match it) | the checksum never comes from the asset; it is read from a `SHA256SUMS` whose detached Ed25519 signature verified first, and `brew` refuses a download whose bytes do not match the pinned digest (`scripts/release/release-signature.sh#verify_sha256sums`, `scripts/release/render-formulae.sh#verify_attestation`) | test: `tests/release/render-formulae.test.sh#an unverifiable signature skips the product`; `tests/release/render-formulae.test.sh#an asset missing from the manifest skips the product`; `tests/release/render-formulae/render-formulae-trust.test.sh#an asset listed twice is rejected`; `tests/release/render-formulae/render-formulae-trust.test.sh#a non-hexadecimal checksum is rejected`; `tests/release/render-formulae/render-formulae-trust.test.sh#a short digest is rejected` (a manifest that verifies but is malformed) |
| A release signed by a wrong or rotated key | verification fails closed against every configured slot; exhausting the slots is an error, not a fallthrough, and the product keeps the formula it had (`scripts/release/release-signature.sh#verify_sha256sums`, `scripts/release/render-formulae.sh#render_product`) | test: `tests/release/render-formulae/render-formulae-trust.test.sh#two wrong keys still fail closed`; `tests/release/render-formulae/render-formulae-trust.test.sh#a well-formed key that did not sign it fails as a signature`; `tests/release/render-formulae.test.sh#the skipped product keeps the formula it had` |
| A release carries a second signature, an ML-DSA-65 one, and it is not checked, or it is left out where it is required | the Ed25519 signature is checked first and always, and a second signature is checked whenever the release carries it. One that does not verify, is not 3309 bytes, is read past the 4096-byte cap or arrives while no ML-DSA-65 key is configured is refused; a download of it that fails, or answers anything but 200 or 404, is refused rather than read as absent; a library without ML-DSA-65 refuses instead of skipping; a product named in `RELEASE_PQ_REQUIRED` is refused without one; and a malformed key, or a list that names no product of the roster, stops the run before any release is read (`scripts/release/release-signature.sh#verify_sha256sums`, `scripts/release/release-signature.sh#check_release_configuration`, `scripts/release/render-formulae.sh#RELEASE_PQ_REQUIRED`) | test: `tests/release/release-signature.test.sh#a required product without its second signature is refused`; `tests/release/release-signature.test.sh#a second signature with no key configured is refused, not skipped`; `tests/release/release-signature.test.sh#a 200 whose transfer broke is refused, even when the bytes look whole`; `tests/release/release-signature.test.sh#and the stop is a configuration error, not a tampered release` for the cases that need no ML-DSA library; `tests/release/release-signature/release-signature-mldsa.test.sh#a valid second signature of another release is refused` and `tests/release/release-signature/release-signature-mldsa.test.sh#the OpenSSL-made ML-DSA-65 vector verifies` for real signatures, in the `mldsa` job of `tests.yml`; `tests/publication/update/update-mldsa-venv.test.sh#a key in the second slot alone installs it too` for the wheel. No product signs with it yet and `RELEASE_PQ_REQUIRED` is empty, so this row protects nothing today: whoever can forge the Ed25519 signature leaves the second one out. It starts to protect a product with the commit that names that product in `RELEASE_PQ_REQUIRED`, in this renderer and in Glyndor/scoop-bucket's `scripts/release/render-manifests.sh`, after a release of it has been verified with both signatures. A product named there before an ML-DSA-65 public key is in one of the two slots stops the run (`tests/release/release-signature.test.sh#a required product with no ML-DSA-65 key configured stops the run`), and a key with an empty list is the valid state between the two steps (`tests/release/release-signature.test.sh#and a key with an empty list, the state between the two steps, starts and admits`) |
| The trust anchor is swapped from outside the script | the key is a constant overridden only by `--pubkey` and `--pubkey2`; no environment variable reaches it (`scripts/release/render-formulae.sh#RELEASE_PUBKEY_B64`) | test: `tests/release/render-formulae/render-formulae-trust.test.sh#the environment cannot swap the trust anchor` |
| A compromised product repository publishes a malicious release under a valid signature | the tap verifies that the manifest is the one the product published and that what it interpolates is well formed: a tag carrying Ruby is refused before it reaches the generated formula (`scripts/release/render-formulae.sh#version_guard`), and a digest must be one entry of 64 hex characters (`scripts/release/render-formulae.sh#hash_of`). It cannot tell a malicious binary from a good one when both are correctly signed, and the release job of the product holds the signing key whose public half is `scripts/release/render-formulae.sh#RELEASE_PUBKEY_B64`, so this is a residual risk, stated below | test: `tests/release/render-formulae/render-formulae-version.test.sh#a release tag carrying Ruby is refused`; `tests/release/render-formulae/render-formulae-version.test.sh#and the error names the tag rather than the signature`; none for the binary itself |
| One product's broken release removes or holds back another's | each product renders on its own; a failure leaves that product's formula as it was, the rest still commit, and the job fails last so the skip is loud (`scripts/release/render-formulae.sh#render_product`, `.github/workflows/update.yml#Render formulae from the latest signed releases`, `.github/workflows/update.yml#Fail if any product was skipped`) | test: `tests/publication/update/update-workflow.test.sh#exit 3 does NOT abort the step`; `tests/publication/update/update-workflow.test.sh#the failure step is last, after the commit` |
| A render that empties the tap is committed | two guards, in the order they run. The render step refuses a render whose only changes are deletions and that would remove the last formula, with an error that names the cause (`.github/workflows/update.yml#Render formulae from the latest signed releases`). The validate step then refuses any empty `Formula/`, however it came to be empty, before `brew` is set up, so that guard does not depend on the toolchain (`.github/workflows/update.yml#Validate the re-rendered formulae`) | test: `tests/publication/update/update-workflow.test.sh#a deletion that would empty the channel refuses the render step` for the first; `tests/publication/update/update-workflow.test.sh#an emptied Formula/ fails validation` for the second |
| A formula in `Formula/` is a symlink, so the render writes through it and the tap stops advancing without a red check | the renderer refuses a symlinked formula, skips that product and exits 3 instead of writing through the link (`scripts/release/render-formulae.sh#render_product`); the validator already refuses a symlink in `Formula/` (`scripts/artifacts/check-formulae.py`) | test: `tests/release/render-formulae/render-formulae-symlink.test.sh#a symlinked formula skips the product (exit 3)` |
| A formula names a url of another Glyndor repository, a second tag inside the same formula, an asset the roster does not declare, or a statement the generator does not write | the content of every formula is compared with what the generator emits for the product its roster row declares: the repository, the tag on every url, the assets, the shape of the digests, and the statements themselves (`scripts/artifacts/check-formulae.sh#check-formulae`). It runs in the render job (`.github/workflows/update.yml#Hold the rendered formulae to the roster`), again in the commit job on the bytes it commits (`.github/workflows/update.yml#Check the rendered bytes against the render job's digests`), and on every push and pull request (`.github/workflows/tests.yml#products`); a roster with no rows, or a formula no row declares, is an error rather than a vacuous pass | `tests/artifacts/check-formulae.test.sh` plants each violation, a comment that tries to move the block stack, CRLF and a forged file name, and reruns them against a copy of the check with its verdict removed |

`brew style` and `brew audit --strict` read a formula as Ruby and as a Homebrew
recipe. Neither of them knows what the product's release looked like, so both
accept a formula that is well formed and wrong. The content check closes that
gap for the things a release decides -- the repository, the tag, the assets --
and refuses the statements the generator does not write, which is what stops a
hand edit from adding code that runs on every install. It does not bind a
digest to any bytes: a well-formed digest of the wrong binary still passes,
and the signature over `SHA256SUMS` is what says otherwise.

The manifest signature authenticates `SHA256SUMS`, not the tag returned by the
release lookup. Before writing, `scripts/release/render-formulae.sh#verify_attestation`
downloads **every** declared asset, compares its SHA-256 with the signed
manifest, and requires provenance for `refs/tags/$tag` from
`$repo/.github/workflows/release.yml`. The version character check
(`scripts/release/render-formulae.sh#version_guard`) prevents Ruby
interpolation; the provenance check binds the asset to the requested tag.
Neither proves that trusted build inputs are benign.
`scripts/release/render-formulae.sh#release_order` then refuses a candidate
below the served SemVer precedence.
`tests/release/render-formulae/render-formulae-attestation.test.sh#an authenticated downgrade stops publication with exit 1`
and `tests/release/render-formulae/render-formulae-attestation.test.sh#an explicit manual rollback is allowed`
exercise these checks, including a correctly authenticated older release and
the manual override.

### Publication: how a commit reaches `main`

| Threat | Control | Evidence |
|---|---|---|
| A malicious or careless formula committed by a human | `main` accepts only signed commits and linear history, and the bot's commits are GitHub-signed; together with the required pull request and checks, and it says who committed, not whether the change was right (`CONTRIBUTING.md#The bot commits straight to main, and that is not an oversight`, `CONTRIBUTING.md#Branch flow`). A hand edit to a formula is overwritten by the next scheduled run: the renderer rewrites every declared formula from the signed release and commits whatever differs (`scripts/release/render-formulae.sh#render_product`, `.github/workflows/update.yml#Render formulae from the latest signed releases`). An edit to the generator itself is not | the ruleset lives on GitHub, not in this tree, and this page cites what `CONTRIBUTING.md` records of it; test: none for the overwrite; `tests/publication/update/update-workflow.test.sh#the commit step invokes gh (not git push)` and `tests/publication/update/update-workflow.test.sh#and the payload uses createCommitOnBranch` hold the commit path to `createCommitOnBranch` so a refactor to `git push` cannot ship an unsigned commit |
| A human commit lands without a `Signed-off-by` trailer (the DCO gap) | `dco.yml` runs on pull requests and is a required check; `dco-on-main.yml` reports every human-authored commit that arrived without the trailer, exempting the bot by who pushed rather than by what the commit says (`.github/workflows/dco-on-main.yml#Check the pushed commits`, `scripts/governance/check-dco-on-main.sh#is_bot`, `scripts/governance/check-dco-on-main.sh#exempt_all`). The required pull-request DCO check prevents an unsigned proposed commit from merging through that path. The push watcher detects any unsigned human commit that nevertheless lands; it cannot undo publication | test: `tests/governance/check-dco-on-main.test.sh#an unsigned human commit fails`; `tests/governance/check-dco-on-main.test.sh#a human using the bot's exact subject is still reported`; `tests/governance/check-dco-on-main.test.sh#a commit whose author field impersonates the bot is still reported` |
| A pull request neutralises a check by replacing its caller with a stub of the same name | none that prevents it; `CODEOWNERS` lists `.github/workflows/` so that required review from Code Owners can be switched on (`.github/CODEOWNERS`) | none: the check is only as strong as that review |
| A caller quietly switches the test job off | `workflow-lint` asserts from outside the shell job that no caller of a local reusable (`shell / test`, `dco`, `line limit`, `workflow-lint` and `empty diff` among them) carries a job-level `if:`, `needs:` or `continue-on-error:`, bar the watchers of `freshness.yml` the script lists by their exact form, that every caller of `reusable-shell-ci` passes a `test-command` that runs a suite, and that at least one such caller exists (`.github/workflows/reusable-workflow-lint.yml#A required test job must not be switchable off`, which runs `scripts/quality/lint/check-test-job-not-switchable.sh#check-test-job-not-switchable` as the base commit the pull request event names has it, so the rule that judges a pull request is the base's. When the path a rule has now is not in the base, the base's copy of the file of the same name at any depth under `scripts/quality/` is taken instead and the log says from which path, so moving a rule and weakening it in the same pull request does not make the weakened copy the judge; two such files fail the job, and only a rule the base has never had runs from the checkout. The content of the rule is the base's; the workflow that runs it comes from the pull request, and a change to it is caught by the owner's review of `.github/workflows/`, which CODEOWNERS routes to the owner, not by this check.) | test: `tests/quality/lint/check-test-job-not-switchable.test.sh#a caller with an empty test-command is refused`; `tests/quality/lint/check-test-job-not-switchable.test.sh#a tree with no reusable-shell-ci caller is refused`; `tests/quality/lint/check-test-job-not-switchable.test.sh#the DCO check switched off with if: false is refused`; `tests/ci/reusable/reusable-workflow-lint.test.sh` (a pull request that hollows the rule is still judged by the base commit's copy); `tests/ci/reusable/reusable-workflow-lint.test.sh#the move: a rule moved and weakened in the same change still refuses the violation`; `tests/ci/reusable/reusable-workflow-lint.test.sh#two files of that name in the base fail the picker` |
| A caller passes an input that weakens the check it calls (`tooling-isolation: false`, `severity: ignore`, `check-exec-bit: false`, `exclude-pattern: ".*"`, a larger `hard-limit`, an `extensions` list without `sh`) and every suite stays green | `workflow-lint` refuses, for every caller of a local reusable, an input that the closed list of that reusable does not name, and a caller of a reusable that has no entry in the list. The `extensions` of the line limit may grow but may not lose a word the callers of the base commit pass, and are lowercase words of letters and digits with one space between them, because the reusable builds a regular expression from them and refuses any other word itself. The list is read from the base commit the pull request event names, like the rest of the rule; the workflow that runs it comes from the pull request and is covered by the owner's review of `.github/workflows/` (`.github/workflows/reusable-workflow-lint.yml#A required test job must not be switchable off`, `scripts/quality/lint/check-test-job-not-switchable.sh#check-test-job-not-switchable`) | test: `tests/quality/lint/check-test-job-not-switchable-inputs.test.sh#a caller with two refused inputs is refused`; `tests/quality/lint/check-test-job-not-switchable-inputs.test.sh#a caller of a local reusable with no entry in the list is refused`; `tests/quality/lint/check-test-job-not-switchable-inputs.test.sh#and the message names the extension taken` |
| A required job, or the step inside it that runs the suite or the comparison, is switched off with a job-level `if:` (`if: false`), `needs:` or `continue-on-error:`, or a step-level `if:`, and every suite stays green; the job can be a caller, one of the jobs inside a local reusable (`shell / test`, `dco`, `empty diff`) or a job a workflow defines itself (the alarm of the health check) | `workflow-lint` reads every job and every step of every workflow, the reusables included, and refuses a job-level `if:`, `needs:` or `continue-on-error:` and a step-level `if:` or `continue-on-error:` that two closed lists in the script do not name by workflow file, job and exact value (the conditions that exist on purpose: an event, a scope decision, the job a watcher waits for). A job added later is held to the rule without a new case, and the refusal says where a condition on purpose is declared. A condition that reads the output of a step or a job (`steps.scope.outputs.needed`) is only accepted while everything that producer can see is what the base commit has: the steps of the job up to it, whole, the `env`, `defaults`, `runs-on`, `container`, `services` and `permissions` of the job and the `env` and `defaults` of the workflow (for a producer that is a job, the whole job and the reusable it calls). A pull request therefore cannot make the scope step write `false`, nor add a step before it that writes `needed=false` to `GITHUB_ENV`, nor set an `env:` that changes what it runs, and a producer that runs a script of the repository from the checkout of a pull request is refused in the workflows a pull request can run; a producer is changed on purpose in two pull requests. `skip-suite-paths`, which decides when `shell / test` is skipped, is a list of words that name a file, never `*` or a pattern that matches every file, and may not gain a word the callers of the base commit do not pass. The lists are read from the base commit the pull request event names, like the rest of the rule; the workflow that runs it comes from the pull request and is covered by the owner's review of `.github/workflows/` (`.github/workflows/reusable-workflow-lint.yml#A required test job must not be switchable off`, `scripts/quality/lint/check-test-job-not-switchable.sh#check-test-job-not-switchable`) | test: `tests/quality/lint/check-test-job-not-switchable-pins.test.sh#and says how to change a producer on purpose`; `tests/quality/lint/check-test-job-not-switchable-inputs.test.sh#and it says the callers of the base commit do not pass it`; `tests/quality/lint/check-test-job-not-switchable-jobs.test.sh#the alarm of a scheduled workflow switched off with if: false is refused`; `tests/quality/lint/check-test-job-not-switchable-steps.test.sh#the step that runs the comparison switched off with if: false is refused`; `tests/quality/lint/check-test-job-not-switchable-jobs.test.sh#the job that runs the tests with a condition that can never hold is refused` |
| A test exists and no workflow runs it, or a script has no test | one watcher fails when a suite under `tests/` is invoked by no workflow, another when a script under `scripts/` has no suite, each including itself (`tests/ci/suites/ci-runs-every-test.test.sh#every test in tests/ is invoked by a workflow`, `scripts/quality/coverage/check-test-coverage.sh#check-test-coverage`, `.github/workflows/tests.yml#shell`) | test: `tests/ci/suites/ci-runs-every-test.test.sh#this watcher is itself invoked by a workflow`; `tests/quality/coverage/check-test-coverage.test.sh#check-test-coverage` |
| A pull request drops suites from the test job, the watcher among them, and the job stays green | the `workflow-lint` check, outside the test job, fails when a suite under `tests/` is run by no workflow on a pull request. A suite counts only from a job without `if:`, `needs:` or `continue-on-error`, from a caller whose `skip-suite-paths` matches no file under `.github/`, `scripts/` or `tests/`, or from a `run:` line that no shell operator follows, in a step without a here-doc, with errexit on and under bash; a line in a branch that is never taken still counts. The checker and the list of exempt suites (`scripts/quality/coverage/suite-exemptions.txt`) are read from the base commit the pull request event names, at their earlier path when the pull request moves them, so the pull request cannot weaken the checker or exempt what it unwires; the workflow that runs them comes from the pull request and is covered by the owner's review of `.github/workflows/` that CODEOWNERS routes to the owner (`.github/workflows/reusable-workflow-lint.yml#Every suite is run by a workflow`, `scripts/quality/coverage/check-suites-wired.sh#check-suites-wired`, `scripts/quality/coverage/suite-exemptions.txt`) | test: `tests/quality/coverage/check-suites-wired.test.sh#dropping the watcher with another suite fails`; `tests/quality/coverage/check-suites-wired.test.sh#a pull request that drops a suite and disarms the checker still fails`; `tests/quality/coverage/check-suites-wired.test.sh#a pull request that drops a suite and exempts it in the same change still fails`; `tests/quality/coverage/check-suites-wired.test.sh#the suites of a caller that needs a conditional job do not count`; `tests/quality/coverage/check-suites-wired.test.sh#control: a skip list of prose only still counts every suite` |

### The update job itself

| Threat | Control | Evidence |
|---|---|---|
| A stalled update job (the cron stops firing, or every run fails) | a freshness watcher fails when `update.yml` has no successful scheduled run within `max-age-hours: 24`, runs twice a day on its own schedule, and watches itself at two days (`.github/workflows/freshness.yml#freshness-update`, `.github/workflows/freshness.yml#Freshness`, `.github/workflows/freshness.yml#freshness-itself`, `.github/workflows/reusable-schedule-freshness.yml#Check the newest successful scheduled run`) | test: `tests/ci/reusable/reusable-schedule-freshness.test.sh#an 11-day-old run fails the 10-day limit`; `tests/ci/reusable/reusable-schedule-freshness.test.sh#no successful run on record fails` |
| A hanging `brew` auto-update holds the concurrency group | the update workflow takes `update-formulae` with `cancel-in-progress: false`, so a hung run would queue every hourly run behind it (`.github/workflows/update.yml#update`); every job that invokes `brew` carries `timeout-minutes` and `HOMEBREW_NO_AUTO_UPDATE` (`.github/workflows/update.yml#validate`, `.github/workflows/tests.yml#formulae`, `.github/workflows/audit.yml#audit`) | test: `tests/ci/policy/rules/brew-jobs-are-bounded.test.sh#every job in this repository that runs brew is bounded and told not to update`; proved on a planted workflow first at `tests/ci/policy/rules/brew-jobs-are-bounded.test.sh#a brew job with neither bound nor variable is reported` |
| A persisted job token in a checkout | `persist-credentials: false` on every checkout; the commit step uses the token from `GH_TOKEN` and nothing here pushes with git | test: `tests/ci/policy/workflows/persist-credentials.test.sh`, which reads every `actions/checkout` of every `.yml` and `.yaml` workflow, the reusables included; measurement: the two `git grep` counts in the verification section below, taken the same way (lines that are not comments), must be equal |
| A compromised or malicious action in CI | every remote `uses:` is pinned to a commit SHA and comes from the `actions` organisation: `actions/checkout`, `actions/upload-artifact`, `actions/download-artifact` and `actions/create-github-app-token`, the only one that receives the app's private key (`.github/workflows/update.yml#Mint a token for the updater app`, `.github/workflows/tests.yml#shell`); `brew` is the runner's preinstalled copy; the render job installs only `python3-cryptography` from Debian's archive (`.github/workflows/update.yml#Install the signature verifier`) | measurement: `git grep uses: .github/workflows` on 2026-11-20 lists no owner other than `actions`; test: `tests/quality/lint/check-action-pins.test.sh#a tag is refused` holds the SHA pin. The tooling-isolation assertion (`.github/workflows/reusable-workflow-lint.yml#A job holding a secret must not install third-party tooling`, which runs `scripts/quality/lint/check-tooling-isolation.sh#check-tooling-isolation` as the base commit the pull request event names has it) matches `secrets.*` references, counts the job token as a secret when the job's permissions let it write, and also refuses a `uses:` action from any owner other than `actions` or `github` in such a job, so the first-party app-token action passes and a third-party one would not |
| The updater app's private key is leaked, or used by code other than the mint step | the key is a repository secret that the mint step alone reads (`.github/workflows/update.yml#Mint a token for the updater app`); the token that step produces is short-lived and is the only credential that can write to `main`, because the app is the one bypass actor on the ruleset and humans have none (`CONTRIBUTING.md#The bot commits straight to main, and that is not an oversight`); the job's own `GITHUB_TOKEN` is `contents: read` and no checkout persists a credential; the commit goes through `createCommitOnBranch` with `expectedHeadOid`, so it is GitHub-signed and fails if `main` moved (`.github/workflows/update.yml#Commit the update to main (GitHub-signed)`); the key is used on every scheduled run, so a revoked key or a removed installation turns the run red on the next schedule (`.github/workflows/freshness.yml#freshness-update` fails when no scheduled run has succeeded for 24 hours) | test: `tests/publication/update/update-workflow.test.sh#the commit step invokes gh (not git push)` and `tests/publication/update/update-workflow.test.sh#and the payload uses createCommitOnBranch` hold the commit path; none for the key itself. The mint asks for `contents: write` and nothing else (`permission-contents`), so the token does not widen if the installation does. Residual: the installation's own settings live on GitHub where this tree cannot check them; a leaked key lets its holder push to `main` past the required checks until it is rotated |
| Code that `brew style` or `brew audit` runs alters what is committed, or the tools the commit step runs with the app's token | the two commands install missing Ruby gems from RubyGems before they run, so they run in `validate`, which holds no secret. Only `commit` references the key; it runs no `brew`, installs nothing, and needs `render` and `validate` with no condition of its own. It commits only files whose SHA-256 match the manifest the render job put in its outputs, which `validate` cannot write, refuses a checkout at another head than the render's, and holds the files to the roster again before the key is used (`.github/workflows/update.yml#Check the rendered bytes against the render job's digests`, `scripts/artifacts/formulae-digests.sh#place_manifest`). The lint refuses `brew style` and `brew audit` in any job that references a secret (`.github/workflows/reusable-workflow-lint.yml#A job holding a secret must not install third-party tooling`) | test: `tests/publication/update/update-key-isolation.test.sh#the live workflow keeps all three rules`, with a planted break of each rule; `tests/publication/update/update-key-isolation.test.sh#a changed artifact carrying its own matching manifest is still refused`; `tests/artifacts/formulae-digests.test.sh#placing a tampered tree is refused`; `tests/quality/lint/check-tooling-isolation.test.sh` (the brew cases) |
| Dependency confusion on the tap name | the README documents the fully qualified `glyndor/tap/podup` only (`README.md#Install`); the tap is deliberately not in homebrew-core, and the formula's URLs point at `github.com/Glyndor/podup` (`Formula/podup.rb#Podup`). A bare `brew install podup` would resolve elsewhere or not at all, and the tap cannot influence that | test: none |

## Key rotation

The renderer carries two slots so a rotation can be make-before-break
(`scripts/release/render-formulae.sh#RELEASE_PUBKEY_B64`,
`scripts/release/render-formulae.sh#RELEASE_PUBKEY2_B64`). Phase one: the product publishes a
release still signed with the old key that carries both keys, and this tap adds
the new key to `RELEASE_PUBKEY2_B64`. Phase two: the product signs with the new
key. Phase three: the old key is removed here, which leaves the new key alone
in the first slot. A release signed by either configured key verifies, and a
release signed by neither fails closed (the render-formulae suite,
`tests/release/render-formulae/render-formulae-trust.test.sh#a release signed by the second key still verifies`,
`tests/release/render-formulae/render-formulae-trust.test.sh#the first key alone still verifies`).

Done in the wrong order, the failure is silent by construction. If the product
signs with the new key before this repository carries it, verification fails,
the product is skipped, its formula stays on the last version that verified,
and the job goes red (`.github/workflows/update.yml#Render formulae from the latest signed releases`,
`.github/workflows/update.yml#Fail if any product was skipped`). Nothing users see
changes: `brew upgrade` keeps offering the old release. The freshness watcher
turns red after 24 hours without a successful scheduled run
(`.github/workflows/freshness.yml#freshness-update`). The key constant must be edited by hand in `Glyndor/scoop-bucket` too
-- its renderer is `scripts/release/render-manifests.sh` there, not this one --
but `check-render-drift.sh` compares both key
slots (`scripts/monitoring/check-render-drift.sh#UNITS`) along with the
attestation check, the SemVer comparison
(`scripts/release/render-formulae.sh#release_order`) and the tag guard
(`scripts/release/render-formulae.sh#version_guard`), and the signature check
both channels source (`scripts/release/release-signature.sh#verify_sha256sums`)
is one file that `check-channel-drift.sh` compares byte for byte, so a key, a
comparison or a guard changed in one channel and not the other is reported as
drift.

The ML-DSA-65 key has the same two slots
(`scripts/release/render-formulae.sh#RELEASE_PQ_PUBKEY_B64`,
`scripts/release/render-formulae.sh#RELEASE_PQ_PUBKEY2_B64`) and the same
overlap, and the two channels carry the same key material: a rotation that
lands in one of them and not the other is reported as drift by
`scripts/monitoring/check-render-drift.sh#UNITS`.

The second signature has a switch besides its key: `RELEASE_PQ_REQUIRED`
(`scripts/release/render-formulae.sh#RELEASE_PQ_REQUIRED`), the products whose second
signature is required. It is empty today, here and in Glyndor/scoop-bucket. The order is:
the ML-DSA-65 public key goes into a slot in both channels; a product starts to
sign with both keys; and once a release of it has been verified here with both
signatures, the product is named in the list in both channels. From that commit
on, a release of that product without its second signature is refused. Before
it, a second signature is checked whenever a release carries one, and it stops
nobody who can forge the Ed25519 one, since that forger leaves it out. The list
is part of what `scripts/monitoring/check-render-drift.sh#UNITS` compares
between the channels, like the keys.

## Residual risks

- **A human who merges past a red check.** `dco` and the rest are required,
  and the ruleset gives humans no bypass, so the remaining case is a repository
  administrator changing the ruleset itself. `dco-on-main.yml` reports anything that lands
  unsigned despite that.
- **No recorded field test.** The formula is rendered from a real signed
  release and passes `brew style` and `brew audit --strict` in CI
  (`.github/workflows/tests.yml#formulae`,
  `.github/workflows/audit.yml#audit`); this page
  records no `brew install` of it on a real macOS or Linux machine. Treat it as
  CI-green.
- **A gate replaced in the pull request that should be judged by it.** A required
  status check is matched by name, so someone with write access could replace a
  caller with a stub that emits the name. The mitigation is Code Owner review on
  `.github/workflows/` (see `.github/CODEOWNERS`).
- **A compromised trusted release pipeline.** Manifest signatures and per-asset
  provenance authenticate the publisher and build context, not good intent. A
  malicious binary built and signed by the trusted pipeline can pass both.
- **The roster is trusted, and its fields are checked anyway.** The formula name
  becomes a path and the class name a Ruby constant; the licence, description and
  version check are written inside Ruby quotes without escaping. The renderer
  holds the name to lowercase letters, digits, dot, plus, at and hyphen, the
  class to a capitalised identifier, and refuses a quote, a backslash or `#{` in
  the three metadata fields, so none of them can leave `Formula/` or add Ruby. A
  newline splits the roster record and is refused as a missing field. The roster
  belongs to this repository, so this is defence in depth for the day it has an
  automated source.
- **Rollback requires an explicit override or a changed trust boundary.** The
  renderer refuses a release older than the served version by SemVer precedence
  before writing, even when signature and provenance are valid. Equal precedence
  still renders. `ALLOW_RELEASE_DOWNGRADE=1` permits a deliberate manual rollback
  without bypassing signature, digest or provenance checks; `update.yml` never
  sets it. The version gate for pull requests accepts that rollback only for the
  exact formula and versions named in `scripts/artifacts/approved-rollbacks.txt`
  on the base branch, so the permission is a separate reviewed change that cannot
  ride along with the rollback, and it is single-use: the gate refuses a tree that
  still carries a line whose rollback has already happened. This compares against the local served formula, not an independent
  historical version ledger: replacing that baseline or changing the renderer
  remains possible for an actor who controls publication.
- **Validation is only as honest as Homebrew and its gems.** Code that
  `brew style` or `brew audit` runs cannot reach the key or change what is
  committed, but it can make the validation pass or fail. A formula it lets
  through still has to match the roster and the render job's digests, and
  `audit.yml` audits the published tree again on its own runner.
- **Monitoring shares fate with the monitored.** The update, the audit and the
  freshness watchers all run on GitHub Actions. An outage there stops the tap
  and its alarms together, and unlike apt there is no expiry on the artifact:
  the last formula on `main` stays installable indefinitely.
- **The signature library is not a validated cryptographic module.** Ed25519 is
  an approved algorithm; `python3-cryptography` on the runner is not a CMVP
  module. An assessment that needs one needs a documented exception.
- **No independent audit.** Every measurement on this page was made by the
  project.
- **The second signature is optional until a product is required.** No
  product is in `RELEASE_PQ_REQUIRED` today, so every release is admitted on
  its Ed25519 signature alone, and a forger of that signature is not stopped by
  the ML-DSA-65 check. The list is edited by hand in both channels, in the order
  the key rotation section gives.

## Out of scope

- **A compromised GitHub.** It hosts `main`, serves the assets the formula
  downloads, runs every workflow, and signs the bot's commits. There is no
  second channel to check it against.
- **A compromised product build pipeline.** The release job holds the signing
  key whose public half this repository trusts
  (`scripts/release/render-formulae.sh#RELEASE_PUBKEY_B64`); a release it signs
  is trusted here.
- **The user's machine.** Homebrew itself, `PATH`, and whatever the installed
  binary does once it runs are outside the tap's reach.

## How to verify this document

```sh
git grep -h 'persist-credentials: false' .github/workflows | grep -vc '^[[:space:]]*#'    # equals the next line
git grep -h 'actions/checkout@' .github/workflows | grep -vc '^[[:space:]]*#'              # equals the line above
git grep -hn '^\s*-\? *uses:' .github/workflows | grep -v 'uses: actions/\|uses: ./.github/workflows/reusable-'   # nothing
grep -n 'RELEASE_PUBKEY\|RELEASE_PQ' scripts/release/render-formulae.sh   # the key slots and the required list
bash scripts/quality/hygiene/check-doc-anchors.sh                      # every reference above resolves
bash scripts/artifacts/check-formulae.sh                       # what the formulae may say
bash tests/release/render-formulae.test.sh
bash tests/release/release-signature.test.sh                  # the second signature, without the ML-DSA library
bash tests/publication/update/update-workflow.test.sh
bash tests/publication/update/update-key-isolation.test.sh
bash tests/ci/policy/rules/brew-jobs-are-bounded.test.sh
bash tests/governance/check-dco-on-main.test.sh
bash scripts/quality/coverage/check-test-coverage.sh
gh ruleset list --repo Glyndor/homebrew-tap                     # the rules on main
```

## Reporting

Report vulnerabilities privately through the repository's **Security tab**.
The organization's [security policy](https://github.com/Glyndor/.github/blob/main/SECURITY.md)
carries the response targets.
