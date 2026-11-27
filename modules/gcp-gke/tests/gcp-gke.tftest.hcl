# Mock-provider tests: no credentials, no API calls.
mock_provider "google" {}

variables {
  project_id           = "your-project-id"
  network              = "apps-vpc"
  subnetwork           = "apps-subnet"
  node_service_account = "gke-nodes@your-project-id.iam.gserviceaccount.com"
}

run "cluster_identity_and_network" {
  command = plan

  assert {
    condition = (
      google_container_cluster.this.name == "apps"
      && google_container_cluster.this.location == "europe-west1-b"
      && google_container_cluster.this.project == "your-project-id"
      && google_container_cluster.this.network == "apps-vpc"
      && google_container_cluster.this.subnetwork == "apps-subnet"
      && google_container_cluster.this.deletion_protection == true
    )
    error_message = "name, zone, project, network, subnetwork, deletion protection"
  }
  assert {
    condition = (
      one(google_container_cluster.this.ip_allocation_policy).cluster_secondary_range_name == "pods"
      && one(google_container_cluster.this.ip_allocation_policy).services_secondary_range_name == "services"
    )
    error_message = "secondary ranges"
  }
  assert {
    condition     = google_container_cluster.this.resource_labels == tomap({ cluster = "apps" })
    error_message = "cluster labels"
  }
}

run "private_nodes_and_endpoints" {
  command = plan

  assert {
    condition     = one(google_container_cluster.this.private_cluster_config).enable_private_nodes == true
    error_message = "private nodes on"
  }
  assert {
    condition     = one(one(google_container_cluster.this.control_plane_endpoints_config).dns_endpoint_config).allow_external_traffic == true
    error_message = "DNS endpoint allows external traffic"
  }
  assert {
    condition     = one(one(google_container_cluster.this.control_plane_endpoints_config).ip_endpoints_config).enabled == true
    error_message = "public IP endpoint stays enabled by default"
  }
}

run "ip_endpoint_can_be_disabled" {
  command = plan

  variables {
    enable_public_endpoint = false
  }

  assert {
    condition     = one(one(google_container_cluster.this.control_plane_endpoints_config).ip_endpoints_config).enabled == false
    error_message = "public IP endpoint off when asked"
  }
}

run "platform_features" {
  command = plan

  assert {
    condition     = google_container_cluster.this.datapath_provider == "ADVANCED_DATAPATH"
    error_message = "Dataplane V2"
  }
  assert {
    condition     = one(google_container_cluster.this.workload_identity_config).workload_pool == "your-project-id.svc.id.goog"
    error_message = "workload identity pool"
  }
  assert {
    condition     = one(google_container_cluster.this.gateway_api_config).channel == "CHANNEL_STANDARD"
    error_message = "Gateway API standard"
  }
  assert {
    condition     = google_container_cluster.this.enable_shielded_nodes == true
    error_message = "shielded nodes"
  }
  assert {
    condition     = one(google_container_cluster.this.release_channel).channel == "STABLE"
    error_message = "release channel"
  }
  assert {
    condition     = one(google_container_cluster.this.cost_management_config).enabled == true
    error_message = "cost management"
  }
}

run "observability" {
  command = plan

  assert {
    condition     = toset(one(google_container_cluster.this.logging_config).enable_components) == toset(["SYSTEM_COMPONENTS", "WORKLOADS"])
    error_message = "system plus workload logging"
  }
  assert {
    condition     = toset(one(google_container_cluster.this.monitoring_config).enable_components) == toset(["SYSTEM_COMPONENTS"])
    error_message = "system monitoring"
  }
  assert {
    condition     = one(one(google_container_cluster.this.monitoring_config).managed_prometheus).enabled == true
    error_message = "managed Prometheus"
  }
}

run "maintenance_window_is_two_days_of_eight_hours" {
  command = plan

  assert {
    condition     = one(one(google_container_cluster.this.maintenance_policy).recurring_window).recurrence == "FREQ=WEEKLY;BYDAY=SA,SU"
    error_message = "Saturday and Sunday every week (at least 48 hours in 32 days)"
  }
  assert {
    condition = (
      one(one(google_container_cluster.this.maintenance_policy).recurring_window).start_time == "2026-11-21T00:00:00Z"
      && timecmp(timeadd(one(one(google_container_cluster.this.maintenance_policy).recurring_window).start_time, "8h"), one(one(google_container_cluster.this.maintenance_policy).recurring_window).end_time) == 0
    )
    error_message = "8-hour window"
  }
}

run "binary_authorization_off_by_default" {
  command = plan

  assert {
    condition     = length(google_container_cluster.this.binary_authorization) == 0
    error_message = "no binary authorization block until the variable is set"
  }
}

run "binary_authorization_when_set" {
  command = plan

  variables {
    binary_authorization_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }

  assert {
    condition     = one(google_container_cluster.this.binary_authorization).evaluation_mode == "PROJECT_SINGLETON_POLICY_ENFORCE"
    error_message = "evaluation mode passed through"
  }
}

run "no_inline_pool_and_import_safe_lifecycle" {
  command = plan

  assert {
    condition     = google_container_cluster.this.remove_default_node_pool == true && google_container_cluster.this.initial_node_count == 1
    error_message = "default pool is created only to be removed"
  }
  assert {
    condition     = one(google_container_cluster.this.node_config).service_account == "gke-nodes@your-project-id.iam.gserviceaccount.com"
    error_message = "even the throwaway pool uses the node service account"
  }
}

run "node_pool_shape" {
  command = plan

  assert {
    condition = (
      google_container_node_pool.this.name == "default-pool"
      && google_container_node_pool.this.cluster == "apps"
      && google_container_node_pool.this.location == "europe-west1-b"
      && google_container_node_pool.this.project == "your-project-id"
    )
    error_message = "pool name, cluster, zone, project"
  }
  assert {
    condition = (
      one(google_container_node_pool.this.autoscaling).min_node_count == 1
      && one(google_container_node_pool.this.autoscaling).max_node_count == 3
      && one(google_container_node_pool.this.autoscaling).location_policy == "ANY"
    )
    error_message = "autoscaling 1 to 3, ANY"
  }
  assert {
    condition = (
      one(google_container_node_pool.this.management).auto_repair == true
      && one(google_container_node_pool.this.management).auto_upgrade == true
      && one(google_container_node_pool.this.upgrade_settings).strategy == "SURGE"
      && one(google_container_node_pool.this.upgrade_settings).max_surge == 1
    )
    error_message = "management and surge upgrades"
  }
}

run "node_config" {
  command = plan

  assert {
    condition = (
      one(google_container_node_pool.this.node_config).machine_type == "e2-standard-2"
      && one(google_container_node_pool.this.node_config).disk_type == "pd-balanced"
      && one(google_container_node_pool.this.node_config).disk_size_gb == 50
      && one(google_container_node_pool.this.node_config).image_type == "COS_CONTAINERD"
    )
    error_message = "machine, disk, image"
  }
  assert {
    condition     = one(google_container_node_pool.this.node_config).spot == true
    error_message = "spot on by default"
  }
  assert {
    condition     = one(google_container_node_pool.this.node_config).service_account == "gke-nodes@your-project-id.iam.gserviceaccount.com"
    error_message = "node service account"
  }
  assert {
    condition     = one(google_container_node_pool.this.node_config).oauth_scopes == toset(["https://www.googleapis.com/auth/cloud-platform", "https://www.googleapis.com/auth/userinfo.email"])
    error_message = "oauth scopes exactly"
  }
  assert {
    condition     = one(google_container_node_pool.this.node_config).metadata == tomap({ "disable-legacy-endpoints" = "true" })
    error_message = "legacy endpoints disabled"
  }
  assert {
    condition = (
      one(one(google_container_node_pool.this.node_config).shielded_instance_config).enable_secure_boot == true
      && one(one(google_container_node_pool.this.node_config).shielded_instance_config).enable_integrity_monitoring == true
      && one(one(google_container_node_pool.this.node_config).workload_metadata_config).mode == "GKE_METADATA"
    )
    error_message = "secure boot, integrity monitoring, GKE metadata server"
  }
  assert {
    condition     = one(google_container_node_pool.this.node_config).resource_labels == tomap({ cluster = "apps" })
    error_message = "node labels"
  }
}

run "spot_can_be_turned_off" {
  command = plan

  variables {
    spot = false
  }

  assert {
    condition     = one(google_container_node_pool.this.node_config).spot == false
    error_message = "on-demand nodes when asked"
  }
}

run "default_compute_service_account_is_refused" {
  command = plan

  variables {
    node_service_account = "123456789012-compute@developer.gserviceaccount.com"
  }

  expect_failures = [var.node_service_account]
}

run "outputs" {
  command = plan

  assert {
    condition     = output.cluster_name == "apps" && output.location == "europe-west1-b"
    error_message = "cluster name and location outputs"
  }
}
