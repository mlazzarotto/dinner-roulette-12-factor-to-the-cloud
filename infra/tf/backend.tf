terraform {
  backend "local" {
    path = "./terraform.tfstate"
  }
}

# No tenancy_ocid or region here on purpose: the provider reads them from the OCI profile
# in ~/.oci/config (OCI_CLI_PROFILE picks another profile), the same one the `oci` CLI uses.
# The Makefile exports TF_VAR_tenancy_ocid from that file, because a few data sources need
# the OCID explicitly, and the S3-compatible profile trick does not always map cleanly.
provider "oci" {
  region = var.region
}
