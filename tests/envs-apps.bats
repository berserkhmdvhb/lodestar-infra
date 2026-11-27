#!/usr/bin/env bats
# Static checks on envs/apps (imports use variables only; targets exist) and the mock-provider
# composition test. Offline: no credentials, no API calls.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  IMPORTS="${IMPORTS_TF:-$ROOT/envs/apps/imports.tf}"
}

# Prints every id line that is not built only from variables/locals.
bad_ids() {
  grep -E '^[[:space:]]+id[[:space:]]*=' "$1" | grep -v -E '\$\{(var|local)\.' || true
  grep -E '^[[:space:]]+id[[:space:]]*=' "$1" | grep -E '[0-9]{12}|[0-9A-Fa-f]{6}-[0-9A-Fa-f]{6}-[0-9A-Fa-f]{6}|projects/[^$]|billingAccounts/[^$]|@[^$]' || true
}

@test "every import id is built from variables or locals, with no literal project, number or account" {
  [ "$(grep -cE '^[[:space:]]+id[[:space:]]*=' "$IMPORTS")" -eq 18 ]
  [ -z "$(bad_ids "$IMPORTS")" ]
}

@test "every import target is a resource declared in the module" {
  while IFS= read -r addr; do
    mod="${addr#module.}"; mod="${mod%%.*}"
    rest="${addr#module."$mod".}"
    type="${rest%%.*}"; name="${rest#*.}"; name="${name%%[*}"
    dir="$ROOT/modules/gcp-${mod//_/-}"
    grep -qE "^resource \"$type\" \"$name\"" "$dir"/*.tf || { echo "no $type.$name in $dir"; false; }
  done < <(sed -nE 's/^[[:space:]]+to[[:space:]]*=[[:space:]]*(module\.[^[:space:]]+)$/\1/p' "$IMPORTS")
}

@test "the id check catches a literal project path, a 12-digit number and an e-mail" {
  printf 'import {\n  id = "projects/my-real-project/global/networks/x"\n  id = "${var.a}/123456789012"\n  id = "${var.a}/x@y.z"\n}\n' > "$BATS_TEST_TMPDIR/bad.tf"
  [ "$(bad_ids "$BATS_TEST_TMPDIR/bad.tf" | wc -l)" -ge 3 ]
}

@test "composition: outputs map onto the template, dns_endpoint set, registry off, budget on" {
  command -v tofu >/dev/null || skip "tofu not installed"
  D="$BATS_TEST_TMPDIR/apps"
  mkdir -p "$D/envs"
  cp -r "$ROOT/envs/apps" "$D/envs/apps"
  cp -r "$ROOT/modules" "$D/modules"
  find "$D" -name .terraform -prune -exec rm -rf {} +
  rm -f "$D/envs/apps/imports.tf" "$D/envs/apps/backend.tf"
  mkdir "$D/envs/apps/tests"
  cp "$BATS_TEST_DIRNAME/envs-apps/apps.tftest.hcl" "$D/envs/apps/tests/"
  run tofu -chdir="$D/envs/apps" init -backend=false -input=false
  [ "$status" -eq 0 ]
  run tofu -chdir="$D/envs/apps" test
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "no import block touches the CI planner identity (everything in it is new)" {
  ! grep -n "ci_planner" "$IMPORTS"
}
