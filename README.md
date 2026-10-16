# Automation

Reusable automation and shared pipeline assets for HouseHoldHub
([ADR-009](https://github.com/House-Hold-Hub/Documentation/blob/main/architecture/adr/ADR-009-five-repository-topology.md)).

## Contents

- [Reusable Docker build workflow](docs/docker-build.md)
- [Shared gates: OpenAPI validation, dependency security, secret scanning, required checks](docs/shared-gates.md)
- [Local setup script](#local-setup)

## Local setup

`scripts/setup-local.sh` brings up the whole local stack from a clean machine, using the real
repositories. [Infrastructure](https://github.com/House-Hold-Hub/Infrastructure)'s `compose.yaml` is the
only definition of the stack; the script copies and redefines nothing.

```bash
git clone https://github.com/House-Hold-Hub/Automation.git
Automation/scripts/setup-local.sh
```

**Prerequisites:** `git`, `curl`, and Docker with the Compose v2 plugin and a running daemon. Port 8080
on 127.0.0.1 must be free. Network access to GitHub (clones) and the image registries (first build).
bash 3.2 (macOS) is enough.

**What it does** (each step is safe to repeat):

1. Clones `Infrastructure`, `Backend` and `Frontend` next to `Automation` when missing, the layout
   Compose needs (`../Backend`, `../Frontend`). An existing checkout is kept as it is: no fetch, pull or
   branch change. A non-git directory in the way is refused, never overwritten.
2. Creates `Infrastructure/.env` (mode 600) from `.env.example` with generated `POSTGRES_PASSWORD` and
   `DJANGO_SECRET_KEY`, only when `.env` does not exist. An existing `.env` is validated (required
   variables present, `docker compose config` accepts it) and never modified. Secrets are never printed.
   If `.env` is missing but the `householdhub_pgdata` volume exists, it stops: a new password would not
   match the one stored in the volume. If `docker volume ls` itself fails, it stops too (exit 3) and creates no
   `.env`; an empty result is the only thing treated as "no volume".
3. Runs `docker compose up -d --build` in `Infrastructure/`.
4. Verifies: PostgreSQL healthy; the `migrate` job exited 0 and `manage.py migrate --check` reports
   nothing pending; the Backend healthcheck; `http://127.0.0.1:8080/api/v1/` returns a
   response that demonstrably comes from Django through nginx (status below 500, Django's security headers
   `X-Frame-Options` / `Cross-Origin-Opener-Policy`, and not the SPA shell): the Backend has no health route and the
   API is still empty, so a Django 404 is the expected answer, while the Frontend's own SPA fallback or 404 is rejected;
   the Frontend container is running and `http://127.0.0.1:8080/` serves the SPA.

It never runs `down`, removes images or deletes volumes, so the PostgreSQL data survives every run. After
a failure the stack is left running for inspection, with the logs of the failing services printed.

```text
scripts/setup-local.sh [--workspace DIR] [--timeout SECONDS]
```

| Option / variable | Meaning |
|---|---|
| `--workspace DIR`, `HHH_WORKSPACE` | Directory holding the sibling repositories (default: parent of Automation). Required from a `.claude/worktrees/*` checkout |
| `--timeout SECONDS` | Wait for each service to become healthy (default 180) |
| `HHH_REPO_BASE_URL` | Clone source (default `https://github.com/House-Hold-Hub`) |
| `HHH_APP_URL` | Origin to verify (default `http://127.0.0.1:8080`, the port `compose.yaml` publishes) |

| Exit code | Meaning |
|---|---|
| 0 | Stack ready |
| 2 | Usage error |
| 3 | Missing prerequisite (git, curl, docker, Compose v2, running daemon), or Docker failed while looking up the PostgreSQL volume |
| 4 | Clone failed, or a checkout is incomplete or not a git repository |
| 5 | Invalid configuration (`.env`, Compose, worktree path, orphan database volume) |
| 6 | `docker compose up` failed (build, port in use, migration failure) |
| 7 | Stack started but a verification failed |

Tests: `tests/scripts/setup-local.test.sh` runs the script against stub `git`, `docker` and `curl`
(no network, no containers). Verified end to end on 2026-10-16 against the repositories' `main`
(Docker 29.8, Compose 5.6): clean clone and start, repeat run, recovery from a stopped Backend, and a failure
with a wrong database password (exit 6, logs shown).
