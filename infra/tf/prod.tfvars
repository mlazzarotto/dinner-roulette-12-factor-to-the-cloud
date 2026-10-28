# Non-secret values only. tenancy_ocid, the SSH key and the registry credentials come from
# infra/.secrets.env as TF_VAR_* and plain vars.
region           = "eu-milan-1"
compartment_ocid = "ocid1.tenancy.oc1..aaaaaaaahyvfwviddsjaegbzmdbya5rthjscqxnipegnkebnkurd6po7t6fq"

# Reserved IP dinner-lb, 129.152.10.43. Created once; survives terraform destroy.
lb_reserved_ip_ocid = "ocid1.publicip.oc1.eu-milan-1.amaaaaaaipr3ocaaroa6wng4lddqyoxdvvssn2mj6sudyuphbhpj4v6djvgq"

allowed_source_cidr = "95.233.46.248/32"

# Smallest A1.Flex shape. The workshop runs one app pod and one Postgres pod.
node_ocpus      = 1
node_memory_gbs = 6

# Fallback if A1.Flex has no capacity in your AD:
#   node_shape = "VM.Standard.E4.Flex"
#   node_ocpus = 1
#   node_memory_gbs = 8
