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
if [[ -n "${GH_REPO:-}" ]]; then echo "stub: GH_REPO leaked into gh" >> "$GH_LOG"; fi
if [[ "$*" == *--input* ]]; then cat >> "$GH_LOG"; echo >> "$GH_LOG"; fi
if [[ -n "${GH_FAIL:-}" && "$*" == *"$GH_FAIL"* ]]; then echo '{"message":"Validation Failed: boom"}'; exit 1; fi
if [[ "$*" == *"/rulesets?"* && "$*" != *-X* ]]; then echo "${GH_RULESETS:-[]}"; fi
exit 0
STUB
  chmod +x "$D/bin/gh"
  export PATH="$D/bin:$PATH"
  unset GH_REPO
  # a throwaway checkout: the script finds its repository from the origin of the checkout it lives in
  mkdir -p "$D/co/scripts"
  cp "$SCRIPT" "$D/co/scripts/"
  git -C "$D/co" init -q
  git -C "$D/co" remote add origin "git@github.com:example-owner/example-repo.git"
  SCRIPT="$D/co/scripts/github-settings.sh"
}

set_origin() { git -C "$D/co" remote set-url origin "$1"; }

ruleset_json() { grep -m1 '"name":"main"' <<<"$output"; }

@test "dry run is the default: only reads reach gh, nothing is written" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *DRY-RUN* ]]
  [ "$(wc -l < "$GH_LOG")" -eq 1 ]
  grep -q 'rulesets' "$GH_LOG"
  ! grep -q -- '-X' "$GH_LOG"
}

@test "dry run says POST when no main ruleset exists and PUT with its id when one does" {
  run bash "$SCRIPT"
  [[ "$output" == *"DRY-RUN POST /repos/example-owner/example-repo/rulesets"* ]]
  export GH_RULESETS='[{"id":77,"name":"main"}]'
  run bash "$SCRIPT"
  [[ "$output" == *"DRY-RUN PUT /repos/example-owner/example-repo/rulesets/77"* ]]
  [[ "$output" != *"DRY-RUN POST"*rulesets* ]]
}

@test "dry run with an unreadable ruleset list says create or update" {
  export GH_FAIL="/rulesets?"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"would create"* ]]
}

@test "the squash commit title and message come from the PR" {
  run bash "$SCRIPT"
  [[ "$output" == *'"squash_merge_commit_title":"PR_TITLE"'* ]]
  [[ "$output" == *'"squash_merge_commit_message":"PR_BODY"'* ]]
}

@test "the repository comes from the origin remote, nothing is hard-coded" {
  run bash "$SCRIPT"
  [[ "$output" == *"# github-settings: example-owner/example-repo, mode=dry"* ]]
}

@test "HTTPS origin URLs parse to owner/name, with and without .git" {
  set_origin "https://github.com/example-owner/example-repo.git"
  run bash "$SCRIPT"
  [[ "$output" == *"# github-settings: example-owner/example-repo, mode=dry"* ]]
  set_origin "https://github.com/example-owner/example-repo"
  run bash "$SCRIPT"
  [[ "$output" == *"# github-settings: example-owner/example-repo, mode=dry"* ]]
}

@test "a non-GitHub origin is refused" {
  set_origin "https://example.com/nope"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read owner/name"* ]]
}

@test "GH_REPO naming another repository stops the script before any gh call" {
  export GH_REPO="example-owner/other-repo"
  run bash "$SCRIPT" --apply
  [ "$status" -ne 0 ]
  msg="$output"
  [[ "$msg" == *"GH_REPO is set to example-owner/other-repo but this checkout is example-owner/example-repo; run: unset GH_REPO"* ]]
  [ ! -s "$GH_LOG" ]
}

@test "GH_REPO equal to the checkout repository proceeds, and never reaches gh" {
  export GH_REPO="example-owner/example-repo"
  run bash "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  grep -q -- '-X POST' "$GH_LOG"
  run grep -q 'GH_REPO leaked' "$GH_LOG"
  [ "$status" -ne 0 ]
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
