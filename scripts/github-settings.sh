#!/usr/bin/env bash
# The GitHub repository settings as code: a `main` ruleset and the security settings.
#
# Usage: bash scripts/github-settings.sh [--dry-run | --apply]
#   --dry-run  (default) print every call it would make, with the JSON payload; changes nothing (it does one read-only
#             GET of the ruleset list, to say whether it would create or update).
#   --apply    perform the calls. Run it once, as a repository admin, with your own `gh auth login`.
# Needs: gh, jq, git. The repository is read from this checkout's `origin` remote, nothing is hard-coded.
# GH_REPO (which gh would honour over the checkout) is never used: if it names another repository the
# script stops, and every gh call runs with it unset.
# Idempotent: an existing ruleset named `main` is updated in place, the rest are plain PATCH/PUT calls.
# On a failure the API error body is printed and the script stops.
#
# REST docs: https://docs.github.com/en/rest/repos/rules and https://docs.github.com/en/rest/repos/repos
set -euo pipefail

MODE=dry
# The required checks: the CI OK job in ci.yml and the job in pr-title.yml.
REQUIRED_CHECK="CI OK"
TITLE_CHECK="PR title (Conventional Commits)"
# The id of the GitHub Actions app: a check only counts when that app produced it.
ACTIONS_APP_ID=15368

die() { echo "error: $*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --dry-run) MODE=dry ;;
    --apply) MODE=apply ;;
    -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (use --dry-run or --apply)" ;;
  esac
  shift
done
command -v gh >/dev/null || die "gh is required"
command -v jq >/dev/null || die "jq is required"

command -v git >/dev/null || die "git is required"

# gh honours GH_REPO over the current directory: every call runs without it.
gh() { env -u GH_REPO gh "$@"; }

URL="$(git -C "$(dirname "$0")/.." remote get-url origin 2>/dev/null)" || die "this checkout has no origin remote"
REPO="${URL#*github.com[:/]}"
REPO="${REPO%/}"
REPO="${REPO%.git}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "could not read owner/name from the origin URL"
if [[ -n "${GH_REPO:-}" && "$GH_REPO" != "$REPO" ]]; then
  die "GH_REPO is set to $GH_REPO but this checkout is $REPO; run: unset GH_REPO"
fi
echo "# github-settings: $REPO, mode=$MODE"

# call METHOD PATH [JSON]: print it in a dry run, send it with --apply; a failure prints the error body.
call() {
  local method="$1" path="$2" body="${3:-}" out
  if [[ "$MODE" == dry ]]; then
    echo "DRY-RUN $method $path"
    if [[ -n "$body" ]]; then jq -c . <<<"$body"; fi
    return 0
  fi
  echo "APPLY $method $path"
  if [[ -n "$body" ]]; then
    out="$(jq -c . <<<"$body" | gh api -X "$method" "$path" --input - 2>&1)" || die "$method $path failed: $out"
  else
    out="$(gh api -X "$method" "$path" 2>&1)" || die "$method $path failed: $out"
  fi
}

# Repository settings: squash merges only, branches deleted on merge, secret scanning and push protection.
call PATCH "/repos/$REPO" '{
  "allow_squash_merge": true, "allow_merge_commit": false, "allow_rebase_merge": false,
  "delete_branch_on_merge": true,
  "squash_merge_commit_title": "PR_TITLE", "squash_merge_commit_message": "PR_BODY",
  "security_and_analysis": {
    "secret_scanning": {"status": "enabled"},
    "secret_scanning_push_protection": {"status": "enabled"}}}'
call PUT "/repos/$REPO/private-vulnerability-reporting"
call PUT "/repos/$REPO/vulnerability-alerts"
call PUT "/repos/$REPO/automated-security-fixes"

# The ruleset on the default branch. No bypass actor: the admin merges through a pull request too.
# 0 approvals, so the single maintainer can merge their own pull requests.
RULESET="$(jq -n --arg c "$REQUIRED_CHECK" --arg t "$TITLE_CHECK" --argjson app "$ACTIONS_APP_ID" '{
  name: "main", target: "branch", enforcement: "active",
  bypass_actors: [],
  conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
  rules: [
    {type: "pull_request", parameters: {
      required_approving_review_count: 0, dismiss_stale_reviews_on_push: false,
      require_code_owner_review: false, require_last_push_approval: false,
      required_review_thread_resolution: false, allowed_merge_methods: ["squash"]}},
    {type: "required_status_checks", parameters: {
      strict_required_status_checks_policy: true,
      required_status_checks: [{context: $c, integration_id: $app}, {context: $t, integration_id: $app}]}},
    {type: "non_fast_forward"},
    {type: "deletion"}]}')"

# The lookup is a read, so a dry run does it too and can say whether it would create or update.
ID="" KNOWN=true
if LIST="$(gh api "/repos/$REPO/rulesets?per_page=100" 2>&1)"; then
  ID="$(jq -r '[.[] | select(.name == "main") | .id][0] // empty' <<<"$LIST")"
elif [[ "$MODE" == apply ]]; then
  die "GET /repos/$REPO/rulesets failed: $LIST"
else
  KNOWN=false
fi
if [[ -n "$ID" ]]; then
  call PUT "/repos/$REPO/rulesets/$ID" "$RULESET"
elif [[ "$KNOWN" == true ]]; then
  call POST "/repos/$REPO/rulesets" "$RULESET"
else
  echo "# ruleset lookup failed: would create (POST /repos/$REPO/rulesets) or update (PUT /repos/$REPO/rulesets/<id>)"
  jq -c . <<<"$RULESET"
fi
echo "# done ($MODE)"
