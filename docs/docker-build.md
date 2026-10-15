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

Callers reference the workflow by an immutable release tag, e.g.
`@v1` (moving major tag) or `@v1.0.0`; pinning to a full commit SHA is the
strictest option. Breaking input changes ship under a new major tag.
Tags are cut from `main` by Automation maintainers after merge.

## Validation

- Syntax: `actionlint` (run in CI via `.github/workflows/lint.yml`).
- Smoke test: `ci.yml` calls the workflow against `tests/fixtures/smoke`.
