output "cluster_id" {
  value = oci_containerengine_cluster.main.id
}

output "lb_reserved_ip" {
  value       = data.oci_core_public_ip.lb.ip_address
  description = "Point the Cloudflare A record dinner.alessandroperetti.dev at this address."
}

output "region" {
  value = var.region
}

output "lb_nsg_id" {
  value = oci_core_network_security_group.lb.id
}

output "lb_reserved_ip_ocid" {
  value = var.lb_reserved_ip_ocid
}

data "oci_core_public_ip" "lb" {
  id = var.lb_reserved_ip_ocid
}

