# Step 3: Configure the repository

At the end of this step, the repository describes your account: secrets in `infra/.secrets.env` (never committed), non-secret settings in `infra/tf/prod.tfvars`, and `make plan` shows what Terraform is about to create.

**Time:** 10 minutes.

## 3.1 Create `infra/.secrets.env`

```bash
cd infra
cp .secrets.example .secrets.env
${EDITOR:-nano} .secrets.env
```

This is the template you start from:

```bash title="infra/.secrets.example"
--8<-- "infra/.secrets.example"
```

Fill in every value:

| Variable | Used by | Value | From |
|---|---|---|---|
| `TF_VAR_tenancy_ocid` | Terraform (`apply`, `oke-up`, `oke-cidr`, `oke-down`) | Your tenancy OCID | [1.2](oci-account.md#12-collect-your-identifiers) |
| `TF_VAR_ssh_public_key` | Terraform, optional | The content of e.g. `~/.ssh/id_ed25519.pub`, **without quotes** | Your machine |
| `ACME_EMAIL` | `oke-up` | A real email address | [2.4](dns-tls.md#24-choose-the-acme-email) |
| `CLOUDFLARE_API_TOKEN` | `oke-up` | The Cloudflare token | [2.3](dns-tls.md#23-create-the-cloudflare-api-token) |
| `OCIR_USERNAME` | `oke-push`, `oke-deploy` | `<tenancy-namespace>/<username>` | [1.6](oci-account.md#16-work-out-your-registry-host-and-username) |
| `OCIR_AUTH_TOKEN` | `oke-push`, `oke-deploy` | The OCI auth token | [1.5](oci-account.md#15-generate-an-auth-token-for-the-registry) |
| `OCIR_IMAGE` | `oke-push`, `oke-deploy` | `<region>.ocir.io/<tenancy-namespace>/dinner-roulette:latest` | [1.6](oci-account.md#16-work-out-your-registry-host-and-username) |

Notes on individual values:

- **`TF_VAR_` prefix.** Terraform automatically maps an environment variable `TF_VAR_<name>` to the input variable `<name>`. That is how the tenancy OCID and the SSH key reach Terraform without being written in `prod.tfvars`.
- **SSH key.** It is registered on the worker node, but the node lives in a private subnet without a public IP, so you would need a bastion to use it. If you do not need it, **delete the line or comment it out**. Leaving the placeholder `ssh-ed25519 AAAA... you@laptop` in place makes OKE reject the node pool.
- **`OCIR_IMAGE`** includes the tag. The registry host in it must match the region you push to. `make` derives the registry server for `docker login` and for the pull Secret from the first part of this value.

### How `make` reads the file

The `Makefile` starts with:

```make
-include .secrets.env
export
```

Every line of the file is parsed as a **make variable assignment**, and `export` passes all variables to every command the targets run. This has consequences:

- **No quotes.** make keeps quotes as part of the value. A quoted SSH key reaches OKE with the quotes and is rejected.
- **Spaces are fine.** Everything after the first `=` is the value, which is why an unquoted SSH key with spaces works.
- **The file wins over your shell.** A variable defined in the file overrides an environment variable with the same name. In CI the file does not exist, so the environment is used.
- **Read once per `make` invocation.** If you edit the file while `make oke-up` is running, the running command keeps the old values.
- **Path.** `-include` looks for the file in the directory make runs in, so run make from `infra/`, or use `make -C infra …`, which changes into `infra/` first.

### Special characters in values

Two characters have a meaning for make:

- `#` starts a comment: everything after it is silently dropped;
- `$` starts a variable reference: `$abc` becomes the value of the make variable `a`, followed by `bc`.

OCI auth tokens are random strings and can contain both. Escape them in `.secrets.env`, writing `\#` for `#` and `$$` for `$`, or generate a new token without them. To check what make actually sees, compare the length it prints with the length of your token:

```bash
make --eval 'token-length: ; @printf %s "$$OCIR_AUTH_TOKEN" | wc -c' token-length
```

## 3.2 Edit `infra/tf/prod.tfvars`

`prod.tfvars` holds the non-secret settings and is committed. Replace the values with yours:

```hcl title="infra/tf/prod.tfvars"
# Non-secret values only. tenancy_ocid, the SSH key and the registry credentials come from
# infra/.secrets.env as TF_VAR_* and plain vars.
region           = "eu-milan-1"
compartment_ocid = "ocid1.tenancy.oc1..aaaa…"    # the tenancy OCID for the root compartment

# Reserved IP created in step 1.7: its OCID, not its address
lb_reserved_ip_ocid = "ocid1.publicip.oc1.eu-milan-1.amaaaa…"

# The only block that reaches the API endpoint and the load balancer
allowed_source_cidr = "203.0.113.25/32"

# Worker node, see "Choose the node shape" below
node_shape      = "VM.Standard.A1.Flex"
node_ocpus      = 2
node_memory_gbs = 12

# Uncomment if the default is no longer offered by OKE (see step 1.9)
# k8s_version = "v1.34.10"
```

All the input variables, from `infra/tf/variables.tf`:

| Variable | Default | Meaning |
|---|---|---|
| `region` | none, required | OCI region identifier, such as `eu-milan-1` |
| `tenancy_ocid` | none, from `TF_VAR_tenancy_ocid` | Used to look up the availability domains |
| `compartment_ocid` | none, required | Compartment for every resource |
| `lb_reserved_ip_ocid` | none, required | OCID of the reserved public IP |
| `allowed_source_cidr` | none, required | The only source allowed on 6443 and 443 |
| `k8s_version` | `v1.34.10` | Version of the control plane and the node pool |
| `node_shape` | `VM.Standard.A1.Flex` | Compute shape of the worker node |
| `node_ocpus` | `2` | OCPUs of the worker node |
| `node_memory_gbs` | `12` | Memory of the worker node, in GB |
| `node_count` | `1` | Number of worker nodes |
| `ssh_public_key` | `null` | Optional key for the node, from `TF_VAR_ssh_public_key` |

### Choose the node shape

| Shape | CPU architecture | Cost | Availability |
|---|---|---|---|
| `VM.Standard.A1.Flex` | arm64 (Ampere) | Always Free up to 2 OCPUs and 12 GB per tenancy, home region only | Often out of capacity |
| `VM.Standard.E3.Flex` | amd64 (AMD) | Paid | Usually available |
| `VM.Standard.E4.Flex` | amd64 (AMD) | Paid | Usually available |
| `VM.Standard.E5.Flex` | amd64 (AMD) | Paid | Usually available |

**How big?** The node runs the Kubernetes system pods (Flannel, kube-proxy, CoreDNS, the CSI node plugin), three cert-manager pods, the ingress-nginx controller, the CNPG operator, PostgreSQL and the app. 1 OCPU with 6 to 8 GB of memory is enough for the workshop. 2 OCPUs with 12 GB is comfortable. On AMD shapes one OCPU is one physical core with two hardware threads, so Kubernetes sees 2 vCPUs. On A1, one OCPU is one core.

**The architecture must match the image.** A1 nodes run arm64 images and E-series nodes run amd64 images. The GitHub `build` workflow pushes a multi-architecture image that works on both. `make oke-push` builds only for the architecture of your own machine. See [step 4](image.md#make-sure-the-architecture-matches).

**The node image is picked automatically.** You never choose an OS image. `cluster.tf` asks OKE which images it offers for the cluster and keeps the ones that are OKE images for the cluster's Kubernetes version, Oracle Linux 9, not GPU, and of the right architecture for the shape. Then it takes the newest.

??? example "infra/tf/cluster.tf"
    ```hcl
    --8<-- "infra/tf/cluster.tf"
    ```

### If you use another region

The repository assumes Milan (`eu-milan-1`). For another region, change it in all of these places:

1. `region` in `infra/tf/prod.tfvars`.
2. The host in `OCIR_IMAGE`, in `infra/.secrets.env`, and the `OCIR_REGION` repository variable for CI.
3. The reserved IP, which belongs to one region: create a new one there.
4. **`infra/tf/network.tf`**: the private route table sends Oracle services traffic to `all-lin-services-in-oracle-services-network`, and `lin` is Milan's region key. Replace `lin` with your region's key, in lower case, or use the value the code already looks up, `data.oci_core_services.all.services[0].cidr_block`, which works in every region. To find a region's key:

    ```bash
    oci iam region list --query "data[?name=='eu-frankfurt-1'].key" --raw-output    # FRA
    ```

Remember that Always Free A1 capacity is available only in your home region.

## 3.3 Validate with `make plan`

```bash
make init     # downloads the OCI provider, pinned by .terraform.lock.hcl
make plan
```

`init` creates `infra/tf/.terraform/`. `plan` reads `prod.tfvars` plus the `TF_VAR_*` values and prints what would be created, without changing anything. On an empty compartment it ends with:

```text
Plan: 25 to add, 0 to change, 0 to destroy.
```

That is 12 network resources (VCN, three gateways, two route tables, two subnets, one security list, three NSGs), 11 NSG rules, the cluster and the node pool. Values such as the node image show as `(known after apply)`, because they depend on the cluster that does not exist yet.

!!! note
    `make plan` does not check `.secrets.env` first. If `TF_VAR_tenancy_ocid` is missing, Terraform prompts for `var.tenancy_ocid` interactively. Press ++ctrl+c++ and fix the file.

!!! danger "The state file is precious"
    Terraform records what it created in `infra/tf/terraform.tfstate`, on your laptop. The file is git-ignored and blocked by the pre-commit hook, because it contains resource details. Without it, `make oke-down` cannot destroy anything, and you would have to delete the cluster and the network by hand in the Console. Back it up if you switch machines.

## Checklist

- [x] `infra/.secrets.env` filled, with no quotes and no placeholder left
- [x] `infra/tf/prod.tfvars` with your region, compartment, reserved IP OCID, source CIDR and shape
- [x] the region-specific bits changed if you are not in Milan
- [x] `make plan` ends with `Plan: 25 to add`

Next: [Step 4: Publish the image](image.md).
