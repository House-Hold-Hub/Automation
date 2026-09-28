# HouseHoldHub Automation

Reusable automation assets shared by the HouseHoldHub service repositories.

Repository ownership follows the canonical five-repository topology: service repositories own their Dockerfiles and service-local workflow entry points, while this repository owns reusable automation assets consumed by those workflows.

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

## Canonical references

- [ADR-009: Five-repository topology](https://github.com/House-Hold-Hub/Documentation/blob/main/architecture/adr/ADR-009-five-repository-topology.md)
- [Technology baseline](https://github.com/House-Hold-Hub/Documentation/blob/main/architecture/technology-baseline.md)
- [MVP implementation plan](https://github.com/House-Hold-Hub/Documentation/blob/main/planning/mvp-implementation-plan.md)
