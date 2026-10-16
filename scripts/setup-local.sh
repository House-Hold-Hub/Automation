#!/usr/bin/env bash
# Set up and start the HouseHoldHub local stack (Automation#3, ADR-009).
#
#   scripts/setup-local.sh [--workspace DIR] [--timeout SECONDS]
#
# What it does, in order. Every step is safe to repeat:
#   1. checks prerequisites (git, curl, Docker with Compose v2 and a running daemon);
#   2. clones Infrastructure, Backend and Frontend as siblings of Automation when missing
#      (compose.yaml builds from ../Backend and ../Frontend); existing checkouts are never touched;
#   3. creates Infrastructure/.env from .env.example with freshly generated secrets, only when
#      .env is absent; an existing .env is validated and never modified;
#   4. starts the stack with `docker compose up -d --build` from Infrastructure/compose.yaml,
#      the single definition of the stack (nothing is copied or redefined here);
#   5. verifies PostgreSQL, the migrations, the Backend and the Frontend through the healthchecks
#      Compose defines and the endpoints the stack serves.
#
# It never deletes containers, images or volumes (`pgdata` included), never prints secret values
# and never edits another repository's files.
#
# Options and environment:
#   --workspace DIR    directory holding the sibling repositories (default: parent of Automation;
#                      HHH_WORKSPACE). Required when run from a .claude/worktrees checkout.
#   --timeout SECONDS  how long to wait for the services to become healthy (default 180).
#   HHH_REPO_BASE_URL  where to clone from (default https://github.com/House-Hold-Hub).
#   HHH_APP_URL        origin the stack is served on (default http://127.0.0.1:8080, the port
#                      published by compose.yaml).
#   GIT, DOCKER, CURL  override the executables (the regression tests inject stubs).
#
# Exit codes: 0 ready; 2 usage; 3 missing prerequisite or Docker unusable; 4 checkout problem; 5 invalid configuration;
# 6 the stack failed to start; 7 the stack started but a service failed verification.
#
# Compatible with bash 3.2 (macOS /bin/bash): no mapfile, associative arrays or ${var,,}.
set -euo pipefail

git_bin=${GIT:-git}
docker_bin=${DOCKER:-docker}
curl_bin=${CURL:-curl}
base_url=${HHH_REPO_BASE_URL:-https://github.com/House-Hold-Hub}
app_url=${HHH_APP_URL:-http://127.0.0.1:8080}
# Compose project name (compose.yaml `name:`), used only to recognise an existing database volume.
project=householdhub
repos=(Infrastructure Backend Frontend)
required_vars=(POSTGRES_PASSWORD DJANGO_SECRET_KEY)

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
say() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { # exit code, message...
  local code=$1; shift
  printf 'error: %s\n' "$*" >&2
  exit "$code"
}

workspace=${HHH_WORKSPACE:-}
timeout=180
while [ "$#" -gt 0 ]; do
  case $1 in
    --workspace) [ "$#" -ge 2 ] || usage; workspace=$2; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || usage; timeout=$2; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done
case $timeout in ''|*[!0-9]*) die 2 "--timeout must be a number of seconds, got '$timeout'" ;; esac

# ---------------------------------------------------------------- workspace
automation_root=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "$workspace" ]; then
  case $automation_root in
    */.claude/worktrees/*)
      die 5 "running from a worktree ($automation_root): the sibling paths ../Infrastructure would not resolve. Run from the main checkout or pass --workspace DIR." ;;
  esac
  workspace=$(dirname "$automation_root")
fi
mkdir -p "$workspace" || die 4 "cannot create workspace directory $workspace"
workspace=$(cd "$workspace" && pwd)
infra=$workspace/Infrastructure

# ---------------------------------------------------------------- prerequisites
check_prerequisites() {
  local missing=0
  command -v "$git_bin" >/dev/null 2>&1 || { printf 'error: git is not installed (https://git-scm.com/downloads)\n' >&2; missing=1; }
  command -v "$curl_bin" >/dev/null 2>&1 || { printf 'error: curl is not installed\n' >&2; missing=1; }
  if ! command -v "$docker_bin" >/dev/null 2>&1; then
    printf 'error: docker is not installed (https://docs.docker.com/get-docker/)\n' >&2
    missing=1
  else
    if ! "$docker_bin" compose version >/dev/null 2>&1; then
      printf 'error: the Docker Compose v2 plugin is missing ("docker compose version" fails); docker-compose v1 is not supported\n' >&2
      missing=1
    fi
    if ! "$docker_bin" info >/dev/null 2>&1; then
      printf 'error: the Docker daemon is not reachable; start Docker Desktop/Engine and check that your user may use it ("docker info")\n' >&2
      missing=1
    fi
  fi
  [ "$missing" -eq 0 ] || exit 3
}

# ---------------------------------------------------------------- checkouts
ensure_checkout() { # repo name
  local name=$1 dir=$workspace/$1
  if [ -e "$dir" ] && [ ! -d "$dir" ]; then
    die 4 "$dir exists and is not a directory"
  fi
  if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    if "$git_bin" -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
      say "$name: existing checkout kept untouched ($(
        "$git_bin" -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached))"
      return 0
    fi
    die 4 "$dir exists but is not a git checkout; move it away or fix it, this script does not overwrite it"
  fi
  say "$name: cloning $base_url/$name.git"
  if ! GIT_TERMINAL_PROMPT=0 "$git_bin" clone --quiet "$base_url/$name.git" "$dir"; then
    die 4 "cloning $base_url/$name.git into $dir failed. Check the network, that the repository exists and that you may read it (private repositories need 'gh auth login' or a credential helper). Re-run the script once fixed."
  fi
}

verify_layout() {
  local missing=0 f
  for f in Infrastructure/compose.yaml Infrastructure/.env.example Infrastructure/nginx/default.conf Backend/Dockerfile Frontend/Dockerfile; do
    if [ ! -f "$workspace/$f" ]; then
      printf 'error: %s is missing\n' "$workspace/$f" >&2
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    die 4 "a checkout is incomplete, most likely on an old branch. Check out main in that repository (git -C <repo> switch main && git -C <repo> pull --ff-only); this script does not change existing checkouts."
  fi
}

# ---------------------------------------------------------------- .env
env_value() { # file key: last KEY=value line, quotes and CR stripped
  awk -v k="$2" '
    index($0, k "=") == 1 { v = substr($0, length(k) + 2); found = 1 }
    END { if (found) { sub(/\r$/, "", v); gsub(/^["\x27]|["\x27]$/, "", v); print v } }' "$1"
}

random_hex() { # bytes
  head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# Looks up the PostgreSQL volumes of the project into $volumes_out (called in the current shell, not
# in a subshell, so the globals survive). A successful query with no result (status 0, empty
# $volumes_out) means "no volume"; a failed query returns non-zero with its diagnostic in $volume_err,
# so callers can tell the two apart and fail closed.
volumes_out=
volume_err=
existing_volume() {
  local errf rc=0
  errf=$(mktemp) || return 1
  volumes_out=$("$docker_bin" volume ls -q \
    --filter "label=com.docker.compose.project=$project" \
    --filter "label=com.docker.compose.volume=pgdata" 2>"$errf") || rc=$?
  volume_err=$(cat "$errf")
  rm -f "$errf"
  return "$rc"
}

create_env() {
  local env=$infra/.env example=$infra/.env.example tmp
  if ! existing_volume; then
    printf '%s\n' "$volume_err" >&2
    die 3 "could not list Docker volumes ('docker volume ls' failed, see above), so it is unknown whether a PostgreSQL volume of project '$project' already exists. No .env was created: a generated password could lock you out of an existing database. Fix Docker access and re-run."
  fi
  if [ -n "$volumes_out" ]; then
    die 5 "no $env, but a PostgreSQL volume of project '$project' already exists. A new random password would not match the one stored in that volume and the Backend could not log in. Restore your previous .env (cp it into Infrastructure/), or, if the data is disposable, remove the volume yourself with 'docker volume rm' (this script never deletes volumes)."
  fi
  say "creating Infrastructure/.env from .env.example with generated secrets"
  tmp=$(umask 077 && mktemp "$infra/.env.XXXXXX") || die 5 "cannot write in $infra"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT
  # Only the documented placeholders are replaced; the secrets travel through the environment, not argv.
  HHH_PW=$(random_hex 24) HHH_KEY=$(random_hex 48) awk '
    /^POSTGRES_PASSWORD=change-me/ { print "POSTGRES_PASSWORD=" ENVIRON["HHH_PW"]; next }
    /^DJANGO_SECRET_KEY=change-me/ { print "DJANGO_SECRET_KEY=" ENVIRON["HHH_KEY"]; next }
    { print }' "$example" > "$tmp"
  chmod 600 "$tmp"
  # mv -n never replaces a .env created in the meantime.
  mv -n "$tmp" "$env"
  if [ -e "$tmp" ]; then
    rm -f "$tmp"
    warn ".env appeared while it was being created; keeping the existing file"
  fi
  trap - EXIT
}

validate_env() {
  local env=$infra/.env var value bad=0
  for var in "${required_vars[@]}"; do
    value=$(env_value "$env" "$var")
    if [ -z "$value" ]; then
      printf 'error: %s is missing or empty in %s\n' "$var" "$env" >&2
      bad=1
    else
      case $value in
        change-me*) warn "$var in Infrastructure/.env is still the public placeholder from .env.example; replace it (it is not changed automatically because the PostgreSQL volume keeps the original password, see Infrastructure/README.md 'Rotate the PostgreSQL password')" ;;
      esac
    fi
  done
  [ "$bad" -eq 0 ] || die 5 "Infrastructure/.env is invalid (see .env.example for the required variables). It was not modified."
  local out
  if ! out=$(cd "$infra" && "$docker_bin" compose config -q 2>&1); then
    printf '%s\n' "$out" >&2
    die 5 "docker compose rejected the configuration (Infrastructure/compose.yaml with Infrastructure/.env). Fix the problem reported above."
  fi
}

# ---------------------------------------------------------------- start
log_dir=
cleanup_log() { [ -z "$log_dir" ] || rm -rf "$log_dir"; }

compose() { (cd "$infra" && "$docker_bin" compose "$@"); }

start_stack() {
  log_dir=$(mktemp -d)
  trap cleanup_log EXIT
  say "starting the stack: docker compose up -d --build (first run builds the images and can take minutes)"
  if ! compose up -d --build 2>&1 | tee "$log_dir/up.log"; then
    diagnose_start "$log_dir/up.log"
    exit 6
  fi
}

diagnose_start() { # log file
  local log=$1
  printf 'error: docker compose up failed.\n' >&2
  if grep -Eqi 'port is already allocated|address already in use|ports are not available' "$log"; then
    printf 'hint: port 8080 on 127.0.0.1 is in use by another process or stack. Free it (lsof -i :8080) and re-run.\n' >&2
  fi
  if grep -Eqi 'no space left on device' "$log"; then
    printf 'hint: Docker is out of disk space. Free space (e.g. docker system df) and re-run; this script does not prune anything.\n' >&2
  fi
  if grep -Eqi 'pull access denied|failed to resolve source metadata|TLS handshake|no such host|i/o timeout' "$log"; then
    printf 'hint: an image could not be pulled. Check the network and registry access (Docker Hub, ghcr.io).\n' >&2
  fi
  service_logs
}

service_logs() { # prints recent logs of services that are not healthy
  local svc state health code
  while IFS='|' read -r svc state health code; do
    [ -n "$svc" ] || continue
    if ! service_ok "$svc" "$state" "$health" "$code"; then
      printf -- '--- last log lines of %s (state=%s health=%s exit=%s) ---\n' "$svc" "$state" "${health:--}" "$code" >&2
      compose logs --no-color --tail 30 "$svc" >&2 2>&1 || true
    fi
  done <<EOF
$(compose ps -a --format '{{.Service}}|{{.State}}|{{.Health}}|{{.ExitCode}}' 2>/dev/null || true)
EOF
}

service_ok() { # service state health exitcode
  case $1 in
    migrate) [ "$2" = exited ] && [ "$4" = 0 ] ;;
    db|backend) [ "$2" = running ] && [ "$3" = healthy ] ;;
    *) [ "$2" = running ] && { [ -z "$3" ] || [ "$3" = healthy ]; } ;;
  esac
}

# ---------------------------------------------------------------- verification
status_of() { # service: "state|health|exitcode" from the current ps output
  printf '%s\n' "$ps_out" | awk -F'|' -v s="$1" '$1 == s { print $2 "|" $3 "|" $4; exit }'
}

http_code() { # url -> status code, 000 when unreachable
  "$curl_bin" -sS -o "$log_dir/body" -D "$log_dir/headers" -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || true
}

failures=0
check() { # description, result (0 ok), hint
  if [ "$2" -eq 0 ]; then
    printf '  ok    %s\n' "$1"
  else
    printf '  FAIL  %s\n' "$1" >&2
    [ -z "${3:-}" ] || printf '        %s\n' "$3" >&2
    failures=$((failures + 1))
  fi
}

wait_for() { # command... : retries until timeout, returns the command's last status
  local deadline=$((SECONDS + timeout)) rc
  while :; do
    rc=0; "$@" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    [ "$SECONDS" -lt "$deadline" ] || return "$rc"
    sleep 3
  done
}

service_healthy() { # service
  local st state health code
  ps_out=$(compose ps -a --format '{{.Service}}|{{.State}}|{{.Health}}|{{.ExitCode}}' 2>/dev/null || true)
  st=$(status_of "$1")
  [ -n "$st" ] || return 1
  IFS='|' read -r state health code <<EOF
$st
EOF
  service_ok "$1" "$state" "$health" "$code"
}

app_serves_frontend() {
  [ "$(http_code "$app_url/")" = 200 ] && grep -qi '<html' "$log_dir/body"
}

# The Backend publishes no health route, so the answer itself must prove its origin. Behind a
# working proxy /api/v1/ is Django's own response (404 until routes exist): it carries the security
# headers Django's middleware adds and is not an HTML page of the SPA. If the proxy location is
# missing, the Frontend's nginx answers instead: its SPA fallback (200 with the app shell) or its own
# 404, neither of which has those headers.
app_reaches_backend() {
  local code
  code=$(http_code "$app_url/api/v1/")
  [ "$code" != 000 ] && [ "$code" -lt 500 ] || return 1
  grep -qiE '^(cross-origin-opener-policy|x-frame-options):' "$log_dir/headers" || return 1
  ! grep -q 'id="root"' "$log_dir/body"
}

migrations_applied() {
  compose run --rm --no-deps -T migrate python manage.py migrate --check >"$log_dir/migrate-check.log" 2>&1
}

verify_stack() {
  [ -n "$log_dir" ] || { log_dir=$(mktemp -d); trap cleanup_log EXIT; }
  say "verifying the services (waiting up to ${timeout}s each)"
  local rc

  set +e; wait_for service_healthy db; rc=$?; set -e
  check "PostgreSQL (db) is running and healthy (pg_isready)" "$rc" "see: docker compose logs db (run in Infrastructure/)"

  set +e; wait_for service_healthy migrate; rc=$?; set -e
  check "migration job (migrate) completed successfully" "$rc" "see: docker compose logs migrate (run in Infrastructure/)"
  if [ "$rc" -eq 0 ]; then
    set +e; migrations_applied; rc=$?; set -e
    check "no unapplied migrations (manage.py migrate --check)" "$rc" "$(tail -n 5 "$log_dir/migrate-check.log" 2>/dev/null | tr '\n' ' ')"
  fi

  set +e; wait_for service_healthy backend; rc=$?; set -e
  check "Backend is running and healthy (healthcheck on /api/v1/)" "$rc" "see: docker compose logs backend (run in Infrastructure/)"

  set +e; wait_for app_reaches_backend; rc=$?; set -e
  check "Backend reachable through the same origin: $app_url/api/v1/" "$rc" "no Django response came back through nginx: unreachable, 5xx, or answered by the Frontend itself (SPA page / nginx 404 without Django's security headers). Check Infrastructure/nginx/default.conf is mounted and proxies /api/ to backend:8000"

  set +e; wait_for service_healthy frontend; rc=$?; set -e
  check "Frontend container is running" "$rc" "see: docker compose logs frontend (run in Infrastructure/)"

  set +e; wait_for app_serves_frontend; rc=$?; set -e
  check "Frontend serves the SPA: $app_url/" "$rc" "expected HTTP 200 with an HTML page"

  if [ "$failures" -ne 0 ]; then
    service_logs
    printf 'error: %d check(s) failed. The stack was left running for inspection; nothing was removed.\n' "$failures" >&2
    exit 7
  fi
}

# ---------------------------------------------------------------- main
check_prerequisites
for r in "${repos[@]}"; do ensure_checkout "$r"; done
verify_layout
if [ -e "$infra/.env" ]; then
  say "Infrastructure/.env exists: kept as is"
else
  create_env
fi
validate_env
start_stack
verify_stack
say "ready: $app_url (Infrastructure/.env holds the generated secrets; do not commit it)"
