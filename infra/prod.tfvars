# Non-secret values only. tenancy_ocid, the SSH key and the registry credentials come from
# infra/.secrets.env as TF_VAR_* and plain vars.
region           = "eu-milan-1"
compartment_ocid = "ocid1.tenancy.oc1..aaaaaaaacpep3awk2bej7nod6f7tnweleb24n2yocsgy72ysygkm3s5lotra"

# Created once with: oci network public-ip create --lifetime RESERVED --compartment-id <c> --display-name dinner-lb
lb_reserved_ip_ocid = "ocid1.publicip.oc1.eu-milan-1.amaaaaaa3lxe6cqaysc6hbig4rvrjvf7bjztvcoueawlgnnnlpozjtqn746q"

allowed_source_cidr = "93.49.96.116/32"

# Smallest A1.Flex shape. The workshop runs one app pod and one Postgres pod.
node_ocpus      = 1
node_memory_gbs = 6

# Fallback if A1.Flex has no capacity in your AD:
#   node_shape = "VM.Standard.E4.Flex"
#   node_ocpus = 1
#   node_memory_gbs = 8
