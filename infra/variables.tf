variable "region" { type = string }
variable "tenancy_ocid" { type = string }
variable "compartment_ocid" { type = string }

variable "k8s_version" {
  type    = string
  default = "v1.34.10"
}

variable "node_shape" {
  type    = string
  default = "VM.Standard.A1.Flex"
}

variable "node_ocpus" {
  type    = number
  default = 2
}

variable "node_memory_gbs" {
  type    = number
  default = 12
}

variable "node_count" {
  type    = number
  default = 1
}

variable "node_boot_volume_gbs" {
  type    = number
  default = 50
}

# Created by hand once with `oci network public-ip create --lifetime RESERVED`. Kept outside
# Terraform on purpose: it survives destroy and the Cloudflare A record never changes.
variable "lb_reserved_ip_ocid" {
  type = string
}

variable "allowed_source_cidr" {
  type    = string
  default = "93.49.96.116/32"
}

variable "ssh_public_key" {
  type        = string
  description = "Public key registered on the nodes. Injected as TF_VAR_ssh_public_key."
}
