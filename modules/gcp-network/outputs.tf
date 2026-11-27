output "network_self_link" {
  description = "Self link of the VPC network."
  value       = google_compute_network.this.self_link
}

output "network_name" {
  description = "Name of the VPC network."
  value       = google_compute_network.this.name
}

output "subnet_self_link" {
  description = "Self link of the primary subnet."
  value       = google_compute_subnetwork.this.self_link
}

output "subnet_name" {
  description = "Name of the primary subnet."
  value       = google_compute_subnetwork.this.name
}

output "pods_range_name" {
  description = "Name of the secondary range for pods."
  value       = one([for r in google_compute_subnetwork.this.secondary_ip_range : r.range_name if r.range_name == "pods"])
}

output "services_range_name" {
  description = "Name of the secondary range for services."
  value       = one([for r in google_compute_subnetwork.this.secondary_ip_range : r.range_name if r.range_name == "services"])
}
