#!/usr/bin/env bats
# scripts/github-settings.sh against a stub gh on PATH: nothing here reaches GitHub.
# The stub logs every call (and the JSON body sent on stdin) to $GH_LOG.
#   GH_RULESETS  JSON answered to GET .../rulesets (default: none exist)
#   GH_FAIL      a substring of the call line that makes the stub fail with an error body

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$ROOT/scripts/github-settings.sh"
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/bin"
  export GH_LOG="$D/gh.log"
  : > "$GH_LOG"
  cat > "$D/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
if [[ "$1 $2" == "repo view" ]]; then echo "example-owner/example-repo"; exit 0; fi
if [[ "$*" == *--input* ]]; then cat >> "$GH_LOG"; echo >> "$GH_LOG"; fi
if [[ -n "${GH_FAIL:-}" && "$*" == *"$GH_FAIL"* ]]; then echo '{"message":"Validation Failed: boom"}'; exit 1; fi
if [[ "$*" == *"/rulesets?"* && "$*" != *-X* ]]; then echo "${GH_RULESETS:-[]}"; fi
exit 0
STUB
  chmod +x "$D/bin/gh"
  export PATH="$D/bin:$PATH"
}

ruleset_json() { grep -m1 '"name":"main"' <<<"$output"; }

@test "dry run is the default: no gh call except repo view, nothing applied" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *DRY-RUN* ]]
  [ "$(wc -l < "$GH_LOG")" -eq 1 ]
  grep -q '^repo view' "$GH_LOG"
}

@test "the repository comes from gh, nothing is hard-coded" {
  run bash "$SCRIPT"
  [[ "$output" == *"example-owner/example-repo"* ]]
}

@test "ruleset requires both checks, strict, from the Actions app" {
  run bash "$SCRIPT"
  j="$(ruleset_json)"
  [ "$(jq -r '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context] | sort | join("|")' <<<"$j")" = "CI OK|PR title (Conventional Commits)" ]
  [ "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.strict_required_status_checks_policy' <<<"$j")" = true ]
  [ "$(jq -r '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].integration_id] | unique | join(",")' <<<"$j")" = 15368 ]
}

@test "ruleset is PR-only with 0 approvals, squash only, no force push or deletion, no bypass" {
  run bash "$SCRIPT"
  j="$(ruleset_json)"
  [ "$(jq -r '.bypass_actors | length' <<<"$j")" -eq 0 ]
  [ "$(jq -c '.rules[] | select(.type=="pull_request") | .parameters.allowed_merge_methods' <<<"$j")" = '["squash"]' ]
  [ "$(jq -r '.rules[] | select(.type=="pull_request") | .parameters.required_approving_review_count' <<<"$j")" = 0 ]
  [ "$(jq -r '[.rules[].type] | index("non_fast_forward") != null and index("deletion") != null' <<<"$j")" = true ]
  [ "$(jq -r '.conditions.ref_name.include[0]' <<<"$j")" = '~DEFAULT_BRANCH' ]
  [ "$(jq -r .enforcement <<<"$j")" = active ]
}

@test "repo settings: squash only, delete branch on merge, secret scanning, push protection" {
  run bash "$SCRIPT"
  [[ "$output" == *'"allow_squash_merge":true'* ]]
  [[ "$output" == *'"allow_merge_commit":false'* ]]
  [[ "$output" == *'"allow_rebase_merge":false'* ]]
  [[ "$output" == *'"delete_branch_on_merge":true'* ]]
  [[ "$output" == *secret_scanning_push_protection* ]]
  [[ "$output" == *private-vulnerability-reporting* ]]
  [[ "$output" == *vulnerability-alerts* ]]
  [[ "$output" == *automated-security-fixes* ]]
}

@test "an unknown argument is refused" {
  run bash "$SCRIPT" --nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "--apply creates the ruleset when missing" {
  run bash "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  grep -q -- '-X POST .*repos/example-owner/example-repo/rulesets' "$GH_LOG"
  ! grep -q -- '-X PUT .*rulesets/' "$GH_LOG"
}

@test "--apply updates the existing ruleset in place (idempotent)" {
  export GH_RULESETS='[{"id":42,"name":"other"},{"id":77,"name":"main"}]'
  run bash "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  grep -q -- '-X PUT .*rulesets/77' "$GH_LOG"
  ! grep -q -- '-X POST .*/rulesets ' "$GH_LOG"
}

@test "a failing call prints the API error body and exits non-zero" {
  export GH_FAIL="/rulesets"
  run bash "$SCRIPT" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"Validation Failed: boom"* ]]
}
