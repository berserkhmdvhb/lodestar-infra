# One import block per hand-built resource. Every id is built from variables and locals only, so no project id,
# number or account ever enters Git. The blocks do nothing once the resources are in state; they may stay.
# Id formats are the ones in the google 8.12.0 provider docs.

locals {
  p = var.project_id

  pool_principal = "principal://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools"

  node_sa_email = "gke-nodes@${local.p}.iam.gserviceaccount.com"
  deployer_sa   = { for e in local.environments : e => "gh-deployer-${e}@${local.p}.iam.gserviceaccount.com" }

  secret_ids = merge([for e, keys in local.secret_keys : { for k in keys : "${e}-${k}" => "${local.service_name}-${e}-${k}" }]...)
  app_ns     = { for e in local.environments : e => "${local.service_name}-${e}" }
  db_ns      = { for e in ["dev", "qa"] : e => "${local.service_name}-${e}-db" }
}

# --- APIs (9) ---
import {
  for_each = toset(local.services)
  to       = module.project.google_project_service.this[each.key]
  id       = "${local.p}/${each.key}"
}

# --- network (4) ---
import {
  to = module.network.google_compute_network.this
  id = "projects/${local.p}/global/networks/apps-vpc"
}

import {
  to = module.network.google_compute_subnetwork.this
  id = "projects/${local.p}/regions/${var.region}/subnetworks/apps-subnet"
}

import {
  to = module.network.google_compute_router.this
  id = "projects/${local.p}/regions/${var.region}/routers/apps-router"
}

import {
  to = module.network.google_compute_router_nat.this
  id = "${local.p}/${var.region}/apps-router/apps-nat"
}

# --- node service account (2) ---
import {
  to = module.node_sa.google_service_account.nodes
  id = "projects/${local.p}/serviceAccounts/${local.node_sa_email}"
}

import {
  to = module.node_sa.google_project_iam_member.nodes["roles/container.defaultNodeServiceAccount"]
  id = "${local.p} roles/container.defaultNodeServiceAccount serviceAccount:${local.node_sa_email}"
}

# --- Workload Identity Federation (2 + 3 + 3 + 3) ---
import {
  to = module.github_wif.google_iam_workload_identity_pool.github
  id = "projects/${local.p}/locations/global/workloadIdentityPools/github"
}

import {
  to = module.github_wif.google_iam_workload_identity_pool_provider.github
  id = "projects/${local.p}/locations/global/workloadIdentityPools/github/providers/github-oidc"
}

import {
  for_each = local.deployer_sa
  to       = module.github_wif.google_service_account.deployer[each.key]
  id       = "projects/${local.p}/serviceAccounts/${each.value}"
}

import {
  for_each = local.deployer_sa
  to       = module.github_wif.google_service_account_iam_member.wif[each.key]
  id       = "projects/${local.p}/serviceAccounts/${each.value} roles/iam.workloadIdentityUser ${local.pool_principal}/github/subject/${var.sub_claim_prefix}:environment:${each.key}"
}

import {
  for_each = local.deployer_sa
  to       = module.github_wif.google_project_iam_member.cluster[each.key]
  id       = "${local.p} roles/container.clusterViewer serviceAccount:${each.value}"
}

# --- Secret Manager: conditional accessors (3 + 2) and the empty secrets (7) ---
import {
  for_each = local.app_ns
  to       = module.secrets.google_project_iam_member.app[each.key]
  id       = "${local.p} roles/secretmanager.secretAccessor ${local.pool_principal}/${local.p}.svc.id.goog/subject/ns/${each.value}/sa/external-secrets eso-${each.value}"
}

import {
  for_each = local.db_ns
  to       = module.secrets.google_project_iam_member.db[each.key]
  id       = "${local.p} roles/secretmanager.secretAccessor ${local.pool_principal}/${local.p}.svc.id.goog/subject/ns/${each.value}/sa/external-secrets eso-${each.value}"
}

import {
  for_each = local.secret_ids
  to       = module.secrets.google_secret_manager_secret.this[each.key]
  id       = "projects/${local.p}/secrets/${each.value}"
}

# --- budget (1) ---
import {
  to = module.budget.google_billing_budget.this[0]
  id = "billingAccounts/${var.billing_account}/budgets/${var.budget_id}"
}

# --- cluster and node pool (2) ---
import {
  to = module.gke.google_container_cluster.this
  id = "projects/${local.p}/locations/${var.zone}/clusters/apps"
}

import {
  to = module.gke.google_container_node_pool.this
  id = "${local.p}/${var.zone}/apps/default-pool"
}
