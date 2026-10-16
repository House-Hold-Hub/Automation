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
| Documentation | yes | n/a (no lockfile) | yes; can replace its own `openapi-contract.yml`, see below |
| Infrastructure | yes | n/a until a lockfile exists | no |

Reference the workflow by full commit SHA for reproducibility (`@v1` is a moving alias, see
[versioning](docker-build.md#versioning)). Never reference a branch. Do not add `paths:` filters
to a workflow whose jobs you require: a required check skipped by a path filter stays pending and
blocks every other pull request.

Documentation's existing `openapi-contract.yml` already does what `openapi-validate.yml` does
(same Redocly version and rules). It is deliberately left untouched here; switching it to the
reusable workflow is a change in Documentation, and only worthwhile together with dropping its
`paths:` filter so the check can become required.

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
`tests/scripts/set-required-checks.test.sh` (CI job `Test set-required-checks script`, not a
required check) covers these cases against a stubbed `gh`.

```bash
scripts/set-required-checks.sh House-Hold-Hub/Automation --apply \
  "actionlint" "Smoke test reusable docker-build / build" "Secret scan / scan" "Gate self-tests"
```

Baseline for a repository without protection (the one Frontend already uses): pull request
required with 0 approvals, required checks, enforced for administrators, no force-push, no
branch deletion, "require branches to be up to date" off. Nothing about review counts or
coverage is imposed by this issue.

### State found and applied

| Repository | Before | After |
|---|---|---|
| Automation | None | Required: `actionlint`, `Smoke test reusable docker-build / build`, `Secret scan / scan`, `Gate self-tests` |
| Backend | None | Required: `Lint`, `Type check`, `Test`, `Contract drift` (all published by `ci.yml` and `api-contract.yml` on main) |
| Frontend | Required `lint`, `typecheck`, `test`, `build`, `contract-drift`; admins enforced | Unchanged: already correct and matches the published names |
| Documentation | Ruleset "Protect main": PR required, no force-push or deletion, no required checks | Unchanged: `Validate OpenAPI` is path-filtered and cannot be required without blocking unrelated PRs |
| Infrastructure | None | Unchanged: it has no workflows, so there is no check to require |

When Backend, Frontend or the others adopt the shared gates, add the published names
(`Secret scan / scan`, `Dependency security / scan`) to their protection with the script above;
a check that no workflow publishes must not be required.

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
- **Not yet adopted by Backend, Frontend, Documentation, Infrastructure.** Their required-check
  lists contain only checks that exist today.
- Administrators are not exempt in Automation's protection (`enforce_admins`), like Frontend.
