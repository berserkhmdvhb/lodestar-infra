output "network_self_link" {
  value = google_compute_network.this.self_link
}

output "network_name" {
  value = google_compute_network.this.name
}

output "subnet_self_link" {
  value = google_compute_subnetwork.this.self_link
}

output "subnet_name" {
  value = google_compute_subnetwork.this.name
}

output "pods_range_name" {
  value = one([for r in google_compute_subnetwork.this.secondary_ip_range : r.range_name if r.range_name == "pods"])
}

output "services_range_name" {
  value = one([for r in google_compute_subnetwork.this.secondary_ip_range : r.range_name if r.range_name == "services"])
}
