#!/usr/bin/env bats
# scripts/checkov-gate.sh against a stub checkov: it must fail on failed checks and on parsing errors.
#   CK_JSON  the JSON the stub prints; with LOG_LEVEL=DEBUG it also names an unparsed file

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/checkov-gate.sh"
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/bin"
  cat > "$D/bin/checkov" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CK_LOG"
if [[ "${LOG_LEVEL:-}" == DEBUG ]]; then echo "[DEBUG]  failed while parsing file /x/modules/m/main.tf"; exit 0; fi
echo "$CK_JSON"
exit 1
STUB
  chmod +x "$D/bin/checkov"
  export CK_LOG="$D/ck.log" PATH="$D/bin:$PATH"
  unset GITHUB_STEP_SUMMARY
}

json() { printf '{"check_type":"terraform","results":{"failed_checks":%s},"summary":{"passed":5,"failed":%s,"skipped":1,"parsing_errors":%s,"checkov_version":"9.9.9"}}' "$3" "$1" "$2"; }

@test "0 failed and 0 parsing errors passes and prints the summary line" {
  export CK_JSON="$(json 0 0 '[]')"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Passed checks: 5, Failed checks: 0, Skipped checks: 1, Parsing errors: 0"* ]]
}

@test "a failed check fails and is named" {
  export CK_JSON="$(json 1 0 '[{"check_id":"CKV_X_1","resource":"google_x.y","file_path":"/main.tf"}]')"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CKV_X_1 google_x.y"* ]]
}

@test "a parsing error fails and names the file" {
  export CK_JSON="$(json 0 1 '[]')"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"/x/modules/m/main.tf"* ]]
}

@test "tests directories and .tftest.hcl files are skipped" {
  export CK_JSON="$(json 0 0 '[]')"
  run bash "$SCRIPT"
  grep -q -- 'tests/' "$CK_LOG"
  grep -q -- 'tftest' "$CK_LOG"
}

@test "GITHUB_STEP_SUMMARY gets a numbers-only table" {
  export CK_JSON="$(json 0 0 '[]')" GITHUB_STEP_SUMMARY="$D/sum.md"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^| 9.9.9 | 5 | 0 | 1 | 0 |$' "$D/sum.md"
}
