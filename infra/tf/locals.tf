# Everything that OpenTofu can work out from your OCI profile lives here, so a fresh clone
# needs no OCIDs. The tenancy OCID is the exception: data.oci_identity_tenancy.tenancy_id is
# required and cannot be read from the provider config, so the Makefile passes it in as
# TF_VAR_tenancy_ocid, taken from ~/.oci/config.

# The tenancy's Object Storage namespace, the first segment of every OCIR image path and
# username. Not the tenancy name: a short random string such as axgow5uurkov.
data "oci_objectstorage_namespace" "this" {
  compartment_id = var.tenancy_ocid
}

locals {
  # Root compartment by default: a personal tenancy has no others, and the workshop puts
  # every resource there.
  compartment_id = coalesce(var.compartment_ocid, var.tenancy_ocid)
  namespace      = data.oci_objectstorage_namespace.this.namespace

  # var.region is passed by the Makefile from ~/.oci/config. When it is null the provider
  # still talks to the right region through the profile, but the OCIR host cannot be built,
  # so the outputs stay null and `check-registry` stops with a clear message.
  ocir_host  = var.region == null ? null : "${var.region}.ocir.io"
  ocir_image = local.ocir_host == null ? null : "${local.ocir_host}/${local.namespace}/dinner-roulette:latest"
}
