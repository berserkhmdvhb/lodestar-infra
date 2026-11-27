#!/usr/bin/env bats
# Static checks on envs/prod (exact settings, depends_on edges, no apps identifiers, no forbidden roles) and the
# mock-provider composition test. Offline: no credentials, no API calls.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  P="$ROOT/envs/prod"
}

# The text of one module block, whitespace squeezed.
block() { awk -v n="$1" '$0 == "module \"" n "\" {" {f=1} f {print} f && $0 == "}" {exit}' "$P/main.tf" | tr -s ' '; }
has() { block "$1" | grep -qF -- "$2" || { echo "module $1 lacks: $2"; return 1; }; }

@test "composition: outputs, per-service pools and secrets, validations (tofu test, mock provider)" {
  command -v tofu >/dev/null || skip "tofu not installed"
  D="$BATS_TEST_TMPDIR/prod"
  mkdir -p "$D/envs"
  cp -r "$P" "$D/envs/prod"
  cp -r "$ROOT/modules" "$D/modules"
  find "$D" -name .terraform -prune -exec rm -rf {} +
  rm -f "$D/envs/prod/backend.tf"
  mkdir "$D/envs/prod/tests"
  cp "$BATS_TEST_DIRNAME/envs-prod/prod.tftest.hcl" "$D/envs/prod/tests/"
  run tofu -chdir="$D/envs/prod" init -backend=false -input=false
  [ "$status" -eq 0 ]
  run tofu -chdir="$D/envs/prod" test
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "gke: prod, regional, two zones, on demand, BALANCED, 1-2 per zone, Tue/Wed window, private endpoint" {
  for s in 'cluster_name = "prod"' 'labels = { cluster = "prod" }' 'location = var.region' \
    'node_locations = var.node_locations' 'spot = false' 'location_policy = "BALANCED"' \
    'min_node_count = 1' 'max_node_count = 2' 'maintenance_recurrence = "FREQ=WEEKLY;BYDAY=TU,WE"' \
    'maintenance_start_time = "2026-12-01T00:00:00Z"' 'maintenance_end_time = "2026-12-01T08:00:00Z"' \
    'enable_public_endpoint = false' 'deletion_protection = true' \
    'enable_insecure_binding_system_unauthenticated = false' 'enable_insecure_binding_system_authenticated = false' \
    'database_encryption_key = module.gke_secrets_key.key_id'; do has gke "$s"; done
  grep -A2 'variable "node_locations"' "$P/variables.tf" >/dev/null
  grep -F 'default     = ["europe-west1-b", "europe-west1-c"]' "$P/variables.tf"
  grep -F 'default     = "europe-west1"' "$P/variables.tf"
  # 2026-12-01 is a Tuesday
  [ "$(date -u -d 2026-12-01 +%a)" = "Tue" ]
  if block gke | grep -qE 'enable_public_endpoint = true|spot = true'; then false; fi
}

@test "network, node account, secrets key, budget, platform secret: exact values" {
  for s in 'network_name = "prod-vpc"' 'subnet_name = "prod-subnet"' 'subnet_cidr = "10.40.0.0/20"' \
    'pods_cidr = "10.50.0.0/16"' 'services_cidr = "10.60.0.0/20"' 'router_name = "prod-router"' 'nat_name = "prod-nat"' \
    'proxy_only_subnet_name = "prod-proxy-only"' 'proxy_only_cidr = "10.40.16.0/23"'; do has network "$s"; done
  if block network | grep -qF 'enable_proxy_only_subnet'; then false; fi
  has node_sa 'display_name = "GKE nodes (prod)"'
  has gke_secrets_key 'key_ring_name = "prod-gke"'
  has gke_secrets_key 'key_name = "prod-secrets"'
  for s in 'enabled = true' 'currency_code = "EUR"' 'amount_units = "250"' 'threshold_percents = [0.5, 0.9, 1.0, 1.5]'; do has budget "$s"; done
  has platform_secrets '"cloudflared-tunnel-token" = { namespace = "cloudflared" }'
  has ci_planner 'billing_account = var.billing_account'
}

@test "project APIs: the production set, no artifactregistry, no cloudkms" {
  if grep -v '^ *#' "$P/main.tf" | grep -qE 'artifactregistry|cloudkms'; then false; fi
  [ "$(sed -n '/project_services = \[/,/^  \]/p' "$P/main.tf" | grep -c '\.googleapis\.com')" -eq 8 ]
}

@test "deploy identity: one call per service, production only, one custom role created once outside the services" {
  for s in 'for_each = var.services' 'environments = ["production"]' 'allowed_environment = "production"' 'enable_previews = false' 'enable_drift = false' \
    'pool_id = "gh-${each.key}"' 'deployer_account_ids = { production = each.value.deployer_account_id }' \
    'github_repository = each.value.github_repository' 'github_owner_id = each.value.github_owner_id' \
    'github_repo_id = each.value.github_repo_id' 'sub_claim_prefix = each.value.sub_claim_prefix' \
    'create_custom_connect_role = false' 'deployer_cluster_role = module.connect_role.role_name'; do has github_wif "$s"; done
  has connect_role 'source = "../../modules/gcp-gke-connect-role"'
  [ "$(grep -c 'create_custom_connect_role' "$P/main.tf")" -eq 1 ]
  run ! grep -nE 'primary|local\.others|local\.connect_role' "$P/main.tf"
}

@test "planner: the ci_* inputs, in the right slots" {
  for s in 'github_repository = var.ci_github_repository' 'github_owner_id = var.ci_github_owner_id' 'github_repo_id = var.ci_github_repo_id' \
    'sub_claim_prefix = var.ci_sub_claim_prefix' 'state_bucket = var.state_bucket' 'state_kms_key_id = var.state_kms_key_id'; do has ci_planner "$s"; done
}

@test "the connect role module has exactly the permissions gcp-github-wif creates itself" {
  a="$(grep -h 'permissions *=' "$ROOT/modules/gcp-gke-connect-role/main.tf" | tr -s ' ')"
  b="$(grep -h 'permissions *=' "$ROOT/modules/gcp-github-wif/main.tf" | tr -s ' ')"
  [ -n "$a" ] && [ "$a" = "$b" ]
  [ "$(grep -hE '^ *(role_id|title|stage) *=' "$ROOT/modules/gcp-gke-connect-role/main.tf" | tr -s ' ')" = "$(grep -hE '^ *(role_id|title|stage) *=' "$ROOT/modules/gcp-github-wif/main.tf" | tr -s ' ')" ]
}

@test "project-level IAM in gcp-project waits for the API enablement; bootstrap/prod enables Resource Manager" {
  sed -n '/google_project_iam_audit_config/,/^}/p' "$ROOT/modules/gcp-project/main.tf" | grep -qF 'depends_on = [google_project_service.this]'
  grep -qF 'cloudresourcemanager.googleapis.com' "$ROOT/bootstrap/prod/main.tf"
}

@test "principal members wait for their pool" {
  sed -n '/resource "google_service_account_iam_member" "wif"/,/^}/p' "$ROOT/modules/gcp-github-wif/main.tf" | grep -qF 'depends_on = [google_iam_workload_identity_pool.github]'
  sed -n '/resource "google_service_account_iam_member" "wif"/,/^}/p' "$ROOT/modules/gcp-ci-planner/main.tf" | grep -qF 'depends_on = [google_iam_workload_identity_pool.ci]'
}

@test "secrets: one call per service, production only" {
  for s in 'for_each = var.services' 'app_environments = ["production"]' 'db_environments = []' 'secret_keys = { production = each.value.secret_keys }'; do has secrets "$s"; done
}

@test "depends_on: every module on module.project; secrets and tunnel token on module.gke; the role owner first" {
  for m in $(grep -oE '^module "[a-z_]+"' "$P/main.tf" | cut -d'"' -f2 | grep -vx project); do
    block "$m" | grep -E 'depends_on = \[.*module\.project' >/dev/null || { echo "module $m lacks depends_on module.project"; false; }
  done
  for m in secrets platform_secrets; do block "$m" | grep -E 'depends_on = \[.*module\.gke[],]' >/dev/null || { echo "$m lacks module.gke"; false; }; done
  # the secrets key's agent grant waits for the container API (module.project enables it), and the cluster waits for the grant
  has gke_secrets_key 'depends_on = [module.project]'
  grep -B1 -A3 'depends_on = \[google_kms_crypto_key_iam_member.gke_agent\]' "$ROOT/modules/gcp-gke-secrets-key/outputs.tf" >/dev/null
  [ "$(grep -c '^module "' "$P/main.tf")" -eq 11 ]
}

@test "no apps identifier, name or network range anywhere in the root" {
  run ! grep -rniwE 'apps' "$P" --include='*.tf' --include='*.example'
  run ! grep -rnE 'apps-|10\.10\.|10\.20\.|10\.30\.|10\.129\.' "$P" --include='*.tf' --include='*.example'
}

@test "no principal, forbidden role or IAM resource in the root; the called modules grant no owner, editor or admin role" {
  run ! grep -nE '^resource|serviceAccount:|user:|group:|allUsers|allAuthenticatedUsers' "$P/main.tf"
  run ! grep -n 'roles/' "$P/main.tf"
  for m in gcp-project gcp-network gcp-node-sa gcp-gke gcp-gke-secrets-key gcp-gke-connect-role gcp-github-wif gcp-secrets gcp-platform-secret gcp-ci-planner gcp-budget; do
    run ! grep -nE 'roles/(owner|editor)|roles/[A-Za-z.]*[aA]dmin|\.admin\b' "$ROOT/modules/$m"/*.tf
  done
}

@test "enable_public_endpoint is false, and the module default stays true (apps unchanged)" {
  grep -qE 'enable_public_endpoint *= *false' "$P/main.tf"
  grep -A3 'variable "enable_public_endpoint"' "$ROOT/modules/gcp-gke/variables.tf" | grep -q 'default     = true'
}

@test "the lock file carries both platforms' hashes and the same provider version as envs/apps" {
  diff "$P/.terraform.lock.hcl" "$ROOT/envs/apps/.terraform.lock.hcl"
  diff "$P/versions.tf" "$ROOT/envs/apps/versions.tf"
}

@test "the example tfvars holds placeholders only" {
  run ! grep -nE '@[a-z0-9-]+\.(com|org|io)' "$P/terraform.tfvars.example"
}
