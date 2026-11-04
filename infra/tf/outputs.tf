output "cluster_id" {
  value = oci_containerengine_cluster.main.id
}

output "region" {
  value = var.region
}

output "lb_nsg_id" {
  value = oci_core_network_security_group.lb.id
}

output "host" {
  value = var.host
}

output "compartment_id" {
  value = local.compartment_id
}

output "ocir_image" {
  value       = local.ocir_image
  description = "The image reference derived from the region and the Object Storage namespace."
}

output "ocir_host" {
  value = local.ocir_host
}

output "namespace" {
  value = local.namespace
}

output "lb_reserved_ip_ocid" {
  value = var.lb_reserved_ip_ocid
}

# When no reserved IP is passed, the load balancer gets an ephemeral one created by the
# cloud-controller-manager on the first ingress-nginx install.

# Always a string, never null: "" means no reserved IP. `tofu output -raw` of a null output
# is an error, so the Makefile must not have to guess, and `test -n` is the whole check.
output "lb_ip" {
  value       = var.lb_reserved_ip_ocid == null ? "" : data.oci_core_public_ip.lb[0].ip_address
  description = "Reserved IP address, or empty when none is configured."
}

output "lb_reserved_ip" {
  value       = try(data.oci_core_public_ip.lb[0].ip_address, null)
  description = "Point the Cloudflare A record for var.host at this address. Null when no reserved IP is set."
}

data "oci_core_public_ip" "lb" {
  count = var.lb_reserved_ip_ocid == null ? 0 : 1
  id    = var.lb_reserved_ip_ocid
}
