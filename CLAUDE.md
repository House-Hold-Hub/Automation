# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Automation is one of the five HouseHoldHub repositories (Backend, Frontend, Infrastructure,
Automation, Documentation: ADR-009). It contains no application code. It publishes reusable GitHub
Actions workflows (`on: workflow_call`) that the other repositories call from their own workflows,
plus a branch-protection script. Automation owns only the shared logic: the calling workflow and
its triggers, the Dockerfile, the decision to require a check and the OpenAPI specification (owned
by Documentation) stay with the consuming repository. Nothing here runs on behalf of another
repository.

The decisions these workflows implement live in the Documentation repository (`../Documentation`
when cloned alongside): ADR-009, ADR-014 (API contract governance), `quality/testing-strategy.md`,
`security/security-model.md`. Live GitHub issues, not Markdown, are authoritative for execution
state.

## Commands

Every tool runs from the image or exact version pinned in the workflows, and the commands below
read that pin from the workflow file so they cannot drift from CI. Locally you need Docker, `jq`
and Node/npx.

```bash
# Workflow lint (required check `actionlint`). The image bundles shellcheck, which actionlint runs on `run:` blocks.
docker run --rm -v "$PWD:/repo:ro" -w /repo "$(grep -o 'rhysd/actionlint:[^ ]*' .github/workflows/lint.yml)" -color

# Shellcheck the standalone scripts (CI does not)
docker run --rm -v "$PWD:/repo:ro" -w /repo --entrypoint shellcheck \
  "$(grep -o 'rhysd/actionlint:[^ ]*' .github/workflows/lint.yml)" scripts/*.sh tests/scripts/*.sh

# Tests for scripts/set-required-checks.sh (required check `Test set-required-checks script`): stubbed gh, no network
tests/scripts/set-required-checks.test.sh

# Tests for scripts/setup-local.sh (CI job `Test setup-local script`, not a required check): stubbed git, docker, curl
tests/scripts/setup-local.test.sh
```

The gate self-tests run only in GitHub Actions (`gates.yml`). To reproduce one locally, run the
scanner the way the workflow does; exit 0 is a pass, non-zero a finding:

```bash
# Secret scan, tree mode: fixtures clean / leaked expect 0 / 1
docker run --rm -v "$PWD:/repo:ro" \
  "$(grep -o 'ghcr.io/gitleaks/gitleaks@sha256:[0-9a-f]*' .github/workflows/secret-scan.yml)" \
  dir /repo/tests/fixtures/secret-scan/leaked --config /repo/tests/fixtures/secret-scan/gitleaks.toml \
  --redact --verbose --no-banner

# Secret scan, history mode with default rules: what `Secret scan / scan` runs on this repository's pull requests
docker run --rm -v "$PWD:/repo:ro" -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/repo \
  "$(grep -o 'ghcr.io/gitleaks/gitleaks@sha256:[0-9a-f]*' .github/workflows/secret-scan.yml)" \
  git /repo --log-opts "origin/main..HEAD" --redact --verbose --no-banner

# Dependency security (queries the OSV database): clean-npm expects 0, vulnerable-npm and vulnerable-python expect 1
docker run --rm -v "$PWD:/src:ro" -w /src \
  "$(grep -o 'ghcr.io/google/osv-scanner@sha256:[0-9a-f]*' .github/workflows/dependency-security.yml)" \
  scan source --lockfile tests/fixtures/dependencies/vulnerable-npm/package-lock.json

# OpenAPI with Redocly's built-in rules (the self-tests pass config-path ""): valid expects 0, invalid-* expect 1
v=$(sed -n '/redocly-version:/,/default:/s/.*default: //p' .github/workflows/openapi-validate.yml)
npm_config_ignore_scripts=true npx --yes "@redocly/cli@$v" lint tests/fixtures/openapi/invalid-contract.yaml

# Smoke build, as ci.yml calls docker-build.yml
docker build --file tests/fixtures/smoke/Dockerfile --tag automation-smoke:ci --build-arg GREETING=smoke tests/fixtures/smoke
```

## Architecture

### Two kinds of workflow in `.github/workflows/`

- **Reusable, called by other repositories:** `docker-build.yml`, `secret-scan.yml`,
  `dependency-security.yml`, `openapi-validate.yml`.
- **Automation's own CI**, which calls the reusable ones through local `uses: ./.github/workflows/…`,
  so a change is exercised here before any consumer picks it up: `lint.yml` (actionlint), `ci.yml`
  (smoke build of `tests/fixtures/smoke`, script tests) and `gates.yml` (this repository's real
  secret scan plus the self-tests; Automation has no OpenAPI document or lockfile, so those two
  gates only ever run against fixtures here).

`examples/` holds the caller workflows consumers copy. `docs/` is the consumer reference (inputs,
versioning, adoption state); keep its input tables in step with the workflows.

### Gate self-tests

Each gate takes `report-only`: the scan step becomes `continue-on-error`, so the job succeeds and
the scan's real result comes out as the `outcome` output. `gates.yml` calls each gate on a positive
fixture (blocking) and on negative fixtures (report-only). The aggregate job `Gate self-tests` reads
`toJSON(needs)` and asserts that every job succeeded with the expected outcome, so a gate that stops
detecting its negative fixture turns it red. It runs with `if: always()` and checks results itself
because a skipped required check counts as passed. To add a case: add the job, list it under
`selftest.needs`, add a `check <job-id> <expected-outcome>` line. Only `Gate self-tests` is
required, not the individual `Self-test …` jobs.

### Check names are an interface

GitHub publishes check-run names, not workflow names: a plain job publishes its `name:`, a job that
calls a reusable workflow publishes `<caller job name> / <called job name>`. Consumers require
`Secret scan / scan`, `Dependency security / scan` and `OpenAPI / validate`, so the job names inside
the reusable workflows (`scan`, `validate`, `build`) are part of their contract. Automation's `main`
requires `actionlint`, `Smoke test reusable docker-build / build`, `Secret scan / scan`,
`Gate self-tests` and `Test set-required-checks script`. Renaming any of these jobs silently drops
the protection: update branch protection in the same change. Never add `paths:` filters to a
workflow whose jobs are required: a required check skipped that way stays pending and blocks every
other pull request.

### Versioning and propagation

Consumers pin the reusable workflows by full commit SHA (the current pin is recorded in
`docs/shared-gates.md`), so a merged change reaches a consumer only when that repository bumps its
pin. `vX.Y.Z` tags and the moving `v1` alias are cut from `main` by maintainers after merge, and
breaking input changes need a new major (`docs/docker-build.md#versioning`). A tag contains only
what existed when it was cut: check with `git ls-tree -r --name-only <tag> -- .github/workflows`
before referencing one.

## Conventions for reusable workflows

- `permissions: {}` at the top and `contents: read` on the job. No secrets as inputs; scanner
  containers get no token and mount the checkout read-only.
- Actions pinned by full commit SHA with a `# vX.Y.Z` comment, images by `@sha256:` digest with the
  version alongside, Redocly by exact version (no ranges). Nothing updates the pins automatically:
  bump them by hand, every occurrence at once (`grep -rn 'actions/checkout@' .github/workflows`).
- `actions/checkout` with `ref: ${{ inputs.ref }}` and `persist-credentials: false`.
- Inputs and event data reach `run:` scripts only through `env:`, never as `${{ … }}` in the script
  body. Scripts start with `set -euo pipefail`, build an args array, and parse newline-separated
  inputs with `while IFS= read -r line || [ -n "$line" ]`.
- Shared inputs: `ref`, `runs-on`, `timeout-minutes`; each gate also takes `report-only` and
  exposes `outcome`.
- `docker-build.yml` never logs in to a registry, pushes or deploys: registry and deployment targets
  wait for decision gate D02.
- Checks that belong to a consumer (Backend/Frontend lint, type check, tests, contract drift) are
  not duplicated here, and there is no coverage threshold.

## Fixtures

- The leaked secret-scan fixture is a synthetic marker matched only by the test rule in
  `tests/fixtures/secret-scan/gitleaks.toml`. This repository's own `Secret scan / scan` runs
  Gitleaks' default rules over every commit a pull request adds, so a realistic-looking credential
  in any commit (fixtures included) fails CI, and deleting it in a later commit is not enough: the
  commit must be rewritten. Run the history-mode scan above before pushing.
- Dependency fixtures depend on the live OSV database. `lodash` 4.17.15 and `requests` 2.19.0 stay
  vulnerable; `is-number` 7.0.0 is expected clean and must be replaced if an advisory is ever
  published for it (`Self-test dependencies clean` would turn red with no change here).
- `invalid-reference.yaml` fails at `redocly bundle`, which the workflow runs before `lint` and which
  catches an unresolved `$ref` whatever the lint configuration; `invalid-contract.yaml` bundles but
  fails `lint`.

## Branch protection script

`scripts/set-required-checks.sh OWNER/REPO [--apply] CHECK...` adds required checks to the default
branch's protection and binds them to GitHub Actions (`app_id` 15368). Without `--apply` it is a dry
run; it is idempotent and only PATCHes the required-checks list of existing protection. It creates
the baseline protection only after GitHub answers 404 "Branch not protected", aborts on any other
API error (exit 4) and refuses repositories with an active branch ruleset (exit 3; Documentation's
"Protect main" ruleset is edited directly). `GH` overrides the `gh` binary, which is how the tests
inject a stub whose answers `STUB_PROTECTION` selects; a behaviour change needs a case there. The
script is run locally by an administrator, and macOS ships bash 3.2 as `/bin/bash`: avoid bash 4+
features (`mapfile`, associative arrays, `${var,,}`) and keep both scripts passing under 3.2.

`--apply` changes live settings of an organisation repository and needs admin rights. Confirm a
check's published name from a real pull-request run before requiring it:

```bash
gh api repos/House-Hold-Hub/<repo>/commits/<sha>/check-runs -q '.check_runs[] | .name'
```

Enabling GitHub-native security features, or a protection change that GitHub refuses, is left to an
administrator, not worked around.

## Local setup script

`scripts/setup-local.sh` clones Infrastructure/Backend/Frontend as siblings, creates `Infrastructure/.env`
from `.env.example` (only when absent, mode 600, generated secrets), runs `docker compose up -d --build`
from Infrastructure's `compose.yaml` and verifies db, migrations, Backend and Frontend (exit codes 2-7,
see README "Local setup"). It must stay non-destructive: no `down`, `rm`, `prune` or volume removal, no
change to existing checkouts or `.env`, no secret in output (the tests assert this). It reads, never
copies, Infrastructure's definitions, so a change to service names, healthchecks or the published port in
`compose.yaml` needs a matching change in `service_ok`/`verify_stack`/`HHH_APP_URL`. `GIT`, `DOCKER`
and `CURL` inject the stubs; a behaviour change needs a case in the test. Keep bash 3.2 compatibility.
Real-stack check: `scripts/setup-local.sh --workspace <empty dir>`.

## Docs and git workflow

- `docs/shared-gates.md` records cross-repository state (adoption, required checks, native security
  settings) as dated facts read from GitHub. Re-read the live state with `gh api` before updating it.
- Branches are `<type>/<issue>-<slug>` (`feature/`, `docs/`; `scratch/` for throwaway pull requests,
  closed unmerged, that prove a failing gate blocks a merge). Conventional Commit subjects,
  `Refs #<issue>` in the body, pull requests into `main`.
