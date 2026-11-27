#!/usr/bin/env bash
# Plan envs/apps in CI without ever printing the plan.
#
# Usage: scripts/ci-plan.sh <summary-file>
#
# Reads the OpenTofu variables from the TF_VAR_* environment (the workflow maps repository secrets to
# them, so GitHub masks every value). Runs init and `plan -lock=false -detailed-exitcode -out`, with all
# tofu output going to a runner-local log. The summary is built from `tofu show -json` with jq and holds
# only the counts and, per changed resource, its address and actions: never an attribute value.
# On a failure it prints only the log lines that start with "Error: " (at most 20), after replacing every
# TF_VAR_* value (except region and zone) and every REDACT_* value with *** by literal match. GitHub masks
# only a whole registered value, so a line is never cut; the redaction is a second layer.
# The workflow sets REDACT_WIF_PROVIDER and REDACT_SA from the CI identity secrets.
# The plan file and the log live in a temporary directory that is removed on exit and never uploaded.
# The summary is redacted the same way (addresses can carry values as keys, and issue bodies are not masked).
# Writes `exitcode=0` (no changes) or `exitcode=2` (changes) to $GITHUB_OUTPUT.
# Structured inputs: CI_MASK_JSON names environment variables (space-separated) that hold JSON, such as
# TF_VAR_services. Before any tofu command, every string and number leaf in them, and the owner and the repo of every
# leaf shaped <owner>/<repo>, is registered with ::add-mask:: and exported as REDACT_LEAF_<n> for the literal
# redaction (longest first). The value is read from the environment and never echoed; a parse failure prints no value.
# Env: CI_PLAN_DIR (default envs/apps), CI_MASK_JSON (default none).
set -Eeuo pipefail

summary="${1:?usage: ci-plan.sh <summary-file>}"
dir="${CI_PLAN_DIR:-envs/apps}"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ci-plan.XXXXXX")"
trap 'rm -rf "$work"' EXIT
log="$work/tofu.log"

mask_json() {
  local name leaf out n=0
  for name in ${CI_MASK_JSON:-}; do
    out="$(printenv "$name" | jq -r '
      [.. | scalars | select(type == "string" or type == "number") | tostring | split("\n")[] | select(length > 0)] as $l
      | ($l + [$l[] | select(test("^[^/]+/[^/]+$")) | split("/")[]]) as $m
      | ($m + [$m[] | select(contains(".")) | (gsub("\\."; "\\."), gsub("\\."; "\\\\."))]) | unique | .[]' 2>/dev/null)" ||
      { echo "::error::${name} is not valid JSON"; exit 1; }
    while IFS= read -r leaf; do
      [[ -n "$leaf" ]] || continue
      echo "::add-mask::${leaf}"
      n=$((n + 1))
      export "REDACT_LEAF_${n}=${leaf}"
    done <<<"$out"
  done
}
mask_json

redact() {
  awk '
    BEGIN {
      for (k in ENVIRON) {
        if (((k ~ /^TF_VAR_/ && k != "TF_VAR_region" && k != "TF_VAR_zone") || k ~ /^REDACT_/) && ENVIRON[k] != "") v[++n] = ENVIRON[k]
      }
      for (i = 2; i <= n; i++) { x = v[i]; for (j = i - 1; j >= 1 && length(v[j]) < length(x); j--) v[j + 1] = v[j]; v[j + 1] = x }
    }
    {
      line = $0
      for (i = 1; i <= n; i++) {
        out = ""
        while ((p = index(line, v[i])) > 0) { out = out substr(line, 1, p - 1) "***"; line = substr(line, p + length(v[i])) }
        line = out line
      }
      print line
    }'
}

fail() {
  echo "::error::$1; the full log is not published, only its error lines follow"
  redact <"$log" | grep -E '^(│ )?Error: ' | head -n 20 || true
  exit 1
}

tofu -chdir="$dir" init -no-color -input=false >"$log" 2>&1 || fail "tofu init failed"

code=0
tofu -chdir="$dir" plan -no-color -lock=false -input=false -detailed-exitcode -out="$work/plan" >>"$log" 2>&1 || code=$?
if [[ "$code" -ne 0 && "$code" -ne 2 ]]; then fail "tofu plan failed"; fi

tofu -chdir="$dir" show -no-color -json "$work/plan" >"$work/plan.json" 2>>"$log" || fail "tofu show failed"

jq -r '
  [(.resource_changes // [])[] | select(.change.actions | . != ["no-op"] and . != ["read"])] as $c
  | def n(f): [$c[] | select(.change.actions | f)] | length;
  "Plan: \(n(. == ["create"])) to add, \(n(. == ["update"])) to change, \(n(. == ["delete"])) to destroy, \(n(. == ["delete", "create"] or . == ["create", "delete"])) to replace.",
  "",
  (if ($c | length) == 0 then "No changes." else $c[] | "- `\(.address)`: \(.change.actions | join(", "))" end)
' "$work/plan.json" | redact >"$summary"

echo "exitcode=$code" >>"${GITHUB_OUTPUT:-/dev/null}"
