#!/usr/bin/env bash
# Regression tests for scripts/set-required-checks.sh, run against a stub `gh` (no network).
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
script=$root/scripts/set-required-checks.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Stub behaviour is driven by STUB_PROTECTION: absent | forbidden | server-error | not-found | exists
cat > "$work/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
path=$2
case "$*" in
  *"-X PATCH"*|*"-X PUT"*) cat > "$STUB_LOG.payload"; echo "$*" > "$STUB_LOG.write"; exit 0 ;;
esac
case "$path" in
  */rulesets) echo 0 ;;
  */protection)
    case "$STUB_PROTECTION" in
      absent)       echo "gh: Branch not protected (HTTP 404)" >&2; exit 1 ;;
      not-found)    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      forbidden)    echo "gh: Resource not accessible (HTTP 403)" >&2; exit 1 ;;
      server-error) echo "gh: Server Error (HTTP 502)" >&2; exit 1 ;;
      exists)       cat "$STUB_PROTECTION_JSON" ;;
    esac ;;
  repos/*) echo main ;;
esac
STUB
chmod +x "$work/gh"

failures=0
run() { # name, protection mode, args...; sets $out and $code, clears recorded writes
  local mode=$1; shift
  rm -f "$work"/log*; : > "$work/log"
  set +e
  out=$(GH="$work/gh" STUB_LOG="$work/log" STUB_PROTECTION="$mode" STUB_PROTECTION_JSON="$work/protection.json" \
    "$script" House-Hold-Hub/Test "$@" 2>&1)
  code=$?
  set -e
}
expect() { # description, condition result (0 = ok)
  if [ "$2" -eq 0 ]; then echo "ok    $1"; else echo "FAIL  $1"; echo "        ${out//$'\n'/$'\n'        }"; failures=$((failures + 1)); fi
}
wrote() { [ -e "$work/log.write" ]; }

cat > "$work/protection.json" <<'JSON'
{"required_status_checks":{"strict":true,"checks":[
  {"context":"lint","app_id":15368},
  {"context":"Secret scan / scan","app_id":null},
  {"context":"Gate self-tests","app_id":999}]},
 "required_pull_request_reviews":{"required_approving_review_count":2},
 "enforce_admins":{"enabled":true}}
JSON

# 1. Existing contexts bound to no app or another app are rebound to GitHub Actions (app 15368).
run exists --apply "Secret scan / scan" "Gate self-tests" "new check"
expect "rebinds contexts with null or foreign app_id" "$(wrote && jq -e '
  (.checks | map(select(.context != "lint")) | all(.app_id == 15368)) and
  (.checks | map(.context) | sort) == (["Gate self-tests","Secret scan / scan","lint","new check"] | sort)' \
  "$work/log.payload" >/dev/null && echo 0 || echo 1)"
expect "keeps unrelated required checks and strict setting" "$(jq -e '(.checks | map(select(.context=="lint" and .app_id==15368)) | length) == 1 and .strict == true' "$work/log.payload" >/dev/null && echo 0 || echo 1)"
expect "only the required-checks endpoint is written (other settings untouched)" "$(grep -q 'protection/required_status_checks' "$work/log.write" && ! grep -q -- '-X PUT' "$work/log.write" && echo 0 || echo 1)"

# 2. Dry run writes nothing; an up-to-date list is a no-op (idempotent).
run exists "Secret scan / scan"
expect "dry run does not write" "$(wrote && echo 1 || echo 0)"
run exists --apply lint
expect "already-bound check: no write" "$(wrote && echo 1 || echo 0)"
expect "already-bound check: reports up to date" "$(grep -q 'already up to date' <<< "$out" && echo 0 || echo 1)"

# 3. Protection is created only on a verified 404 "Branch not protected".
run absent
expect "dry run on unprotected repo does not write" "$(wrote && echo 1 || echo 0)"
run absent --apply lint
expect "creates baseline after verified 404" "$(wrote && grep -q -- '-X PUT' "$work/log.write" && jq -e '.required_status_checks.checks[0].app_id == 15368' "$work/log.payload" >/dev/null && echo 0 || echo 1)"

# 4. Any other failure aborts without changes.
for mode in not-found forbidden server-error; do
  run "$mode" --apply lint
  expect "$mode: aborts non-zero, no write" "$([ "$code" -ne 0 ] && ! wrote && echo 0 || echo 1)"
done

if [ "$failures" -ne 0 ]; then echo "$failures failed"; exit 1; fi
echo "all passed"
