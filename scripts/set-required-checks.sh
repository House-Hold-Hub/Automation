#!/usr/bin/env bash
# Add required status checks to the default-branch protection of a HouseHoldHub repository.
#
#   scripts/set-required-checks.sh OWNER/REPO [--apply] CHECK [CHECK...]
#
# CHECK is the check-run name GitHub Actions publishes (the job name, or "caller job / called
# job" for a reusable workflow). Look names up first, see docs/shared-gates.md; the script does
# not invent them. Without --apply it only prints what it would change.
#
# - Existing protection is preserved: only the required-checks list is extended (union).
# - Repositories protected by a ruleset are not touched; edit the ruleset instead.
# - A repository without protection gets the baseline already used by Frontend: pull request
#   required (0 approvals), required checks bound to GitHub Actions, enforced for admins, no
#   force-push, no deletion.
set -euo pipefail

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ "$#" -ge 2 ] || usage
repo=$1; shift
apply=false
if [ "${1:-}" = "--apply" ]; then apply=true; shift; fi
[ "$#" -ge 1 ] || usage
requested=("$@")

github_actions_app_id=15368
branch=$(gh api "repos/$repo" -q .default_branch)

rulesets=$(gh api "repos/$repo/rulesets" -q 'map(select(.enforcement=="active" and .target=="branch")) | length')
if [ "$rulesets" -gt 0 ]; then
  echo "$repo is protected by $rulesets active branch ruleset(s); not touching it. Add the checks to the ruleset." >&2
  exit 3
fi

wanted=$(printf '%s\n' "${requested[@]}" | jq -R . | jq -s 'map({context: ., app_id: '"$github_actions_app_id"'})')

if current=$(gh api "repos/$repo/branches/$branch/protection" 2>/dev/null); then
  existing=$(jq '.required_status_checks.checks // []' <<< "$current")
  strict=$(jq '.required_status_checks.strict // false' <<< "$current")
  merged=$(jq -n --argjson a "$existing" --argjson b "$wanted" '($a + $b) | unique_by(.context)')
  echo "$repo@$branch: protection exists; required checks become:"
  jq -r '.[].context' <<< "$merged" | sed 's/^/  - /'
  if $apply; then
    gh api -X PATCH "repos/$repo/branches/$branch/protection/required_status_checks" \
      --input - <<< "$(jq -n --argjson c "$merged" --argjson s "$strict" '{strict: $s, checks: $c}')" >/dev/null
    echo "applied."
  fi
else
  echo "$repo@$branch: no protection; baseline would be created with required checks:"
  jq -r '.[].context' <<< "$wanted" | sed 's/^/  - /'
  if $apply; then
    gh api -X PUT "repos/$repo/branches/$branch/protection" --input - >/dev/null <<< "$(jq -n --argjson c "$wanted" '{
      required_status_checks: {strict: false, checks: $c},
      enforce_admins: true,
      required_pull_request_reviews: {required_approving_review_count: 0},
      restrictions: null,
      allow_force_pushes: false,
      allow_deletions: false
    }')"
    echo "applied."
  fi
fi
