locals {
  oauth_scopes = [
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/userinfo.email",
  ]
}

resource "google_container_cluster" "this" {
  # checkov:skip=CKV_GCP_12:network policy is enforced by Dataplane V2, not the legacy add-on
  # checkov:skip=CKV_GCP_13:no client certificate is issued; the live master_auth is left as it is
  # checkov:skip=CKV_GCP_20:master authorized networks are enabled on the live cluster but are not managed here; the DNS endpoint is the access path
  # checkov:skip=CKV_GCP_61:flow logs belong to the subnetwork (gcp-network); intranode visibility is not in the live cluster
  # checkov:skip=CKV_GCP_65:Google Groups for RBAC is not used
  # checkov:skip=CKV_GCP_66:Binary Authorization stays off until phase 11 (binary_authorization_mode)
  # checkov:skip=CKV_GCP_68:Secure Boot is set on the node pool; the throwaway default pool is removed at once
  # checkov:skip=CKV_GCP_69:GKE_METADATA is set on the node pool; the throwaway default pool is removed at once
  name     = var.cluster_name
  project  = var.project_id
  location = var.location

  network    = var.network
  subnetwork = var.subnetwork

  # GKE needs a node pool at creation. A one-node default pool is created and removed at once; the real
  # pool is google_container_node_pool.this. The node_config only keeps even that pool off the default
  # compute account.
  remove_default_node_pool = true
  initial_node_count       = 1
  node_config {
    service_account = var.node_service_account
  }

  deletion_protection   = var.deletion_protection
  datapath_provider     = "ADVANCED_DATAPATH"
  enable_shielded_nodes = true
  resource_labels       = var.labels

  release_channel {
    channel = var.release_channel
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  private_cluster_config {
    enable_private_nodes = true
  }

  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
    ip_endpoints_config {
      enabled = var.enable_public_endpoint
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = true
    }
  }

  cost_management_config {
    enabled = true
  }

  maintenance_policy {
    recurring_window {
      start_time = var.maintenance_start_time
      end_time   = var.maintenance_end_time
      recurrence = var.maintenance_recurrence
    }
  }

  rbac_binding_config {
    enable_insecure_binding_system_unauthenticated = var.enable_insecure_binding_system_unauthenticated
    enable_insecure_binding_system_authenticated   = var.enable_insecure_binding_system_authenticated
  }

  # Free tier only. vulnerability_mode is left unset: GKE removed workload vulnerability scanning.
  security_posture_config {
    mode = var.security_posture_mode
  }

  database_encryption {
    state    = var.database_encryption_key == null ? "DECRYPTED" : "ENCRYPTED"
    key_name = var.database_encryption_key
  }

  dynamic "binary_authorization" {
    for_each = var.binary_authorization_mode == null ? [] : [var.binary_authorization_mode]
    content {
      evaluation_mode = binary_authorization.value
    }
  }

  lifecycle {
    # The live cluster was made with gcloud and carries its default pool inline. node_pool and node_config
    # are reported back from that pool (node_config forces replacement), and the two create-only
    # arguments are not in the API at all. None of them may plan a change or a replacement on import.
    ignore_changes = [node_pool, node_config, initial_node_count, remove_default_node_pool]
  }
}

resource "google_container_node_pool" "this" {
  name     = var.node_pool_name
  project  = var.project_id
  location = var.location
  cluster  = google_container_cluster.this.name

  autoscaling {
    min_node_count  = var.min_node_count
    max_node_count  = var.max_node_count
    location_policy = "ANY"
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    strategy  = "SURGE"
    max_surge = 1
  }

  node_config {
    machine_type    = var.machine_type
    disk_type       = var.disk_type
    disk_size_gb    = var.disk_size_gb
    image_type      = "COS_CONTAINERD"
    spot            = var.spot
    service_account = var.node_service_account
    oauth_scopes    = local.oauth_scopes
    metadata        = { "disable-legacy-endpoints" = "true" }
    resource_labels = var.labels

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  lifecycle {
    # The autoscaler owns the node count; initial_node_count is create-only and unknown after import.
    ignore_changes = [node_count, initial_node_count]
  }
}
