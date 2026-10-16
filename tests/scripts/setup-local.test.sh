#!/usr/bin/env bash
# Regression tests for scripts/setup-local.sh, run against stub git, docker and curl (no network,
# no containers). The real stack is exercised by hand, see README "Local setup".
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
script=$root/scripts/setup-local.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

# git stub: `clone` creates the files compose needs unless STUB_CLONE_FAIL is set.
cat > "$work/bin/git" <<'STUB'
#!/usr/bin/env bash
echo "git $*" >> "$STUB_LOG"
if [ "$1" = clone ]; then
  [ -z "${STUB_CLONE_FAIL:-}" ] || { echo "fatal: unable to access '$3'" >&2; exit 128; }
  url=$3; dir=$4; name=$(basename "$url" .git)
  mkdir -p "$dir/.git" "$dir/nginx"
  case $name in
    Infrastructure)
      echo "services: {}" > "$dir/compose.yaml"
      echo "x" > "$dir/nginx/default.conf"
      cp "$STUB_ENV_EXAMPLE" "$dir/.env.example" ;;
    *) echo "FROM scratch" > "$dir/Dockerfile" ;;
  esac
  exit 0
fi
if [ "$1" = -C ]; then
  case $3 in
    rev-parse) case $4 in --git-dir) [ -e "$2/.git" ] ;; *) echo main ;; esac ;;
  esac
  exit
fi
STUB

# docker stub, behaviour selected by STUB_* variables.
cat > "$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_LOG"
case "$1" in
  info) [ -z "${STUB_DAEMON_DOWN:-}" ] ;;
  volume) [ -z "${STUB_VOLUME:-}" ] || echo "$STUB_VOLUME" ;;
  compose)
    shift
    case "$1" in
      version) [ -z "${STUB_NO_COMPOSE:-}" ] ;;
      config) [ -z "${STUB_CONFIG_FAIL:-}" ] || { echo "services.backend.environment.X must be set" >&2; exit 1; } ;;
      up) if [ -n "${STUB_UP_FAIL:-}" ]; then echo "Bind for 127.0.0.1:8080 failed: port is already allocated"; exit 1; fi ;;
      ps) printf '%s\n' "db|running|healthy|0" "migrate|exited||0" \
            "backend|${STUB_BACKEND:-running|healthy|0}" "frontend|running||0" ;;
      run) exit "${STUB_MIGRATE_CHECK:-0}" ;;
      logs) echo "stub log line for $*" ;;
    esac ;;
esac
STUB

cat > "$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=; url=
while [ "$#" -gt 0 ]; do
  case $1 in -o) out=$2; shift ;; -w|--max-time) shift ;; -*) ;; *) url=$1 ;; esac
  shift
done
case $url in
  */api/v1/) printf '%s' "x" > "$out"; printf '%s' "${STUB_API_CODE:-404}" ;;
  *) echo '<!doctype html><html></html>' > "$out"; printf '%s' "${STUB_FRONT_CODE:-200}" ;;
esac
STUB
chmod +x "$work/bin/"*

# The template mirrors Infrastructure/.env.example: placeholders that must be replaced.
cat > "$work/env.example" <<'ENV'
POSTGRES_DB=householdhub
POSTGRES_PASSWORD=change-me-local-only
DJANGO_SECRET_KEY=change-me-local-only-generate-your-own
DJANGO_DEBUG=true
ENV

failures=0
ws=
out=
code=0
fresh() { # new empty workspace
  ws=$work/ws.$RANDOM$RANDOM
  mkdir -p "$ws"
  : > "$work/log"
}
run() { # extra env assignments are passed through the environment of the caller
  set +e
  out=$(GIT="$work/bin/git" DOCKER="$work/bin/docker" CURL="$work/bin/curl" HHH_REPO_BASE_URL=https://example.invalid/org \
    STUB_LOG="$work/log" STUB_ENV_EXAMPLE="$work/env.example" "$@" "$script" --workspace "$ws" --timeout 0 2>&1)
  code=$?
  set -e
}
expect() { # description, condition status (0 = ok)
  if [ "$2" -eq 0 ]; then echo "ok    $1"; else echo "FAIL  $1"; echo "        ${out//$'\n'/$'\n'        }"; failures=$((failures + 1)); fi
}
logged() { grep -q -- "$1" "$work/log"; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# 1. Clean first run: clones the three repositories, creates .env, starts and verifies the stack.
fresh
run env
expect "first run succeeds" "$([ "$code" -eq 0 ] && echo 0 || echo 1)"
expect "clones Infrastructure, Backend and Frontend" "$(logged 'clone --quiet https://example.invalid/org/Infrastructure.git' && logged 'org/Backend.git' && logged 'org/Frontend.git' && echo 0 || echo 1)"
expect ".env created with mode 600" "$([ "$(mode "$ws/Infrastructure/.env")" = 600 ] && echo 0 || echo 1)"
expect "placeholders replaced by generated secrets" "$(! grep -q 'change-me' "$ws/Infrastructure/.env" && grep -Eq '^POSTGRES_PASSWORD=[0-9a-f]{48}$' "$ws/Infrastructure/.env" && grep -Eq '^DJANGO_SECRET_KEY=[0-9a-f]{96}$' "$ws/Infrastructure/.env" && echo 0 || echo 1)"
expect "other template lines are preserved" "$(grep -q '^DJANGO_DEBUG=true$' "$ws/Infrastructure/.env" && echo 0 || echo 1)"
pw=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$ws/Infrastructure/.env")
expect "no secret value is printed or logged" "$(! grep -qF "$pw" <<<"$out" && ! grep -qF "$pw" "$work/log" && echo 0 || echo 1)"
expect "starts the stack with up -d --build" "$(logged 'docker compose up -d --build' && echo 0 || echo 1)"
expect "checks migrations" "$(logged 'migrate --check' && echo 0 || echo 1)"
expect "never removes anything" "$(! grep -Eq 'compose (down|rm)|volume (rm|prune)|system prune| -v( |$)' "$work/log" && echo 0 || echo 1)"

# 2. Second run: idempotent, .env and checkouts are untouched, no clone.
sum=$(cksum < "$ws/Infrastructure/.env"); : > "$work/log"
run env
expect "second run succeeds" "$([ "$code" -eq 0 ] && echo 0 || echo 1)"
expect "second run keeps .env byte for byte" "$([ "$(cksum < "$ws/Infrastructure/.env")" = "$sum" ] && echo 0 || echo 1)"
expect "second run does not clone" "$(! logged ' clone ' && echo 0 || echo 1)"

# 3. Existing .env with a missing required variable: refused, file untouched.
fresh; run env >/dev/null
printf 'POSTGRES_DB=custom\nDJANGO_SECRET_KEY=abc\n' > "$ws/Infrastructure/.env"; : > "$work/log"
sum=$(cksum < "$ws/Infrastructure/.env")
run env
expect "invalid .env exits 5 naming the variable" "$([ "$code" -eq 5 ] && grep -q 'POSTGRES_PASSWORD is missing' <<<"$out" && echo 0 || echo 1)"
expect "invalid .env is not modified and nothing is started" "$([ "$(cksum < "$ws/Infrastructure/.env")" = "$sum" ] && ! logged 'compose up' && echo 0 || echo 1)"

# 4. Existing .env still holding placeholders: warned, not rewritten.
printf 'POSTGRES_PASSWORD=change-me-local-only\nDJANGO_SECRET_KEY=real-value\n' > "$ws/Infrastructure/.env"
sum=$(cksum < "$ws/Infrastructure/.env")
run env
expect "placeholder password warns and continues" "$([ "$code" -eq 0 ] && grep -q 'still the public placeholder' <<<"$out" && [ "$(cksum < "$ws/Infrastructure/.env")" = "$sum" ] && echo 0 || echo 1)"

# 5. No .env but a PostgreSQL volume exists: a new password would not match it.
fresh; run env >/dev/null; rm "$ws/Infrastructure/.env"
run env STUB_VOLUME=householdhub_pgdata
expect "existing volume without .env exits 5 and writes no .env" "$([ "$code" -eq 5 ] && [ ! -e "$ws/Infrastructure/.env" ] && grep -q 'never deletes volumes' <<<"$out" && echo 0 || echo 1)"

# 6. Clone failure.
fresh
run env STUB_CLONE_FAIL=1
expect "clone failure exits 4 with a diagnostic" "$([ "$code" -eq 4 ] && grep -q 'cloning .*Infrastructure.git.* failed' <<<"$out" && echo 0 || echo 1)"

# 7. A non-git directory in the way is never overwritten.
fresh; mkdir "$ws/Backend"; echo keep > "$ws/Backend/file"
run env
expect "non-git directory is refused and left intact" "$([ "$code" -eq 4 ] && [ "$(cat "$ws/Backend/file")" = keep ] && echo 0 || echo 1)"

# 8. An incomplete existing checkout is reported, not modified.
fresh; mkdir -p "$ws/Infrastructure/.git"; echo keep > "$ws/Infrastructure/README.md"
run env
expect "incomplete checkout exits 4 naming the missing file" "$([ "$code" -eq 4 ] && grep -q 'compose.yaml is missing' <<<"$out" && ! logged 'git -C .* \(pull\|checkout\|reset\)' && echo 0 || echo 1)"

# 9. Prerequisites.
fresh
run env STUB_DAEMON_DOWN=1
expect "daemon down exits 3" "$([ "$code" -eq 3 ] && grep -q 'daemon is not reachable' <<<"$out" && echo 0 || echo 1)"
run env STUB_NO_COMPOSE=1
expect "missing compose plugin exits 3" "$([ "$code" -eq 3 ] && grep -q 'Compose v2 plugin' <<<"$out" && echo 0 || echo 1)"
set +e
out=$(GIT="$work/bin/git" DOCKER="$work/nonexistent-docker" CURL="$work/bin/curl" "$script" --workspace "$ws" 2>&1); code=$?
set -e
expect "missing docker exits 3" "$([ "$code" -eq 3 ] && grep -q 'docker is not installed' <<<"$out" && echo 0 || echo 1)"

# 10. Compose rejects the configuration.
fresh
run env STUB_CONFIG_FAIL=1
expect "invalid compose configuration exits 5" "$([ "$code" -eq 5 ] && grep -q 'rejected the configuration' <<<"$out" && ! logged 'compose up' && echo 0 || echo 1)"

# 11. Start failure: exit 6 with the port hint.
fresh
run env STUB_UP_FAIL=1
expect "start failure exits 6 with a port hint" "$([ "$code" -eq 6 ] && grep -q 'port 8080' <<<"$out" && echo 0 || echo 1)"

# 12. Verification failures: exit 7, stack left running.
fresh
run env STUB_BACKEND='running|unhealthy|0'
expect "unhealthy Backend exits 7 and shows its logs" "$([ "$code" -eq 7 ] && grep -q 'FAIL  Backend is running and healthy' <<<"$out" && grep -q 'last log lines of backend' <<<"$out" && ! logged 'compose down' && echo 0 || echo 1)"
fresh
run env STUB_API_CODE=502
expect "proxy 502 on /api/v1/ exits 7" "$([ "$code" -eq 7 ] && grep -q 'FAIL  Backend reachable through the same origin' <<<"$out" && echo 0 || echo 1)"
fresh
run env STUB_FRONT_CODE=000
expect "unreachable Frontend exits 7" "$([ "$code" -eq 7 ] && grep -q 'FAIL  Frontend serves the SPA' <<<"$out" && echo 0 || echo 1)"
fresh
run env STUB_MIGRATE_CHECK=1
expect "unapplied migrations exit 7" "$([ "$code" -eq 7 ] && grep -q 'FAIL  no unapplied migrations' <<<"$out" && echo 0 || echo 1)"

# 13. Worktree guard and usage errors.
set +e
out=$("$script" --timeout abc 2>&1); code=$?
set -e
expect "bad --timeout exits 2" "$([ "$code" -eq 2 ] && echo 0 || echo 1)"

if [ "$failures" -ne 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "all passed"
