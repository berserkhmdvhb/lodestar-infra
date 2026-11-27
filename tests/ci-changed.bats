#!/usr/bin/env bats
# scripts/ci-changed.sh: which root's plan a pull request's changed files trigger.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$ROOT/scripts/ci-changed.sh"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
  : > "$GITHUB_OUTPUT"
  unset GITHUB_EVENT_NAME
}

# usage: files <root> <path>...
files() { local r="$1"; shift; printf '%s\n' "$@" | "$SCRIPT" "$r"; }

@test "envs/apps changes trigger apps and not prod" {
  files apps envs/apps/main.tf
  grep -qx 'run=true' "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
  files prod envs/apps/main.tf
  grep -qx 'run=false' "$GITHUB_OUTPUT"
}

@test "envs/prod and bootstrap/prod changes trigger prod and not apps" {
  files prod envs/prod/main.tf
  grep -qx 'run=true' "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
  files prod bootstrap/prod/main.tf
  grep -qx 'run=true' "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
  files apps envs/prod/main.tf bootstrap/prod/main.tf
  grep -qx 'run=false' "$GITHUB_OUTPUT"
}

@test "modules trigger both" {
  files apps modules/gcp-gke/main.tf
  files prod modules/gcp-gke/main.tf
  [ "$(grep -cx 'run=true' "$GITHUB_OUTPUT")" -eq 2 ]
}

@test "the plan script and the plan workflow trigger both" {
  for f in scripts/ci-plan.sh scripts/ci-changed.sh .github/workflows/plan.yml; do
    : > "$GITHUB_OUTPUT"; files apps "$f"; grep -qx 'run=true' "$GITHUB_OUTPUT"
    : > "$GITHUB_OUTPUT"; files prod "$f"; grep -qx 'run=true' "$GITHUB_OUTPUT"
  done
}

@test "unrelated files and look-alike prefixes trigger neither" {
  for r in apps prod; do
    : > "$GITHUB_OUTPUT"
    files "$r" README.md docs/x.md envs/apps-old/a.tf envs/production/a.tf bootstrap/prod2/a.tf bootstrap/main.tf
    grep -qx 'run=false' "$GITHUB_OUTPUT"
  done
}

@test "an empty file list triggers nothing" {
  run "$SCRIPT" prod < /dev/null
  [ "$status" -eq 0 ]
  grep -qx 'run=false' "$GITHUB_OUTPUT"
}

@test "workflow_dispatch always runs" {
  GITHUB_EVENT_NAME=workflow_dispatch run "$SCRIPT" prod < /dev/null
  grep -qx 'run=true' "$GITHUB_OUTPUT"
}

@test "an unknown root is a usage error" {
  run "$SCRIPT" staging < /dev/null
  [ "$status" -ne 0 ]
}
