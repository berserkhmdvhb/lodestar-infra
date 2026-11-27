# Mock-provider tests: no credentials, no API calls.
mock_provider "google" {}

variables {
  project_id = "your-project-id"
}

run "vpc_is_custom_mode_regional" {
  command = plan

  assert {
    condition     = google_compute_network.this.name == "apps-vpc"
    error_message = "network name default"
  }
  assert {
    condition     = google_compute_network.this.auto_create_subnetworks == false
    error_message = "auto_create_subnetworks must be false"
  }
  assert {
    condition     = google_compute_network.this.routing_mode == "REGIONAL"
    error_message = "routing_mode must be REGIONAL"
  }
}

run "subnet_has_pga_and_secondary_ranges" {
  command = plan

  assert {
    condition     = google_compute_subnetwork.this.name == "apps-subnet" && google_compute_subnetwork.this.region == "europe-west1"
    error_message = "subnet name and region defaults"
  }
  assert {
    condition     = google_compute_subnetwork.this.ip_cidr_range == "10.10.0.0/20"
    error_message = "primary CIDR default"
  }
  assert {
    condition     = google_compute_subnetwork.this.private_ip_google_access == true
    error_message = "Private Google Access must be on"
  }
  assert {
    condition     = length(google_compute_subnetwork.this.secondary_ip_range) == 2
    error_message = "two secondary ranges"
  }
  assert {
    condition = (
      google_compute_subnetwork.this.secondary_ip_range[0].range_name == "pods"
      && google_compute_subnetwork.this.secondary_ip_range[0].ip_cidr_range == "10.20.0.0/16"
      && google_compute_subnetwork.this.secondary_ip_range[1].range_name == "services"
      && google_compute_subnetwork.this.secondary_ip_range[1].ip_cidr_range == "10.30.0.0/20"
    )
    error_message = "secondary ranges: pods then services with the guide CIDRs"
  }
  assert {
    condition     = length(google_compute_subnetwork.this.log_config) == 0
    error_message = "no flow logs here"
  }
}

run "nat_covers_all_subnets_and_logs_errors" {
  command = plan

  assert {
    condition     = google_compute_router.this.name == "apps-router"
    error_message = "router name default"
  }
  assert {
    condition = (
      google_compute_router_nat.this.name == "apps-nat"
      && google_compute_router_nat.this.nat_ip_allocate_option == "AUTO_ONLY"
      && google_compute_router_nat.this.source_subnetwork_ip_ranges_to_nat == "ALL_SUBNETWORKS_ALL_IP_RANGES"
    )
    error_message = "NAT: AUTO_ONLY and all subnetworks, all IP ranges"
  }
  assert {
    condition     = google_compute_router_nat.this.enable_endpoint_independent_mapping == false
    error_message = "endpoint-independent mapping must be false (as live)"
  }
  assert {
    condition = (
      one(google_compute_router_nat.this.log_config).enable == true
      && one(google_compute_router_nat.this.log_config).filter == "ERRORS_ONLY"
    )
    error_message = "NAT logging must be enabled for errors only"
  }
}

run "no_proxy_only_subnet_by_default" {
  command = plan

  assert {
    condition     = length(google_compute_subnetwork.proxy_only) == 0
    error_message = "proxy-only subnet is opt-in"
  }
}

run "proxy_only_subnet_when_enabled" {
  command = plan

  variables {
    enable_proxy_only_subnet = true
  }

  assert {
    condition     = length(google_compute_subnetwork.proxy_only) == 1
    error_message = "proxy-only subnet expected"
  }
  assert {
    condition = (
      google_compute_subnetwork.proxy_only[0].name == "apps-proxy-only"
      && google_compute_subnetwork.proxy_only[0].ip_cidr_range == "10.129.0.0/23"
      && google_compute_subnetwork.proxy_only[0].purpose == "REGIONAL_MANAGED_PROXY"
      && google_compute_subnetwork.proxy_only[0].role == "ACTIVE"
    )
    error_message = "proxy-only subnet name, CIDR, purpose and role"
  }
}

run "outputs_expose_names" {
  command = plan

  assert {
    condition     = output.pods_range_name == "pods" && output.services_range_name == "services"
    error_message = "secondary range names"
  }
  assert {
    condition     = output.network_name == "apps-vpc" && output.subnet_name == "apps-subnet"
    error_message = "network and subnet names"
  }
}
