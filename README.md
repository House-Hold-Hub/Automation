# HouseHoldHub Automation

Reusable automation assets shared by the HouseHoldHub service repositories.

Repository ownership follows the canonical five-repository topology: service repositories own their Dockerfiles, tests, dependency manifests, and service-local workflow entry points, while this repository owns reusable automation and policy assets consumed by those workflows.

## Reusable service-image build

`.github/workflows/build-service-image.yml` is a callable GitHub Actions workflow. It has only a `workflow_call` trigger, so a Backend or Frontend workflow remains the entry point that decides when to build or release a service.

The reusable workflow checks out the **calling service repository** and builds the Dockerfile owned by that repository. It does not publish an image, select a container registry, deploy a service, or name a managed provider.

### Inputs

| Input | Required | Default | Purpose |
| --- | --- | --- | --- |
| `build_context` | No | `.` | Docker build context in the calling service repository |
| `dockerfile` | No | `Dockerfile` | Path to the service-owned Dockerfile |
| `image_tag` | No | `householdhub-service:ci` | Local image tag used for build validation |

### Caller example

Add a repository-local workflow in the service repository and call the shared asset from there:

```yaml
name: Service CI

on:
  pull_request:
  push:
    branches:
      - main

jobs:
  build:
    uses: House-Hold-Hub/Automation/.github/workflows/build-service-image.yml@<reviewed-ref>
    with:
      build_context: .
      dockerfile: Dockerfile
      image_tag: householdhub-service:${{ github.sha }}
```

Replace `<reviewed-ref>` with the Automation commit SHA or tag approved by the service repository.

Publishing to a registry and deployment/release execution deliberately remain outside this reusable workflow. Those choices stay with the service repository and the deferred D02 decision before M9.

## Shared pull-request gates

Automation provides reusable gate implementations while each service repository remains responsible for its own test commands and service-local workflow.

| Workflow | Purpose |
| --- | --- |
| `.github/workflows/validate-contract.yml` | Validate the reviewed Documentation-owned OpenAPI contract with the canonical Redocly checks |
| `.github/workflows/dependency-security.yml` | Reject pull requests that introduce dependency vulnerabilities |
| `.github/workflows/secret-scan.yml` | Scan every commit introduced by the pull request for hard-coded secrets |

The dependency and secret gates intentionally require a `pull_request` caller. They are merge gates, not release or deployment workflows.

The dependency gate disables license-policy enforcement because license governance is outside issue #2; it performs vulnerability review only. The secret gate runs the pinned Gitleaks CLI directly, with checksum verification, so organization repositories do not depend on the separately licensed Gitleaks GitHub Action.

### Consumer workflow example

The service repository owns the `tests` job and calls the shared gates:

```yaml
name: Service CI

on:
  pull_request:

permissions:
  contents: read

jobs:
  tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      # Service-owned setup and test commands go here.

  contract:
    uses: House-Hold-Hub/Automation/.github/workflows/validate-contract.yml@<reviewed-automation-ref>
    with:
      documentation_ref: <reviewed-documentation-ref>

  dependency-security:
    uses: House-Hold-Hub/Automation/.github/workflows/dependency-security.yml@<reviewed-automation-ref>

  secret-scan:
    uses: House-Hold-Hub/Automation/.github/workflows/secret-scan.yml@<reviewed-automation-ref>
```

Use reviewed commit SHAs or tags for both Automation and Documentation. The canonical OpenAPI workflow requires an explicit Documentation ref so an unrelated change to `Documentation/main` cannot silently change a service PR's contract gate.

Automation does **not** define the service test command, generated-client compatibility command, or repository-local lint/type checks. Those remain owned by each implementation manifest and service workflow.

## Branch protection

Merge enforcement is a repository setting, not a reusable workflow. Configure each service repository's protected `main` branch only after its pull-request workflow has emitted the relevant checks.

The branch protection procedure is documented in [`docs/branch-protection.md`](docs/branch-protection.md). It deliberately selects the checks currently emitted by each service workflow instead of hard-coding status-check names in this repository.

## Canonical references

- [ADR-009: Five-repository topology](https://github.com/House-Hold-Hub/Documentation/blob/main/architecture/adr/ADR-009-five-repository-topology.md)
- [ADR-014: API contract governance](https://github.com/House-Hold-Hub/Documentation/blob/main/architecture/adr/ADR-014-api-contract-governance.md)
- [Testing strategy](https://github.com/House-Hold-Hub/Documentation/blob/main/quality/testing-strategy.md)
- [Security model](https://github.com/House-Hold-Hub/Documentation/blob/main/security/security-model.md)
- [MVP implementation plan](https://github.com/House-Hold-Hub/Documentation/blob/main/planning/mvp-implementation-plan.md)
