#!/usr/bin/env bats
# scripts/ci-plan.sh against a stub tofu on PATH: nothing here reaches a cloud API.
# The stub writes a recognisable value into its plan output and into the attribute values of the JSON,
# so the tests can prove neither reaches stdout, stderr or the summary.
#   TOFU_FAIL   init or plan: that step exits 1 and prints an error line holding a masked-looking value
#   TOFU_CODE   exit code of plan (default 2)
#   TOFU_EMPTY  show answers a plan with no resource changes

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$ROOT/scripts/ci-plan.sh"
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/bin"
  cat > "$D/bin/tofu" <<'STUB'
#!/usr/bin/env bash
args=" $* "
if [[ "$args" == *" init "* ]]; then
  if [[ "${TOFU_FAIL:-}" == init ]]; then printf 'Error: backend ***masked*** failed\n  detail SENTINEL-DETAIL\n'; exit 1; fi
  echo "Initializing SENTINEL-INIT"; exit 0
fi
if [[ "$args" == *" plan "* ]]; then
  if [[ "${TOFU_FAIL:-}" == plan ]]; then printf 'Error: reading ***masked*** failed\n  detail SENTINEL-DETAIL\n'; exit 1; fi
  echo "  + name = SENTINEL-PLAN"
  for a in "$@"; do case "$a" in -out=*) echo opaque > "${a#-out=}" ;; esac; done
  exit "${TOFU_CODE:-2}"
fi
if [[ "$args" == *" show "* ]]; then
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
  : > "$GITHUB_OUTPUT"
}

@test "the summary holds counts and addresses with actions, and nothing else" {
  run "$SCRIPT" "$D/summary.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(sed -n 1p "$D/summary.md")" = "Plan: 1 to add, 1 to change, 1 to destroy, 1 to replace." ]
  grep -qF -- '- `module.a.google_x.one`: create' "$D/summary.md"
  grep -qF -- '- `module.b.google_y.three`: delete, create' "$D/summary.md"
  ! grep -q 'five\|six' "$D/summary.md"
  ! grep -q SENTINEL "$D/summary.md"
  grep -qx 'exitcode=2' "$GITHUB_OUTPUT"
}

@test "nothing of the plan or of the init output is printed" {
  run "$SCRIPT" "$D/summary.md"
  ! grep -q SENTINEL <<<"$output"
}

@test "no changes reports exitcode 0 and no resource list" {
  TOFU_EMPTY=1 TOFU_CODE=0 run "$SCRIPT" "$D/summary.md"
  [ "$status" -eq 0 ]
  grep -qx 'exitcode=0' "$GITHUB_OUTPUT"
  [ "$(cat "$D/summary.md")" = "$(printf 'Plan: 0 to add, 0 to change, 0 to destroy, 0 to replace.\n\nNo changes.')" ]
}

@test "a failing plan prints only the error line, cut and capped, and exits 1" {
  TOFU_FAIL=plan run "$SCRIPT" "$D/summary.md"
  [ "$status" -eq 1 ]
  grep -qF 'Error: reading ***masked*** failed' <<<"$output"
  ! grep -q 'SENTINEL' <<<"$output"
}

@test "a failing init prints only the error line and exits 1" {
  TOFU_FAIL=init run "$SCRIPT" "$D/summary.md"
  [ "$status" -eq 1 ]
  ! grep -q 'SENTINEL' <<<"$output"
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
