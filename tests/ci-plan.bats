#!/usr/bin/env bats
# scripts/ci-plan.sh against a stub tofu on PATH: nothing here reaches a cloud API.
# The stub writes a recognisable value into its plan output and into the attribute values of the JSON,
# so the tests can prove neither reaches stdout, stderr or the summary.
#   TOFU_FAIL   init, plan, show, long, sa or nested: that step exits 1 and prints error lines
#               (long: one 300-character Error line that contains the project id in the middle;
#               sa: the Error line names REDACT_SA; nested: it names TF_VAR_nested, which contains the project id)
#               show writes its plan text and Error line to STDERR, as the real tofu does
#   TOFU_CODE   exit code of plan (default 2)
#   TOFU_EMPTY  show answers a plan with no resource changes
# Without -no-color the stub colours its error lines, so a missing flag shows up as an escape character.
# Every negative assertion uses `run !` (a bare `! cmd` in the middle of a test never fails it).

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$ROOT/scripts/ci-plan.sh"
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/bin"
  cat > "$D/bin/tofu" <<'STUB'
#!/usr/bin/env bash
args=" $* "
esc=$'\033[31m'; off=$'\033[0m'
if [[ "$args" == *" -no-color "* ]]; then esc=""; off=""; fi
err() { printf '%sError: %s%s\n' "$esc" "$1" "$off"; }
if [[ "$args" == *" init "* ]]; then
  if [[ "${TOFU_FAIL:-}" == init ]]; then err 'backend ***masked*** failed'; echo "  detail SENTINEL-DETAIL"; exit 1; fi
  echo "Initializing SENTINEL-INIT"; exit 0
fi
if [[ "$args" == *" plan "* ]]; then
  if [[ "${TOFU_FAIL:-}" == plan ]]; then err 'reading ***masked*** failed'; echo "  detail SENTINEL-DETAIL"; exit 1; fi
  if [[ "${TOFU_FAIL:-}" == sa ]]; then err "denied for ${REDACT_SA}"; exit 1; fi
  if [[ "${TOFU_FAIL:-}" == nested ]]; then err "see ${TF_VAR_nested}"; exit 1; fi
  if [[ "${TOFU_FAIL:-}" == long ]]; then
    pad="$(printf 'x%.0s' $(seq 1 300))"
    err "${pad} ${TF_VAR_project_id} ${pad}"
    echo "  detail SENTINEL-DETAIL"; exit 1
  fi
  echo "  + name = SENTINEL-PLAN"
  for a in "$@"; do case "$a" in -out=*) echo opaque > "${a#-out=}" ;; esac; done
  exit "${TOFU_CODE:-2}"
fi
if [[ "$args" == *" show "* ]]; then
  if [[ "${TOFU_FAIL:-}" == show ]]; then echo "  + name = SENTINEL-SHOW" >&2; err 'show failed' >&2; exit 1; fi
  if [[ -n "${TOFU_ADDR:-}" ]]; then
    printf '{"resource_changes":[{"address":"module.x.this[\\"%s:pull_request\\"]","change":{"actions":["create"]}}]}\n' "${TF_VAR_project_id}"; exit 0
  fi
  if [[ -n "${TOFU_EMPTY:-}" ]]; then echo '{"resource_changes":[]}'; exit 0; fi
  cat <<'JSON'
{"resource_changes":[
 {"address":"module.a.google_x.one","change":{"actions":["create"],"after":{"name":"SENTINEL-AFTER"}}},
 {"address":"module.a.google_x.two[\"k\"]","change":{"actions":["update"],"after":{"name":"SENTINEL-AFTER"}}},
 {"address":"module.b.google_y.three","change":{"actions":["delete","create"],"after":{"name":"SENTINEL-AFTER"}}},
 {"address":"module.b.google_y.four","change":{"actions":["delete"]}},
 {"address":"module.b.google_y.five","change":{"actions":["no-op"]}},
 {"address":"module.b.data.google_z.six","change":{"actions":["read"]}}
]}
JSON
  exit 0
fi
exit 0
STUB
  chmod +x "$D/bin/tofu"
  export PATH="$D/bin:$PATH"
  export RUNNER_TEMP="$D"
  export GITHUB_OUTPUT="$D/out"
  export TF_VAR_project_id="SENTINEL-PROJECT-4242"
  export TF_VAR_zone="europe-west1-b"
  export REDACT_SA="sa-SENTINEL@example.invalid"
  : > "$GITHUB_OUTPUT"
}

@test "the summary holds counts and addresses with actions, and nothing else" {
  run "$SCRIPT" "$D/summary.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(sed -n 1p "$D/summary.md")" = "Plan: 1 to add, 1 to change, 1 to destroy, 1 to replace." ]
  grep -qF -- '- `module.a.google_x.one`: create' "$D/summary.md"
  grep -qF -- '- `module.b.google_y.three`: delete, create' "$D/summary.md"
  run ! grep -q 'five\|six' "$D/summary.md"
  run ! grep -q SENTINEL "$D/summary.md"
  grep -qx 'exitcode=2' "$GITHUB_OUTPUT"
}

@test "nothing of the plan or of the init output is printed" {
  run "$SCRIPT" "$D/summary.md"
  out="$output"
  run ! grep -q SENTINEL <<<"$out"
}

@test "no changes reports exitcode 0 and no resource list" {
  TOFU_EMPTY=1 TOFU_CODE=0 run "$SCRIPT" "$D/summary.md"
  [ "$status" -eq 0 ]
  grep -qx 'exitcode=0' "$GITHUB_OUTPUT"
  [ "$(cat "$D/summary.md")" = "$(printf 'Plan: 0 to add, 0 to change, 0 to destroy, 0 to replace.\n\nNo changes.')" ]
}

@test "a failing plan prints only the error line, uncoloured, and exits 1" {
  TOFU_FAIL=plan run "$SCRIPT" "$D/summary.md"
  [ "$status" -eq 1 ]
  out="$output"
  grep -qF 'Error: reading ***masked*** failed' <<<"$out"
  run ! grep -q 'SENTINEL' <<<"$out"
  run ! grep -q $'\033' <<<"$out"
}

@test "a failing init prints only the error line and exits 1" {
  TOFU_FAIL=init run "$SCRIPT" "$D/summary.md"
  [ "$status" -eq 1 ]
  out="$output"
  grep -qF 'Error: backend' <<<"$out"
  run ! grep -q 'SENTINEL' <<<"$out"
  run ! grep -q $'\033' <<<"$out"
}

@test "a long error line is not cut and its identifying value is redacted whole" {
  TOFU_FAIL=long run "$SCRIPT" "$D/summary.md"
  [ "$status" -eq 1 ]
  out="$output"
  [ "$(grep -c '^Error: ' <<<"$out")" -eq 1 ]
  grep -qF -- '*** xxx' <<<"$out"
  run ! grep -q 'SENTINEL' <<<"$out"
  run ! grep -q 'PROJECT' <<<"$out"
  [ "$(grep "^Error: " <<<"$out" | wc -c)" -gt 600 ]
}

@test "a failing show prints no plan text" {
  TOFU_FAIL=show run "$SCRIPT" "$D/summary.md"
  [ "$status" -eq 1 ]
  out="$output"
  run ! grep -q 'SENTINEL' <<<"$out"
}

@test "a failing show keeps its error line (stderr reaches the log) and still prints no plan text" {
  TOFU_FAIL=show run "$SCRIPT" "$D/summary.md"
  out="$output"
  grep -qF 'Error: show failed' <<<"$out"
}

@test "REDACT_SA is replaced in an error line" {
  TOFU_FAIL=sa run "$SCRIPT" "$D/summary.md"
  [ "$status" -eq 1 ]
  out="$output"
  grep -qxF 'Error: denied for ***' <<<"$out"
  run ! grep -q 'SENTINEL' <<<"$out"
}

@test "a value that contains another value is redacted whole, longest first" {
  export TF_VAR_nested="${TF_VAR_project_id}-suffix"
  TOFU_FAIL=nested run "$SCRIPT" "$D/summary.md"
  [ "$status" -eq 1 ]
  out="$output"
  grep -qxF 'Error: see ***' <<<"$out"
  run ! grep -q 'suffix' <<<"$out"
}

@test "the plan file and the log are removed on exit" {
  run "$SCRIPT" "$D/summary.md"
  [ -z "$(find "$D" -maxdepth 1 -name 'ci-plan.*')" ]
  TOFU_FAIL=plan run "$SCRIPT" "$D/summary.md"
  [ -z "$(find "$D" -maxdepth 1 -name 'ci-plan.*')" ]
}

@test "a missing summary path is a usage error" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "the summary file is redacted: a TF_VAR value inside an address" {
  TOFU_ADDR=1 run "$SCRIPT" "$D/summary.md"
  [ "$status" -eq 0 ]
  grep -qF -- '- `module.x.this["***:pull_request"]`: create' "$D/summary.md"
  run ! grep -q SENTINEL "$D/summary.md"
}
