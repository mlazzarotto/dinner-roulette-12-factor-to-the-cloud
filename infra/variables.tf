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

# Created by hand once with `oci network public-ip create --lifetime RESERVED`. Kept outside
# Terraform on purpose: it survives destroy and the Cloudflare A record never changes.
variable "lb_reserved_ip_ocid" {
  type = string
}

variable "allowed_source_cidr" {
  type        = string
  description = "Only this block reaches the API endpoint and the load balancer."
}

variable "ssh_public_key" {
  type        = string
  default     = null
  description = "Optional public key registered on the nodes. Injected as TF_VAR_ssh_public_key."
}
