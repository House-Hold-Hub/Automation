# Branch protection for shared quality gates

The shared workflows in this repository can be selected as required merge checks when the consuming repository protects its target branch. Required status checks block merge when those check contexts fail or are missing, but they do **not** make repository-local workflow definitions immutable. A pull request that can edit its local CI workflow can potentially replace a reusable-workflow call with a different job that reports the same check context. The exact service test/check names stay owned by the service repository.

## Configure `main`

For each Backend or Frontend repository:

1. Ensure the repository-local CI workflow runs on `pull_request`.
2. Ensure that workflow publishes:
   - the service-owned test check or checks;
   - the shared canonical-contract validation check;
   - the shared dependency-security check;
  - the shared secret-scanning check.
3. Run the workflow on at least one pull request so GitHub can discover the current check contexts.
4. In the repository rules for `main`, require a pull request before merge and require status checks to pass.
5. Select the checks emitted by the current service workflow from GitHub's visible status-check list. Do not copy check-context names into Automation policy files.
6. Verify the rule with a pull request that intentionally fails a service test or one shared gate: merge must remain blocked until the failing check passes.

If a service workflow renames or replaces a required check, update that repository's branch rule after the new check has run and is visible. The service workflow remains the source of the check name; this repository owns only the reusable gate implementation and this policy.

## Workflow integrity

Required status checks alone do not prove that the intended shared workflow definition ran. Protecting the gate definition itself requires an independently enforced control outside the pull request's editable workflow, for example an organization ruleset/required workflow or equivalent review protection for workflow-file changes.

This repository documents that requirement but does not configure organization rulesets or cross-repository review enforcement as part of issue #2. Until an independent workflow-integrity control is enabled by repository/organization governance, required check contexts must not be described as making the shared gates tamper-proof.

## Scope

This policy covers pull-request test, contract, dependency-security, and secret-scanning gates. It does not add deployment, registry, runtime provisioning, local Compose setup, monitoring, or release execution.
