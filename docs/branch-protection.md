# Branch protection for shared quality gates

The shared workflows in this repository become merge gates only when the consuming repository protects its target branch. The exact service test/check names stay owned by the service repository.

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

## Scope

This policy covers pull-request test, contract, dependency-security, and secret-scanning gates. It does not add deployment, registry, runtime provisioning, local Compose setup, monitoring, or release execution.
