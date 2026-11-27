#!/usr/bin/env bats
# Static checks for the L1.4 hardening that a mock-provider test cannot see. Offline.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  KEY="$ROOT/modules/gcp-gke-secrets-key/main.tf"
}

@test "the key ring and the key can never be destroyed" {
  [ "$(grep -c 'prevent_destroy = true' "$KEY")" -eq 2 ]
}

@test "the key output waits for the service agent grant" {
  grep -q 'depends_on = \[google_kms_crypto_key_iam_member.gke_agent\]' "$ROOT/modules/gcp-gke-secrets-key/outputs.tf"
}

@test "the audit config never logs DATA_READ" {
  ! grep -rn 'DATA_READ' --include='*.tf' "$ROOT/modules" "$ROOT/envs"
}

@test "no import block touches the new resources" {
  ! grep -nE 'audit_config|kms_|secrets_key|rbac|log_config' "$ROOT/envs/apps/imports.tf"
}
