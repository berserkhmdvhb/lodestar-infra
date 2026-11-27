#!/usr/bin/env bats
# Static checks of the per-root CI jobs: each job reads only its own root's secrets and variables.
# The apps jobs are `plan` and `drift`, the production jobs are `plan-prod` and `drift-prod`.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# usage: job <workflow-file> <job-id>: prints that job's block
job() { awk -v id="  $2:" '$0 == id {on=1; print; next} /^  [A-Za-z0-9_-]+:/ {on=0} on' "$ROOT/.github/workflows/$1"; }

# usage: refs <block>: every secrets.X / vars.X name, one per line
refs() { grep -oE '(secrets|vars)\.[A-Za-z0-9_]+' <<<"$1" | sort -u; }

@test "the production jobs exist" {
  [ -n "$(job plan.yml plan-prod)" ]
  [ -n "$(job drift.yml drift-prod)" ]
  grep -q 'name: Plan envs/prod' <<<"$(job plan.yml plan-prod)"
  grep -q 'name: Drift envs/prod' <<<"$(job drift.yml drift-prod)"
}

@test "each production job reads only TF_PROD_* secrets and variables" {
  for spec in plan.yml:plan-prod drift.yml:drift-prod; do
    r="$(refs "$(job "${spec%%:*}" "${spec##*:}")")"
    [ -n "$r" ]
    run ! grep -vE '^(secrets|vars)\.TF_PROD_[A-Z_]+$' <<<"$r"
  done
}

@test "each apps job reads no TF_PROD_* value" {
  for spec in plan.yml:plan drift.yml:drift; do
    b="$(job "${spec%%:*}" "${spec##*:}")"
    [ -n "$b" ]
    run ! grep -q 'TF_PROD' <<<"$b"
  done
}

@test "the production jobs authenticate with the production planner" {
  for spec in plan.yml:plan-prod drift.yml:drift-prod; do
    b="$(job "${spec%%:*}" "${spec##*:}")"
    grep -q 'workload_identity_provider: ${{ secrets.TF_PROD_CI_WIF_PROVIDER }}' <<<"$b"
    grep -q 'service_account: ${{ secrets.TF_PROD_CI_SA }}' <<<"$b"
  done
}

@test "the production jobs check every secret they use before planning" {
  for spec in plan.yml:plan-prod drift.yml:drift-prod; do
    b="$(job "${spec%%:*}" "${spec##*:}")"
    for n in $(refs "$b" | sed 's/^[a-z]*\.//'); do
      [ "$(grep -c "^          ${n}: \${{ \(secrets\|vars\).${n} }}" <<<"$b")" -ge 1 ]
      grep -qE "^ +(for name in \\\\)?.*\b${n}\b" <<<"$(sed -n '/for name in/,/; do/p' <<<"$b")"
    done
  done
}

@test "no dynamic secrets lookup, no fallback expression, no reusable workflow, no environment" {
  for f in plan.yml drift.yml; do
    run ! grep -E 'secrets\[|secrets: inherit|workflow_call|^ +uses: \./|^ +environment:' "$ROOT/.github/workflows/$f"
    run ! grep -E '\$\{\{[^}]*(secrets|vars)\.[^}]*(&&|\|\|)[^}]*\}\}|\$\{\{[^}]*(&&|\|\|)[^}]*(secrets|vars)\.[^}]*\}\}' "$ROOT/.github/workflows/$f"
  done
}

@test "the production plan masks the services leaves and plans envs/prod" {
  b="$(job plan.yml plan-prod)"
  grep -q 'TF_VAR_services: ${{ secrets.TF_PROD_SERVICES }}' <<<"$b"
  grep -q 'CI_MASK_JSON: TF_VAR_services' <<<"$b"
  grep -q 'CI_PLAN_DIR: envs/prod' <<<"$b"
  b="$(job drift.yml drift-prod)"
  grep -q 'CI_MASK_JSON: TF_VAR_services' <<<"$b"
  grep -q 'CI_PLAN_DIR: envs/prod' <<<"$b"
}

@test "each plan job runs its own path filter, and the workflow triggers on both roots" {
  grep -q 'scripts/ci-changed.sh apps' <<<"$(job plan.yml plan)"
  grep -q 'scripts/ci-changed.sh prod' <<<"$(job plan.yml plan-prod)"
  grep -q '"bootstrap/prod/\*\*"' "$ROOT/.github/workflows/plan.yml"
  grep -q '"envs/\*\*"' "$ROOT/.github/workflows/plan.yml"
}

@test "each drift job has its own issue title" {
  grep -qx '          TITLE: Drift detected in envs/apps' <<<"$(job drift.yml drift)"
  grep -qx '          TITLE: Drift detected in envs/prod' <<<"$(job drift.yml drift-prod)"
  for spec in drift:apps drift-prod:prod; do
    grep -q -- '--author app/github-actions' <<<"$(job drift.yml "${spec%%:*}")"
  done
}

@test "drift-prod has no path filter, and the plan jobs fetch two commits and fail on a git error" {
  run ! grep -q 'ci-changed' <<<"$(job drift.yml drift-prod)"
  for j in plan plan-prod; do
    b="$(job plan.yml "$j")"
    grep -q 'fetch-depth: 2' <<<"$b"
    grep -q 'shell: bash' <<<"$b"
    grep -q 'git diff --no-renames' <<<"$b"
  done
}

@test "both prod jobs pass and check the node locations variable" {
  for spec in plan.yml:plan-prod drift.yml:drift-prod; do
    b="$(job "${spec%%:*}" "${spec##*:}")"
    grep -q 'TF_VAR_node_locations: ${{ vars.TF_PROD_NODE_LOCATIONS }}' <<<"$b"
    grep -q 'TF_PROD_NODE_LOCATIONS: ${{ vars.TF_PROD_NODE_LOCATIONS }}' <<<"$b"
    grep -q 'TF_PROD_NODE_LOCATIONS; do' <<<"$b"
  done
}
