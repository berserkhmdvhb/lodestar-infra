output "cluster_name" {
  description = "Name of the GKE cluster."
  value       = google_container_cluster.this.name
}

output "location" {
  description = "Location of the GKE cluster."
  value       = google_container_cluster.this.location
}

output "dns_endpoint" {
  description = "DNS-based control-plane endpoint (host name, no scheme)."
  value       = one(one(google_container_cluster.this.control_plane_endpoints_config).dns_endpoint_config).endpoint
}
