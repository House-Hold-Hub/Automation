# Reusable Docker build workflow

`.github/workflows/docker-build.yml` builds a service image from a
**service-owned** Dockerfile. Automation owns only this shared logic
(ADR-009, technology baseline). Releases are triggered by the service
repository, never by Automation.

Out of scope until D02 is resolved: registry login, push, deployment targets,
provider-specific steps. Shared gates (Automation#2) are also not included.

## Usage

See [`examples/service-docker-build.yml`](../examples/service-docker-build.yml).

## Inputs

| Input | Default | Description |
|---|---|---|
| `dockerfile` | `Dockerfile` | Dockerfile path from repo root |
| `context` | `.` | Build context from repo root |
| `image-name` | `service` | Local image name (no registry) |
| `image-tag` | `ci` | Local image tag |
| `target` | _empty_ | Multi-stage target |
| `build-args` | _empty_ | Newline-separated `KEY=VALUE` (no secrets) |
| `ref` | _empty_ | Git ref to build (caller's ref by default) |
| `runs-on` | `ubuntu-latest` | Runner label |
| `timeout-minutes` | `30` | Job timeout |

Output: `image` — the local `name:tag` built. No secrets are required;
permissions are `contents: read`.

## Versioning

Pick the reference that matches the guarantee you need:

| Reference | Mutable? | Use |
|---|---|---|
| `@v1` | **Yes** - moving alias to the latest `v1.x.y` | Convenience; callers may receive new workflow code without changing their repository |
| `@v1.0.0` | No, as long as tags are never retargeted | Pinned release version |
| `@<full 40-char commit SHA>` | No - immutable | **Recommended** for maximum reproducibility and supply-chain safety |

Breaking input changes ship under a new major tag. Tags are cut from `main`
by Automation maintainers after merge.

## Validation

- Syntax: `actionlint` (run in CI via `.github/workflows/lint.yml`).
- Smoke test: `ci.yml` calls the workflow against `tests/fixtures/smoke`.
