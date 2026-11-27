#!/usr/bin/env bash
# The IaC security scan as a strict gate: checkov over every OpenTofu file, tests excluded.
# Fails on any failed check AND on any file checkov could not parse (checkov itself only warns on those,
# so a real .tf file could silently escape scanning). Appends a numbers-only table to GITHUB_STEP_SUMMARY.
# Needs: checkov, jq. Run from the repository root (make checkov).
set -euo pipefail

# Skipped: .tools, any directory named exactly tests (no infrastructure module may be named tests), .tftest.hcl.
# Slash-delimited and without alternation: a (^|/) group makes checkov print FutureWarnings.
SKIP=(--skip-path '/\.tools/' --skip-path '/tests/' --skip-path '\.tftest\.hcl$')
ARGS=(-d . --framework terraform --compact --skip-download "${SKIP[@]}")
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

# checkov exits non-zero on failed checks; the counts decide below, but a non-zero exit with clean counts
# (a crash after the output) or unreadable JSON is a failure too.
ck_rc=0
checkov "${ARGS[@]}" --quiet -o json >"$OUT" || ck_rc=$?
JQ_ONE='if type == "array" then .[0] else . end'
read -r PASSED FAILED SKIPPED PARSE VERSION < <(jq -r "$JQ_ONE | .summary | [.passed // 0, .failed // 0, .skipped // 0, .parsing_errors // 0, .checkov_version // \"unknown\"] | @tsv" "$OUT") ||
  { echo "checkov gave no JSON result" >&2; exit 1; }

echo "checkov $VERSION: Passed checks: $PASSED, Failed checks: $FAILED, Skipped checks: $SKIPPED, Parsing errors: $PARSE"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### IaC security scan (checkov)"
    echo "| version | passed | failed | skipped | parsing errors |"
    echo "| --- | --- | --- | --- | --- |"
    echo "| $VERSION | $PASSED | $FAILED | $SKIPPED | $PARSE |"
  } >>"$GITHUB_STEP_SUMMARY"
fi

rc=0
if ((ck_rc != 0 && FAILED == 0 && PARSE == 0)); then
  echo "checkov exited $ck_rc with no failed checks and no parsing errors: the scan did not complete" >&2
  rc=1
fi
if ((FAILED > 0)); then
  echo "failed checks:" >&2
  jq -r "$JQ_ONE | .results.failed_checks[]? | \"  \(.check_id) \(.resource) \(.file_path)\"" "$OUT" >&2
  rc=1
fi
if ((PARSE > 0)); then
  echo "files checkov could not parse:" >&2
  LOG_LEVEL=DEBUG checkov "${ARGS[@]}" --quiet 2>&1 | sed -n 's/.*failed while parsing file //p' | sort -u | sed 's/^/  /' >&2 || true
  rc=1
fi
exit "$rc"
