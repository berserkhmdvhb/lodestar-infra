#!/usr/bin/env bats
# bootstrap/ is the LIVE root holding the owner's state bucket. Its plan must show moves only, so every
# resource it held before the module refactor either keeps its address there or has a moved block into the module.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  B="$ROOT/bootstrap"
  M="$ROOT/modules/gcp-state-backend/main.tf"
  # Collapse every .tf file of bootstrap/ into one whitespace-free string.
  SRC="$(cat "$B"/*.tf | tr -d ' \n\t')"
}

# The pre-refactor addresses of bootstrap/ (hard-coded on purpose).
STAYS=('google_project_service.apis')
MOVES=(
  'google_kms_key_ring.state'
  'google_kms_crypto_key.state'
  'google_kms_crypto_key_iam_member.gcs_agent'
  'google_storage_bucket.state'
  'google_storage_bucket_iam_member.admins'
  'google_kms_crypto_key_iam_member.admins'
)

@test "resources that stay keep their exact address" {
  for a in "${STAYS[@]}"; do
    grep -qE "^resource \"${a%%.*}\" \"${a#*.}\" \{" "$B/main.tf"
  done
}

@test "every moved resource has a moved block into the module, and lives there, not in the root" {
  for a in "${MOVES[@]}"; do
    [[ "$SRC" == *"moved{from=${a}to=module.state.${a}}"* ]] || false
    grep -qE "^resource \"${a%%.*}\" \"${a#*.}\" \{" "$M"
    run ! grep -qE "^resource \"${a%%.*}\" \"${a#*.}\" \{" "$B/main.tf"
  done
}

@test "the root calls the module under the name the moved blocks target" {
  grep -qE '^module "state" \{' "$B/main.tf"
  grep -q 'source *= "../modules/gcp-state-backend"' "$B/main.tf"
}

@test "prevent_destroy survives on the ring, the key and the bucket" {
  [ "$(grep -c 'prevent_destroy = true' "$M")" -eq 3 ]
}
