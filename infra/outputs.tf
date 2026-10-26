# Provided by the OKE CSI add-on, so it cannot be declared here.
output "storage_class" {
  value       = "oci-bv"
  description = "Block volume StorageClass provided by the OKE CSI add-on."
}

output "cluster_id" {
  value = oci_containerengine_cluster.main.id
}

output "lb_reserved_ip" {
  value       = data.oci_core_public_ip.lb.ip_address
  description = "Point the Cloudflare A record dinner.lazzarotto.dev at this address."
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

