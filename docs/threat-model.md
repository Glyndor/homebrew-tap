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
`scripts/quality/check-doc-anchors.sh` resolves every reference below and
fails when one does not, so a moved function is caught by the build instead of
by the next reader.

Evidence is of three kinds: a **test** is a case under `tests/` that fails when the
control is removed from the file it covers; a **workflow** is a job that runs
on every push, pull request or schedule, and here that is weaker than it sounds,
because the updater app bypasses the required checks on `main`; human pull
requests must pass them (`CONTRIBUTING.md#Branch flow`, “Branch rules”); a
**measurement** is a number or an outcome read off
a file or a run, with the date.

## What the tap is, and is not

There is no server. `brew install glyndor/tap/podup` clones this repository from
GitHub and reads `Formula/podup.rb` out of the clone (`README.md#Install`,
`README.md#What you are trusting`). The git content of `main` is the published
artifact, which is why the update lands as a commit rather than as a file on a
bucket (`.github/workflows/update.yml#Render, validate, and commit`). The
binaries stay on each product's GitHub release; the formula pins their URL and
SHA-256 (`Formula/podup.rb#Podup`). Nothing is
pushed here by a product and no product holds a credential on this repository
(`.github/workflows/update.yml#update`).

## Assets

| Asset | Where | Why it matters |
|---|---|---|
| The formulae | `Formula/*.rb` on `main` | what `brew` executes as the installing user |
| The rendered checksums | `sha256` lines inside each formula (`Formula/podup.rb#Podup`) | the only thing that binds a download to the release the tap verified |
| The organization's release key (public half) | `scripts/release/render-formulae.sh#RELEASE_PUBKEY_B64`, with a second slot at `scripts/release/render-formulae.sh#RELEASE_PUBKEY2_B64` | the trust anchor that admits a release into the tap |
| `main` itself | this repository | every `brew update` reads it, and the bot writes to it without a pull request |

## Trust boundaries and actors

- **A product's GitHub release.** Untrusted until its `SHA256SUMS.sig` verifies
  against a configured key (`scripts/release/render-formulae.sh#verify_sha256sums`). Its assets
  are attacker-influenced by definition: whoever can publish a release controls
  them (`scripts/release/render-formulae.sh#hash_of`).
- **GitHub.** Hosts the repository, serves the release assets, runs the
  workflows, and signs the bot's commits through `createCommitOnBranch`
  (`.github/workflows/update.yml#Commit the update to main (GitHub-signed)`). One trust domain; see Out of scope.
- **The update bot.** `update.yml` runs hourly. The job itself holds a
  read-only `GITHUB_TOKEN` (`contents: read`). The write goes through a token
  minted for the `glyndor-updater` GitHub App (`contents: write` on this
  repository only) by `actions/create-github-app-token`, from a long-lived
  private key held as the repository secret `UPDATER_APP_PRIVATE_KEY`. The app
  is a bypass actor on the `main` ruleset and commits through
  `createCommitOnBranch`. A leaked key would let its holder push to `main` past
  the required checks, which is why the key is the credential that matters here.
- **A human with Write.** Opens pull requests. The ruleset requires a pull
  request, nine status checks with the branch up to date, signed commits and
  CodeQL, and gives humans no bypass. One person holds Write today
  (`.github/CODEOWNERS#*`).
- **A macOS user running `brew install`.** Trusts this repository's `main`,
  Homebrew, and their own machine. The tap cannot reach past the second.

## Threats and controls

### Admission: what a formula is allowed to say

| Threat | Control | Evidence |
|---|---|---|
| A tampered or substituted release asset (a binary swapped after publication, or a `SHA256SUMS` rewritten to match it) | the checksum never comes from the asset; it is read from a `SHA256SUMS` whose detached Ed25519 signature verified first, and `brew` refuses a download whose bytes do not match the pinned digest (`scripts/release/render-formulae.sh#verify_sha256sums`, `scripts/release/render-formulae.sh#verify_attestation`) | test: `tests/release/render-formulae.test.sh#an unverifiable signature skips the product`; `tests/release/render-formulae.test.sh#an asset missing from the manifest skips the product`; `tests/release/render-formulae/render-formulae-trust.test.sh#an asset listed twice is rejected`; `tests/release/render-formulae/render-formulae-trust.test.sh#a non-hexadecimal checksum is rejected`; `tests/release/render-formulae/render-formulae-trust.test.sh#a short digest is rejected` (a manifest that verifies but is malformed) |
| A release signed by a wrong or rotated key | verification fails closed against every configured slot; exhausting the slots is an error, not a fallthrough, and the product keeps the formula it had (`scripts/release/render-formulae.sh#verify_sha256sums`, `scripts/release/render-formulae.sh#render_product`) | test: `tests/release/render-formulae/render-formulae-trust.test.sh#two wrong keys still fail closed`; `tests/release/render-formulae/render-formulae-trust.test.sh#a well-formed key that did not sign it fails as a signature`; `tests/release/render-formulae.test.sh#the skipped product keeps the formula it had` |
| The trust anchor is swapped from outside the script | the key is a constant overridden only by `--pubkey` and `--pubkey2`; no environment variable reaches it (`scripts/release/render-formulae.sh#RELEASE_PUBKEY_B64`) | test: `tests/release/render-formulae/render-formulae-trust.test.sh#the environment cannot swap the trust anchor` |
| A compromised product repository publishes a malicious release under a valid signature | the tap verifies that the manifest is the one the product published and that what it interpolates is well formed: a tag carrying Ruby is refused before it reaches the generated formula (`scripts/release/render-formulae.sh#version_guard`), and a digest must be one entry of 64 hex characters (`scripts/release/render-formulae.sh#hash_of`). It cannot tell a malicious binary from a good one when both are correctly signed, and the release job of the product holds the signing key whose public half is `scripts/release/render-formulae.sh#RELEASE_PUBKEY_B64`, so this is a residual risk, stated below | test: `tests/release/render-formulae/render-formulae-version.test.sh#a release tag carrying Ruby is refused`; `tests/release/render-formulae/render-formulae-version.test.sh#and the error names the tag rather than the signature`; none for the binary itself |
| One product's broken release removes or holds back another's | each product renders on its own; a failure leaves that product's formula as it was, the rest still commit, and the job fails last so the skip is loud (`scripts/release/render-formulae.sh#render_product`, `.github/workflows/update.yml#Render formulae from the latest signed releases`, `.github/workflows/update.yml#Fail if any product was skipped`) | test: `tests/publication/update/update-workflow.test.sh#exit 3 does NOT abort the step`; `tests/publication/update/update-workflow.test.sh#the failure step is last, after the commit` |
| A render that empties the tap is committed | the validate step refuses an empty `Formula/` before `brew` is set up, so the guard does not depend on the toolchain (`.github/workflows/update.yml#Validate the re-rendered formulae`) | test: `tests/publication/update/update-workflow.test.sh#an emptied Formula/ fails validation` |
| A formula names a url of another Glyndor repository, a second tag inside the same formula, an asset the roster does not declare, or a statement the generator does not write | the content of every formula is compared with what the generator emits for the product its roster row declares: the repository, the tag on every url, the assets, the shape of the digests, and the statements themselves (`scripts/artifacts/check-formulae.sh#check-formulae`). It runs before the commit lands (`.github/workflows/update.yml#Validate the re-rendered formulae`) and on every push and pull request (`.github/workflows/tests.yml#products`); a roster with no rows, or a formula no row declares, is an error rather than a vacuous pass | `tests/artifacts/check-formulae.test.sh` plants each violation, a comment that tries to move the block stack, CRLF and a forged file name, and reruns them against a copy of the check with its verdict removed |

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
| A malicious or careless formula committed by a human | `main` accepts only signed commits and linear history, and the bot's commits are GitHub-signed; together with the required pull request and checks, and it says who committed, not whether the change was right (`CONTRIBUTING.md#The bot commits straight to main, and that is not an oversight`, `CONTRIBUTING.md#Branch flow`). A hand edit to a formula is overwritten within the hour: the renderer rewrites every declared formula from the signed release and commits whatever differs (`scripts/release/render-formulae.sh#render_product`, `.github/workflows/update.yml#Render formulae from the latest signed releases`). An edit to the generator itself is not | the ruleset lives on GitHub, not in this tree, and this page cites what `CONTRIBUTING.md` records of it; test: none for the overwrite; `tests/publication/update/update-workflow.test.sh#the commit step invokes gh (not git push)` and `tests/publication/update/update-workflow.test.sh#and the payload uses createCommitOnBranch` hold the commit path to `createCommitOnBranch` so a refactor to `git push` cannot ship an unsigned commit |
| A human commit lands without a `Signed-off-by` trailer (the DCO gap) | `dco.yml` runs on pull requests and is a required check; `dco-on-main.yml` reports every human-authored commit that arrived without the trailer, exempting the bot by who pushed rather than by what the commit says (`.github/workflows/dco-on-main.yml#Check the pushed commits`, `scripts/governance/check-dco-on-main.sh#is_bot`, `scripts/governance/check-dco-on-main.sh#exempt_all`). The required pull-request DCO check prevents an unsigned proposed commit from merging through that path. The push watcher detects any unsigned human commit that nevertheless lands; it cannot undo publication | test: `tests/governance/check-dco-on-main.test.sh#an unsigned human commit fails`; `tests/governance/check-dco-on-main.test.sh#a human using the bot's exact subject is still reported`; `tests/governance/check-dco-on-main.test.sh#a commit whose author field impersonates the bot is still reported` |
| A pull request neutralises a check by replacing its caller with a stub of the same name | none that prevents it; `CODEOWNERS` lists `.github/workflows/` so that required review from Code Owners can be switched on the day a second person gets Write (`.github/CODEOWNERS#.github/workflows/`) | measurement: single maintainer, read off `.github/CODEOWNERS#*` |
| A caller quietly switches the test job off | `workflow-lint` asserts from outside the shell job that every caller of `reusable-shell-ci` passes a `test-command` that runs a suite, and that at least one caller exists (`.github/workflows/reusable-workflow-lint.yml#A required test job must not be switchable off`) | test: `tests/ci/reusable/reusable-workflow-lint.test.sh#a caller with an empty test-command is refused`; `tests/ci/reusable/reusable-workflow-lint.test.sh#a tree with no reusable-shell-ci caller is refused` |
| A test exists and no workflow runs it, or a script has no test | one watcher fails when a suite under `tests/` is invoked by no workflow, another when a script under `scripts/` has no suite, each including itself (`tests/ci/suites/ci-runs-every-test.test.sh#every test in tests/ is invoked by a workflow`, `scripts/quality/check-test-coverage.sh#check-test-coverage`, `.github/workflows/tests.yml#shell`) | test: `tests/ci/suites/ci-runs-every-test.test.sh#this watcher is itself invoked by a workflow`; `tests/quality/check-test-coverage.test.sh#check-test-coverage` |

### The update job itself

| Threat | Control | Evidence |
|---|---|---|
| A stalled update job (the cron stops firing, or every run fails) | a freshness watcher fails when `update.yml` has no successful scheduled run within `max-age-days: 3`, runs twice a day on its own schedule, and watches itself at two days (`.github/workflows/freshness.yml#freshness-update`, `.github/workflows/freshness.yml#Freshness`, `.github/workflows/freshness.yml#freshness-itself`, `.github/workflows/reusable-schedule-freshness.yml#Check the newest successful scheduled run`) | test: `tests/ci/reusable/reusable-schedule-freshness.test.sh#an 11-day-old run fails the 10-day limit`; `tests/ci/reusable/reusable-schedule-freshness.test.sh#no successful run on record fails` |
| A hanging `brew` auto-update holds the concurrency group | the update job takes `update-formulae` with `cancel-in-progress: false`, so a hung run would queue every hourly run behind it (`.github/workflows/update.yml#update`); every job that invokes `brew` carries `timeout-minutes` and `HOMEBREW_NO_AUTO_UPDATE` (`.github/workflows/update.yml#Render formulae from the latest signed releases`, `.github/workflows/tests.yml#shell`, `.github/workflows/audit.yml#Audit formulae as an installed tap`) | test: `tests/ci/policy/rules/brew-jobs-are-bounded.test.sh#every job in this repository that runs brew is bounded and told not to update`; proved on a planted workflow first at `tests/ci/policy/rules/brew-jobs-are-bounded.test.sh#a brew job with neither bound nor variable is reported` |
| A persisted job token in a checkout | `persist-credentials: false` on every checkout; the commit step uses the token from `GH_TOKEN` and nothing here pushes with git | measurement: the two `git grep` counts in the verification section below must be equal; test: none |
| A third-party action in CI | one: `actions/create-github-app-token` in `update.yml`, pinned to a commit SHA, which receives the app's private key. The others are `actions/checkout`, `actions/setup-go` and `actions/cache`, each pinned to a commit SHA; `brew` is the runner's preinstalled copy (`.github/workflows/update.yml#Mint a token for the updater app`, `.github/workflows/tests.yml#shell`); the update job installs only `python3-cryptography` from Debian's archive (`.github/workflows/update.yml#Install the signature verifier`) | measurement: `git grep uses: .github/workflows` on 2026-09-02; test: none. The tooling-isolation assertion (`.github/workflows/reusable-workflow-lint.yml#A job holding a secret must not install third-party tooling`) matches `secrets.*` references and also refuses a `uses:` action from any owner other than `actions` or `github` in such a job, so the first-party app-token action passes and a third-party one would not |
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
turns red after three days without a successful scheduled run
(`.github/workflows/freshness.yml#freshness-update`). The key constant must be edited by hand in `Glyndor/scoop-bucket` too
-- its renderer is `scripts/release/render-manifests.sh` there, not this one --
but `check-render-drift.sh` compares both key
slots (`scripts/monitoring/check-render-drift.sh#UNITS`) along with the
verification functions, the SemVer comparison
(`scripts/release/render-formulae.sh#release_order`) and the tag guard
(`scripts/release/render-formulae.sh#version_guard`), so a key, a comparison
or a guard changed in one channel and not the other is reported as drift.

## Residual risks

- **A human who merges past a red check.** `dco` and the rest are required,
  and the ruleset gives humans no bypass, so the remaining case is the owner
  changing the ruleset itself. `dco-on-main.yml` reports anything that lands
  unsigned despite that.
- **No field test on macOS hardware.** The formula is rendered from a real
  signed release and passes `brew style` and `brew audit --strict` in CI
  (`.github/workflows/tests.yml#formulae`,
  `.github/workflows/audit.yml#Audit formulae as an installed tap`); no
  `brew install` of it has been recorded
  on a real Mac as of 2026-09-02. Treat it as CI-green.
- **One maintainer.** Every pull request is reviewed and merged by its author
  (`.github/CODEOWNERS#*`), and a required status check is matched by name, so
  the mitigation for a second person with Write is written down rather than on.
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
  sets it. This compares against the local served formula, not an independent
  historical version ledger: replacing that baseline or changing the renderer
  remains possible for an actor who controls publication.
- **Monitoring shares fate with the monitored.** The update, the audit and the
  freshness watchers all run on GitHub Actions. An outage there stops the tap
  and its alarms together, and unlike apt there is no expiry on the artifact:
  the last formula on `main` stays installable indefinitely.
- **The signature library is not a validated cryptographic module.** Ed25519 is
  an approved algorithm; `python3-cryptography` on the runner is not a CMVP
  module. An assessment that needs one needs a documented exception.
- **No independent audit.** Every measurement on this page was made by the
  project.

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
git grep -n 'persist-credentials' .github/workflows | wc -l    # equals the next line
git grep -c 'actions/checkout@' .github/workflows | awk -F: '{s+=$2} END {print s}'   # equals the line above
git grep -hn '^\s*-\? *uses:' .github/workflows | grep -v 'uses: actions/\|uses: ./.github/workflows/reusable-'   # nothing
grep -n 'RELEASE_PUBKEY' scripts/release/render-formulae.sh     # the two key slots
bash scripts/quality/check-doc-anchors.sh                      # every reference above resolves
bash scripts/artifacts/check-formulae.sh                       # what the formulae may say
bash tests/release/render-formulae.test.sh
bash tests/publication/update/update-workflow.test.sh
bash tests/ci/policy/rules/brew-jobs-are-bounded.test.sh
bash tests/governance/check-dco-on-main.test.sh
bash scripts/quality/check-test-coverage.sh
gh ruleset list --repo Glyndor/homebrew-tap                     # the rules on main
```

## Reporting

Report vulnerabilities privately through the repository's **Security tab**.
The organization's [security policy](https://github.com/Glyndor/.github/blob/main/SECURITY.md)
carries the response targets.
