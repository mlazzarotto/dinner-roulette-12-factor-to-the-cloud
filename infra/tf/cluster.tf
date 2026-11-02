resource "oci_containerengine_cluster" "main" {
  compartment_id     = var.compartment_ocid
  kubernetes_version = var.k8s_version
  name               = "dinner-roulette"
  vcn_id             = oci_core_vcn.main.id
  type               = "BASIC_CLUSTER"

  cluster_pod_network_options {
    cni_type = "FLANNEL_OVERLAY"
  }

  endpoint_config {
    subnet_id            = oci_core_subnet.public.id
    nsg_ids              = [oci_core_network_security_group.endpoint.id]
    is_public_ip_enabled = true
  }

  options {
    service_lb_subnet_ids = [oci_core_subnet.public.id]
    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }
  }
}

resource "oci_containerengine_node_pool" "main" {
  compartment_id     = var.compartment_ocid
  cluster_id         = oci_containerengine_cluster.main.id
  kubernetes_version = var.k8s_version
  name               = "dinner-nodes"

  node_shape = var.node_shape

  node_shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_gbs
  }

  node_source_details {
    source_type = "IMAGE"
    image_id    = local.node_image_id
  }

  node_config_details {
    size = var.node_count

    placement_configs {
      availability_domain = local.ad
      subnet_id           = oci_core_subnet.private.id
    }

    node_pool_pod_network_option_details {
      cni_type = "FLANNEL_OVERLAY"
    }

    nsg_ids = [oci_core_network_security_group.nodes.id]
  }

  node_eviction_node_pool_settings {
    eviction_grace_duration = "PT0S"
  }

  ssh_public_key = var.ssh_public_key
}

# OKE images only: the API rejects a plain Oracle Linux image. Match the cluster version and
# the node architecture (A1.Flex is aarch64, E4.Flex is x86_64).
data "oci_containerengine_node_pool_option" "main" {
  node_pool_option_id = oci_containerengine_cluster.main.id
  compartment_id      = var.compartment_ocid
}

locals {
  k8s_release = trimprefix(var.k8s_version, "v")
  arm_shape   = var.node_shape == "VM.Standard.A1.Flex"

  oke_node_images = {
    for s in data.oci_containerengine_node_pool_option.main.sources : s.source_name => s.image_id
    if s.source_type == "IMAGE"
    && can(regex("-OKE-${local.k8s_release}-", s.source_name))
    && can(regex("^Oracle-Linux-9\\.[0-9]+-", s.source_name))
    && !can(regex("GPU", s.source_name))
    && can(regex("^Oracle-Linux-9\\.[0-9]+-aarch64-", s.source_name)) == local.arm_shape
  }

  # Names embed the build date, so the last one alphabetically is the newest.
  oke_node_image_names = sort(keys(local.oke_node_images))
  node_image_id        = local.oke_node_images[local.oke_node_image_names[length(local.oke_node_image_names) - 1]]
}

