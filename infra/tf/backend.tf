terraform {
  backend "local" {
    path = "./terraform.tfstate"
  }
}

provider "oci" {
  region = var.region
}
