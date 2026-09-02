# Threat model

What this tap protects, against whom, with which control, and how each control
is known to work. The README says what to install and what the checksum in a
formula rests on; this page is the assessor's view: one row per threat, the
control that answers it, and the evidence that the control is real. Residual
risks come last, on purpose.

Every `path:line` below was read from this repository on 2026-09-02. Evidence
is of three kinds: a **test** is a case under `tests/` that fails when the
control is removed from the file it covers; a **workflow** is a job that runs
on every push, pull request or schedule, and here that is weaker than it sounds,
because the ruleset on `main` requires no status check at all
(`CONTRIBUTING.md:35-38`); a **measurement** is a number or an outcome read off
a file or a run, with the date.

## What the tap is, and is not

There is no server. `brew install glyndor/tap/podup` clones this repository from
GitHub and reads `Formula/podup.rb` out of the clone (`README.md:17`,
`README.md:37-39`). The git content of `main` is the published artifact, which
is why the update lands as a commit rather than as a file on a bucket
(`update.yml:12-17`). The binaries stay on each product's GitHub release; the
formula pins their URL and SHA-256 (`Formula/podup.rb:12-32`). Nothing is
pushed here by a product and no product holds a credential on this repository
(`update.yml:3-8`).

## Assets

| Asset | Where | Why it matters |
|---|---|---|
| The formulae | `Formula/*.rb` on `main` | what `brew` executes as the installing user |
| The rendered checksums | `sha256` lines inside each formula (`Formula/podup.rb:15,19,26,30`) | the only thing that binds a download to the release the tap verified |
| The organization's release key (public half) | `scripts/render-formulae.sh:25`, with a second slot at `:37` | the trust anchor that admits a release into the tap |
| `main` itself | this repository | every `brew update` reads it, and the bot writes to it without a pull request |

## Trust boundaries and actors

- **A product's GitHub release.** Untrusted until its `SHA256SUMS.sig` verifies
  against a configured key (`scripts/render-formulae.sh:102-164`). Its assets
  are attacker-influenced by definition: whoever can publish a release controls
  them (`scripts/render-formulae.sh:173-175`).
- **GitHub.** Hosts the repository, serves the release assets, runs the
  workflows, and signs the bot's commits through `createCommitOnBranch`
  (`update.yml:159-162`). One trust domain; see Out of scope.
- **The update bot.** `update.yml` runs hourly on `GITHUB_TOKEN` with
  `contents: write` scoped to the one job (`update.yml:46`, `:67-68`) and
  commits straight to `main` (`update.yml:152-189`). The token exists for the
  duration of the run and is persisted in no checkout (`update.yml:81-83`).
- **A human with Write.** Opens pull requests; the ruleset requires signatures
  on `main` but no review and no status check (`CONTRIBUTING.md:35-38`,
  `:73-78`). One person holds Write today (`.github/CODEOWNERS:2`).
- **A macOS user running `brew install`.** Trusts this repository's `main`,
  Homebrew, and their own machine. The tap cannot reach past the second.

## Threats and controls

### Admission: what a formula is allowed to say

| Threat | Control | Evidence |
|---|---|---|
| A tampered or substituted release asset (a binary swapped after publication, or a `SHA256SUMS` rewritten to match it) | the checksum never comes from the asset; it is read from a `SHA256SUMS` whose detached Ed25519 signature verified first, and `brew` refuses a download whose bytes do not match the pinned digest (`scripts/render-formulae.sh:102-164`, `:166-197`) | test: `tests/render-formulae.test.sh:211` (an unverifiable signature skips the product and writes no formula), `:219` (an asset missing from the manifest), `:408`, `:421`, `:433` (a manifest that verifies but is malformed) |
| A release signed by a wrong or rotated key | verification fails closed against every configured slot; exhausting the slots is an error, not a fallthrough, and the product keeps the formula it had (`scripts/render-formulae.sh:137-162`, `:426-433`) | test: `tests/render-formulae.test.sh:306` (two wrong keys still fail closed), `:395` (a well-formed key that did not sign it fails as a signature), `:248` (the skipped product keeps its formula) |
| The trust anchor is swapped from outside the script | the key is a constant overridden only by `--pubkey` and `--pubkey2`; no environment variable reaches it (`scripts/render-formulae.sh:39-62`) | test: `tests/render-formulae.test.sh:273` (the environment cannot swap the trust anchor) |
| A compromised product repository publishes a malicious release under a valid signature | the tap verifies that the manifest is the one the product published and that what it interpolates is well formed: a tag carrying Ruby is refused before it reaches the generated formula (`scripts/render-formulae.sh:287-317`), and a digest must be one entry of 64 hex characters (`:176-196`). It cannot tell a malicious binary from a good one when both are correctly signed, and the release job of the product holds the signing key (`update.yml:36-38`), so this is a residual risk, stated below | test: `tests/render-formulae.test.sh:323` (a release tag carrying Ruby is refused, and the error names the tag rather than the signature); none for the binary itself |
| One product's broken release removes or holds back another's | each product renders on its own; a failure leaves that product's formula as it was, the rest still commit, and the job fails last so the skip is loud (`scripts/render-formulae.sh:422-434`, `update.yml:96-108`, `:191-199`) | test: `tests/render-formulae.test.sh:245-248`, `tests/update-workflow.test.sh:129-131` (exit 3 does not abort the step), `:241` (the failure step is last) |
| A render that empties the tap is committed | the validate step refuses an empty `Formula/` before `brew` is set up, so the guard does not depend on the toolchain (`update.yml:139-144`) | test: `tests/update-workflow.test.sh:155` (an emptied `Formula/` fails validation) |

### Publication: how a commit reaches `main`

| Threat | Control | Evidence |
|---|---|---|
| A malicious or careless formula committed by a human | `main` accepts only signed commits and linear history, and the bot's commits are GitHub-signed; that is the compensating control for the missing require-PR, and it says who committed, not whether the change was right (`CONTRIBUTING.md:35-38`, `:76-78`). A hand edit to a formula is overwritten within the hour: the renderer rewrites every declared formula from the signed release and commits whatever differs (`scripts/render-formulae.sh:388-412`, `update.yml:110-115`). An edit to the generator itself is not | the ruleset lives on GitHub, not in this tree, and this page cites what `CONTRIBUTING.md` records of it; test: none for the overwrite; `tests/update-workflow.test.sh:218-225` holds the commit path to `createCommitOnBranch` so a refactor to `git push` cannot ship an unsigned commit |
| A human commit lands without a `Signed-off-by` trailer (the DCO gap) | `dco.yml` runs on pull requests and is not required (`dco.yml:11-19`, `CONTRIBUTING.md:73-75`); `dco-on-main.yml` reports every human-authored commit that arrived without the trailer, exempting the bot by who pushed rather than by what the commit says (`dco-on-main.yml:36-61`, `scripts/check-dco-on-main.sh:38-47`, `:77-91`). Detection, not prevention: the commit is already on `main` when it speaks | test: `tests/check-dco-on-main.test.sh:72` (an unsigned human commit fails), `:97` (a human using the bot's exact subject is still reported), `:112` (an author field impersonating the bot is still reported) |
| A pull request neutralises a check by replacing its caller with a stub of the same name | none that prevents it; `CODEOWNERS` lists `.github/workflows/` so that required review from Code Owners can be switched on the day a second person gets Write (`.github/CODEOWNERS:4-17`) | measurement: single maintainer, read off `.github/CODEOWNERS:2` |
| A caller quietly switches the test job off | `workflow-lint` asserts from outside the shell job that every caller of `reusable-shell-ci` passes a `test-command` that runs a suite, and that at least one caller exists (`reusable-workflow-lint.yml:113-156`) | test: `tests/reusable-workflow-lint.test.sh:108` (an empty `test-command` is refused), `:130` (a tree with no caller is refused) |
| A test exists and no workflow runs it, or a script has no test | one watcher fails when a suite under `tests/` is invoked by no workflow, another when a script under `scripts/` has no suite, each including itself (`scripts/check-test-coverage.sh:22-35`, `tests.yml:31-50`) | test: `tests/ci-runs-every-test.test.sh:59`, `:75`; `tests/check-test-coverage.test.sh` |

### The update job itself

| Threat | Control | Evidence |
|---|---|---|
| A stalled update job (the cron stops firing, or every run fails) | a freshness watcher fails when `update.yml` has no successful scheduled run within `max-age-days: 3`, runs twice a day on its own schedule, and watches itself at two days (`freshness.yml:41-42`, `:56-63`, `:84-91`, `reusable-schedule-freshness.yml:71-95`) | test: `tests/reusable-schedule-freshness.test.sh:120` (an 11-day-old run fails the 10-day limit), `:132` (no successful run on record fails) |
| A hanging `brew` auto-update holds the concurrency group | the update job takes `update-formulae` with `cancel-in-progress: false`, so a hung run would queue every hourly run behind it (`update.yml:59-61`); every job that invokes `brew` carries `timeout-minutes` and `HOMEBREW_NO_AUTO_UPDATE` (`update.yml:76-79`, `tests.yml:82-89`, `audit.yml:27-32`) | test: `tests/brew-jobs-are-bounded.test.sh:138` (every job that runs `brew` is bounded and told not to update), proved on a planted workflow first at `:111` |
| A persisted job token in a checkout | `persist-credentials: false` on every checkout; the commit step uses the token from `GH_TOKEN` and nothing here pushes with git | measurement: 13 `actions/checkout` steps and 13 `persist-credentials: false` across `.github/workflows/` on 2026-09-02; test: none |
| A third-party action in CI | none. The only actions are `actions/checkout`, `actions/setup-go` and `actions/cache`, each pinned to a commit SHA; `brew` is the runner's preinstalled copy (`update.yml:149`, `tests.yml:98`); the update job installs only `python3-cryptography` from Debian's archive (`update.yml:85-88`) | measurement: `git grep uses: .github/workflows` on 2026-09-02; test: none. The tooling-isolation assertion (`reusable-workflow-lint.yml:158-272`) matches `secrets.*` references and would not see the update job, which holds `github.token` |
| Dependency confusion on the tap name | the README documents the fully qualified `glyndor/tap/podup` only (`README.md:17`); the tap is deliberately not in homebrew-core, and the formula's URLs point at `github.com/Glyndor/podup` (`Formula/podup.rb:8,14`). A bare `brew install podup` would resolve elsewhere or not at all, and the tap cannot influence that | test: none |

## Key rotation

The renderer carries two slots so a rotation can be make-before-break
(`scripts/render-formulae.sh:17-37`). Phase one: the product publishes a
release still signed with the old key that carries both keys, and this tap adds
the new key to `RELEASE_PUBKEY2_B64`. Phase two: the product signs with the new
key. Phase three: the old key is removed here, which leaves the new key alone
in the first slot. A release signed by either configured key verifies, and a
release signed by neither fails closed (`tests/render-formulae.test.sh:293`,
`:299`, `:306`).

Done in the wrong order, the failure is silent by construction. If the product
signs with the new key before this repository carries it, verification fails,
the product is skipped, its formula stays on the last version that verified,
and the job goes red (`update.yml:96-108`, `:191-199`). Nothing users see
changes: `brew upgrade` keeps offering the old release. The freshness watcher
turns red after three days without a successful scheduled run
(`freshness.yml:63`). Two things the tree does not do: the key constant must be
edited by hand in `Glyndor/scoop-bucket` too (`scripts/render-formulae.sh:21-24`),
and `check-render-drift.sh` compares the verification functions and not the
constants (`scripts/check-render-drift.sh:76-78`), so a key changed in one
channel and not the other is not reported as drift.

## Residual risks

- **DCO on human commits is detected, not prevented.** The routes to prevention
  were measured and declined; the record is in `CONTRIBUTING.md:44-56`. What
  stays uncovered is a human who sees the red run and merges anyway.
- **No field test on macOS hardware.** The formula is rendered from a real
  signed release and passes `brew style` and `brew audit --strict` in CI
  (`tests.yml:106`, `audit.yml:71`); no `brew install` of it has been recorded
  on a real Mac as of 2026-09-02. Treat it as CI-green.
- **One maintainer.** Every pull request is reviewed and merged by its author
  (`.github/CODEOWNERS:2`), and a required status check is matched by name, so
  the mitigation for a second person with Write is written down rather than on.
- **A valid signature is the end of what the tap can check.** A product whose
  release pipeline is compromised signs what it likes; admission here binds the
  formula to the manifest, not the manifest to good intent.
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
  key (`update.yml:36-38`); a release it signs is trusted here.
- **The user's machine.** Homebrew itself, `PATH`, and whatever the installed
  binary does once it runs are outside the tap's reach.

## How to verify this document

```sh
git grep -n 'persist-credentials' .github/workflows | wc -l    # 13
git grep -c 'actions/checkout@' .github/workflows | awk -F: '{s+=$2} END {print s}'   # 13
git grep -hn '^\s*-\? *uses:' .github/workflows | grep -v 'uses: actions/\|uses: ./.github/workflows/reusable-'   # nothing
sed -n 17,37p scripts/render-formulae.sh                        # the two key slots
bash tests/render-formulae.test.sh
bash tests/update-workflow.test.sh
bash tests/brew-jobs-are-bounded.test.sh
bash tests/check-dco-on-main.test.sh
bash scripts/check-test-coverage.sh
gh ruleset list --repo Glyndor/homebrew-tap                     # the rules on main
```

## Reporting

Report vulnerabilities privately through the repository's **Security tab**.
The organization's [security policy](https://github.com/Glyndor/.github/blob/main/SECURITY.md)
carries the response targets.
