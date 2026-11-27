#!/usr/bin/env bash
# Plan envs/apps in CI without ever printing the plan.
#
# Usage: scripts/ci-plan.sh <summary-file>
#
# Reads the OpenTofu variables from the TF_VAR_* environment (the workflow maps repository secrets to
# them, so GitHub masks every value). Runs init and `plan -lock=false -detailed-exitcode -out`, with all
# tofu output going to a runner-local log. The summary is built from `tofu show -json` with jq and holds
# only the counts and, per changed resource, its address and actions: never an attribute value.
# On a failure it prints only the "Error" lines of the log (cut to 200 characters, at most 20).
# The plan file and the log live in a temporary directory that is removed on exit and never uploaded.
# Writes `exitcode=0` (no changes) or `exitcode=2` (changes) to $GITHUB_OUTPUT.
# Env: CI_PLAN_DIR (default envs/apps).
set -Eeuo pipefail

summary="${1:?usage: ci-plan.sh <summary-file>}"
dir="${CI_PLAN_DIR:-envs/apps}"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ci-plan.XXXXXX")"
trap 'rm -rf "$work"' EXIT
log="$work/tofu.log"

fail() {
  echo "::error::$1; the full log is not published, only its error lines follow"
  grep -F 'Error' "$log" | cut -c1-200 | head -n 20 || true
  exit 1
}

tofu -chdir="$dir" init -input=false >"$log" 2>&1 || fail "tofu init failed"

code=0
tofu -chdir="$dir" plan -lock=false -input=false -detailed-exitcode -out="$work/plan" >>"$log" 2>&1 || code=$?
if [[ "$code" -ne 0 && "$code" -ne 2 ]]; then fail "tofu plan failed"; fi

tofu -chdir="$dir" show -json "$work/plan" >"$work/plan.json" 2>>"$log" || fail "tofu show failed"

jq -r '
  [(.resource_changes // [])[] | select(.change.actions | . != ["no-op"] and . != ["read"])] as $c
  | def n(f): [$c[] | select(.change.actions | f)] | length;
  "Plan: \(n(. == ["create"])) to add, \(n(. == ["update"])) to change, \(n(. == ["delete"])) to destroy, \(n(. == ["delete", "create"] or . == ["create", "delete"])) to replace.",
  "",
  (if ($c | length) == 0 then "No changes." else $c[] | "- `\(.address)`: \(.change.actions | join(", "))" end)
' "$work/plan.json" >"$summary"

echo "exitcode=$code" >>"${GITHUB_OUTPUT:-/dev/null}"
