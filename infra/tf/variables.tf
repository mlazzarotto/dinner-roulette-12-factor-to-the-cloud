variable "tenancy_ocid" {
  type        = string
  description = "Your tenancy OCID. Injected as TF_VAR_tenancy_ocid by the Makefile from ~/.oci/config."
}

variable "compartment_ocid" {
  type        = string
  default     = null
  description = "Compartment for every resource. Defaults to the tenancy (the root compartment)."
}

variable "host" {
  type        = string
  description = "Public host name served by the load balancer, e.g. dinner.example.com. Used by the ingress and the smoke test."
}

variable "region" {
  type        = string
  default     = null
  description = "OCI region identifier. Defaults to the region in your OCI profile."
}

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

# Optional. Created by hand once with `oci network public-ip create --lifetime RESERVED`, and
# kept outside OpenTofu on purpose: it survives destroy, so the DNS record never changes.
# Without it the load balancer gets an ephemeral address, and `oke-up` prints it so you can
# point the A record at it. An ephemeral address changes on every `oke-up`.
variable "lb_reserved_ip_ocid" {
  type    = string
  default = null
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
