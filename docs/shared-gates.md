# Shared gates: contract, dependency security and secret scanning

Automation supplies reusable workflows that consuming repositories call from their own
workflow. The calling workflow, its triggers and the decision to require a check stay with the
consuming repository (ADR-009). Automation does not run anything on behalf of other repositories.

Sources: [ADR-009](https://github.com/House-Hold-Hub/Documentation/blob/main/architecture/adr/ADR-009-five-repository-topology.md),
[ADR-014](https://github.com/House-Hold-Hub/Documentation/blob/main/architecture/adr/ADR-014-api-contract-governance.md),
[testing strategy](https://github.com/House-Hold-Hub/Documentation/blob/main/quality/testing-strategy.md),
[security model](https://github.com/House-Hold-Hub/Documentation/blob/main/security/security-model.md).

## Blocking CI checks versus GitHub-native security features

These are different mechanisms and only the first kind can block a merge through a required
status check.

| | Blocking CI check (this repository) | GitHub-native feature |
|---|---|---|
| Examples | OpenAPI validation, OSV lockfile scan, Gitleaks scan | Secret scanning, push protection, Dependabot alerts and security updates, code scanning |
| Where it lives | Workflow file, runs on the pull request | Repository or organisation settings |
| Can be a required status check | Yes | No (push protection can reject a push, alerts never block a merge) |
| Configured by | Code in this repository | An administrator in Settings → Code security |

The native features are complementary, not a substitute: they are repository settings that this
repository's code cannot enable or verify. See [Current state and limits](#current-state-and-limits).

## Reusable workflows

All three use `permissions: contents: read`, take no secrets, pin third-party actions by commit
SHA and container images by digest, and check out with `persist-credentials: false`.
Each has `ref`, `runs-on`, `timeout-minutes` and `report-only` inputs and an `outcome` output.
`report-only` exists for adoption and for the self-tests; a blocking gate leaves it `false`.

| Workflow | Purpose | Key inputs |
|---|---|---|
| `openapi-validate.yml` | Bundles (syntax and `$ref` resolution) and lints an OpenAPI document with Redocly | `spec-path` (`api/openapi.yaml`), `config-path` (`redocly.yaml`), `redocly-version` (`2.54.3`, exact), `node-version` |
| `dependency-security.yml` | Scans lockfiles with OSV-Scanner; fails on any known vulnerability | `lockfiles` (required, newline-separated, e.g. `package-lock.json`, `uv.lock`) |
| `secret-scan.yml` | Scans git history with Gitleaks; on pull requests only the commits the PR adds; findings are redacted | `mode` (`history` or `tree`), `config-path` (empty uses `.gitleaks.toml` when present) |

Not duplicated here, on purpose: the producer and consumer contract-drift checks
(Backend `Contract drift`, Frontend `contract-drift`) stay in Backend and Frontend, and so do
their lint, type-check, test and build jobs. There is no coverage threshold
(testing strategy: coverage is not a merge gate).

### Use from a consuming repository

Copy [`examples/service-gates.yml`](../examples/service-gates.yml) to
`.github/workflows/gates.yml` and keep the jobs that apply:

| Repository | Secret scan | Dependency security | OpenAPI |
|---|---|---|---|
| Backend | yes | `lockfiles: uv.lock` | no (contract drift already covered) |
| Frontend | yes | `package-lock.json` (+ `tools/*/package-lock.json` if wanted) | no |
| Documentation | yes | n/a (no lockfile) | yes; replaced its own `openapi-contract.yml`, see below |
| Infrastructure | yes | n/a until a lockfile exists | no |

Reference the workflow by full commit SHA for reproducibility (`@v1` is a moving alias, see
[versioning](docker-build.md#versioning)). Never reference a branch. Do not add `paths:` filters
to a workflow whose jobs you require: a required check skipped by a path filter stays pending and
blocks every other pull request.

Documentation's former `openapi-contract.yml` did what `openapi-validate.yml` does (same Redocly
version and rules). Documentation now calls the reusable workflow from its `gates.yml`, without
the old `paths:` filters, so the check runs on every pull request and can be required.

## Required status check names

GitHub publishes the check name, not the workflow name. For a normal job it is the job's `name`.
For a job that calls a reusable workflow it is `<caller job name> / <called job name>`.
List the real names of a commit before requiring anything:

```bash
gh api repos/House-Hold-Hub/<repo>/commits/<sha>/check-runs -q '.check_runs[] | .name'
```

Automation's own checks (verified from a pull-request run):

| Check name | Source | Meaning |
|---|---|---|
| `actionlint` | `lint.yml` | Workflow syntax |
| `Smoke test reusable docker-build / build` | `ci.yml` | Reusable Docker build works |
| `Secret scan / scan` | `gates.yml` | No secret in the commits the PR adds |
| `Gate self-tests` | `gates.yml` | Positive fixtures pass and negative fixtures are detected by all three gates |

`Gate self-tests` aggregates the eight `Self-test …` jobs, which are visible but not individually
required. Automation has no OpenAPI document and no lockfile, so the OpenAPI and dependency gates
run only against fixtures here. Renaming a job or workflow changes its check name and silently
removes the protection: update branch protection in the same change.

## Branch protection

[`scripts/set-required-checks.sh`](../scripts/set-required-checks.sh) extends the required checks
of a default branch without touching anything else, and binds each check to GitHub Actions
(`app_id` 15368) so another app cannot satisfy it; a requested check already present with no app or
another app is rebound. It is a dry run unless `--apply` is given, and re-running it is a no-op.
It creates protection only after GitHub answered 404 "Branch not protected"; any other API error
aborts without changes. It refuses repositories protected by a ruleset.
`tests/scripts/set-required-checks.test.sh` (CI job `Test set-required-checks script`, a required
check in Automation) covers these cases against a stubbed `gh`.

```bash
scripts/set-required-checks.sh House-Hold-Hub/Automation --apply \
  "actionlint" "Smoke test reusable docker-build / build" "Secret scan / scan" \
  "Gate self-tests" "Test set-required-checks script"
```

Documentation is protected by a ruleset ("Protect main"), which the script refuses to edit: its
required checks are managed in the ruleset itself.

Baseline for a repository without protection (the one Frontend already uses): pull request
required with 0 approvals, required checks, enforced for administrators, no force-push, no
branch deletion, "require branches to be up to date" off. Nothing about review counts or
coverage is imposed by this issue.

### State found and applied

Final state, read from GitHub on 2026-10-16. Every consumer's `gates.yml` is on its `main` and
calls the shared workflows at Automation commit `5eeae49dfbef5c30fadb4d2ab8a83db068c01488`. The
check names below are those GitHub publishes. On each `main` the checks that run there are green: every
required check in Automation, Frontend, Documentation and Infrastructure, and in Backend `Contract
drift`, `Secret scan / scan` and `Dependency security / scan`. Backend's `Lint`, `Type check` and
`Test` run only on pull requests (see below), so they are required but not observed on `main`.

| Repository | Adoption | Required on `main` |
|---|---|---|
| Automation | Own secret scan and self-tests ([#6](https://github.com/House-Hold-Hub/Automation/pull/6)) | `actionlint`, `Smoke test reusable docker-build / build`, `Secret scan / scan`, `Gate self-tests`, `Test set-required-checks script` |
| Backend | Secret scan and dependency security on `uv.lock` ([#44](https://github.com/House-Hold-Hub/Backend/pull/44)) | `Lint`, `Type check`, `Test`, `Contract drift`, `Secret scan / scan`, `Dependency security / scan` |
| Frontend | Secret scan and dependency security on `package-lock.json` and `tools/lint/package-lock.json` ([#30](https://github.com/House-Hold-Hub/Frontend/pull/30)) | `lint`, `typecheck`, `test`, `build`, `contract-drift` (preserved) plus `Secret scan / scan`, `Dependency security / scan` |
| Documentation | Secret scan and OpenAPI validation without path filters ([#6](https://github.com/House-Hold-Hub/Documentation/pull/6)); one historical Gitleaks exclusion ([#12](https://github.com/House-Hold-Hub/Documentation/pull/12)) | Ruleset "Protect main" (PR required, no deletion or force-push, existing rules preserved) with `Secret scan / scan` and `OpenAPI / validate` |
| Infrastructure | Secret scan only ([#6](https://github.com/House-Hold-Hub/Infrastructure/pull/6)); no lockfile, OpenAPI document or other workflow exists | `Secret scan / scan`; PR required, admins enforced, no force-push or deletion |

All required checks are bound to GitHub Actions (`app_id` 15368). Backend and Frontend keep their
own lint, type-check, test, build and contract-drift jobs; none is duplicated by the shared gates,
and neither adopts `openapi-validate.yml`, because Documentation owns and validates the
specification. Backend's `ci.yml` has no `push` trigger, so
`Lint`, `Type check` and `Test` are verified on pull requests only, never on `main` itself; the
checks verified on Backend's `main` are `Contract drift`, `Secret scan / scan` and `Dependency
security / scan`.

Before adoption Automation, Backend and Infrastructure had no protection, Frontend already
required its five checks, and Documentation's ruleset required none.

A check that no workflow publishes must not be required: confirm the name from a pull-request run
before adding it.

## Verification

- Syntax: `actionlint` (`lint.yml`).
- Positive and negative cases for each gate: `gates.yml`, fixtures under [`tests/fixtures`](../tests/fixtures)
  (valid and invalid OpenAPI documents, clean and vulnerable npm and uv lockfiles, a synthetic
  marker for the secret scanner that does not resemble a real credential).
- Dependency fixtures depend on the OSV database: the vulnerable ones (`lodash` 4.17.15,
  `requests` 2.19.0) stay vulnerable; the clean one (`is-number` 7.0.0) is expected to stay clean
  and would need replacing if an advisory is ever published for it.

## Current state and limits

- **Native security features are disabled** on all five repositories (checked through the API):
  secret scanning, push protection, Dependabot security updates. Enabling them is a repository
  administrator decision outside this change; until then the Gitleaks and OSV checks are the only
  automated coverage, and a secret pushed straight to a non-protected branch is detected only when
  a pull request is opened.
- **Secret scanning on pull requests covers the commits the PR adds**, not older history. History
  before adoption is scanned on pushes to `main`.
- **OSV-Scanner needs network access** to the OSV database and fails any known vulnerability, with
  no severity threshold. A dependency without a fix blocks until the caller removes or replaces it.
  A threshold would be a policy decision for the security model.
- **Redocly's own dependency tree** is pinned by exact CLI version but resolved by `npx` without a
  lockfile; install scripts are disabled.
- **Action SHAs are not auto-updated.** Nothing here configures Dependabot version updates; pinned
  SHAs and image digests must be refreshed by hand.
- **One historical exclusion exists.** Documentation's `.gitleaksignore` suppresses a single
  Gitleaks fingerprint, a prose line about password hashing in an archived planning document (commit
  `3006cae`, rule `generic-api-key`). It is a false positive on the full-history scan of `main`; the
  file, the commit and every other rule stay scanned. No other repository has an exclusion.
- **Protection changes need repository administration rights** and were applied only after the
  published check names were confirmed. Where GitHub or the tooling denies a change, it is left to
  an administrator rather than worked around.
- **Newly required checks apply to existing branches.** A branch cut before a consumer adopted
  `gates.yml` has no `Secret scan / scan` run and stays blocked until it is updated from `main`.
- Administrators are not exempt in Automation's protection (`enforce_admins`), like Frontend.
