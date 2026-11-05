# Step 3: Configure the repository

At the end of this step, `infra/.secrets.env` holds the few values OCI will not give you, the rest is derived from your account, and `make plan` shows what OpenTofu is about to create.

**Time:** 10 minutes.

## 3.1 Create `infra/.secrets.env`

```bash
cd infra
make oke-secrets      # copies .secrets.example, never overwrites an existing file
make oke-bootstrap    # prints the values you need, and where to get them
```

`make oke-bootstrap` reads your OCI profile and prints your tenancy, user, region and Object Storage namespace, then lists the two pages where only the Console can create a token.

This is the template you start from:

```bash title="infra/.secrets.example"
--8<-- "infra/.secrets.example"
```

Fill in these values:

| Variable | Used by | Value | From |
|---|---|---|---|
| `HOST` | `oke-deploy`, `oke-smoke` | The host name you serve, e.g. `dinner.example.com` | [2.6](dns-tls.md#26-use-your-hostname-in-the-repository) |
| `ACME_EMAIL` | `oke-up` | A real email address | [2.4](dns-tls.md#24-choose-the-acme-email) |
| `CLOUDFLARE_API_TOKEN` | `oke-up` | The Cloudflare token | [2.3](dns-tls.md#23-create-the-cloudflare-api-token) |
| `OCIR_USERNAME` | `oke-push`, `oke-deploy` | `<tenancy-namespace>/<username>` | [1.6](oci-account.md#16-work-out-your-registry-host-and-username) |
| `OCIR_AUTH_TOKEN` | `oke-push`, `oke-deploy` | The OCI auth token | [1.5](oci-account.md#15-generate-an-auth-token-for-the-registry) |
| `TF_VAR_ssh_public_key` | OpenTofu, optional | The content of e.g. `~/.ssh/id_ed25519.pub`, **without quotes** | Your machine |

Five values. Everything else comes from your account.

### What you no longer have to paste

| Value | Where it now comes from |
|---|---|
| Tenancy OCID | `tenancy=` in `~/.oci/config`, read by `make` |
| Region | `region=` in `~/.oci/config` |
| Compartment | The tenancy (root compartment). Set `compartment_ocid` only if you use another one |
| Object Storage namespace | `oci os ns get`, through the `oci_objectstorage_namespace` data source |
| `OCIR_IMAGE` | Derived from `OCIR_USERNAME`: `<region>.ocir.io/<namespace>/dinner-roulette:latest` |
| Your public IP (`allowed_source_cidr`) | `make oke-tfvars`, from `checkip.amazonaws.com` |
| Reserved IP OCID | `make oke-tfvars`, from the reserved IP named `dinner-lb` |

The tenancy OCID is the one thing OpenTofu cannot look up: `oci_identity_tenancy` requires `tenancy_id` and the provider does not expose its own. `make` reads it from the OCI profile instead.

Notes on individual values:

- **`TF_VAR_` prefix.** OpenTofu automatically maps an environment variable `TF_VAR_<name>` to the input variable `<name>`. `.secrets.env` is exported by the `Makefile`, so any `TF_VAR_*` line reaches OpenTofu. That is also how you override a default such as `node_shape`.
- **SSH key.** It is registered on the worker node, but the node lives in a private subnet without a public IP, so you would need a bastion to use it. If you do not need it, **delete the line or comment it out**. Leaving the placeholder `ssh-ed25519 AAAA... you@laptop` in place makes OKE reject the node pool.
- **`OCIR_IMAGE` is optional.** Set it only to deploy a tag other than `:latest`. Leave it out and `make` builds it from `OCIR_USERNAME` and the region, so the registry host and the credentials cannot drift apart.

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
make -f Makefile -f - token-length <<'EOF'
token-length:
	@printf %s "$$OCIR_AUTH_TOKEN" | wc -c
EOF
```

!!! note "Why `-f Makefile -f -`"
    `make --eval` does not exist in GNU make 3.81, which is what macOS ships. Reading a second makefile from stdin works everywhere. The first `-f` is needed so `.secrets.env` is still included.

## 3.2 Run `make oke-tfvars`

There is no `prod.tfvars` to edit. The values that describe *your* account are found, not typed:

```bash
make oke-tfvars
```

It writes `infra/tf/workshop.auto.tfvars`, which OpenTofu loads automatically because of the `.auto.tfvars` suffix. It is git-ignored and safe to delete; run it again whenever your public IP changes.

```hcl title="infra/tf/workshop.auto.tfvars (generated)"
region              = "eu-milan-1"
allowed_source_cidr = "203.0.113.25/32"
lb_reserved_ip_ocid = "ocid1.publicip.oc1.eu-milan-1.amaaaa…"
```

| Value | How it is found |
|---|---|
| `region` | `region=` in `~/.oci/config` |
| `allowed_source_cidr` | `https://checkip.amazonaws.com`, plus `/32` |
| `lb_reserved_ip_ocid` | The `RESERVED` public IP named `dinner-lb`, or omitted if there is none |

If no reserved IP is found, `oke-up` still works: the load balancer gets an ephemeral address and `oke-up` prints it at the end so you can point the A record at it. That address changes on every `oke-up`, so create one when you are past experimenting:

```bash
oci network public-ip create --lifetime RESERVED --display-name dinner-lb
```

All the input variables, from `infra/tf/variables.tf`:

| Variable | Default | Meaning |
|---|---|---|
| `region` | from `~/.oci/config` | OCI region identifier, such as `eu-milan-1` |
| `tenancy_ocid` | from `~/.oci/config` | Used to look up the availability domains |
| `compartment_ocid` | the tenancy | Compartment for every resource |
| `lb_reserved_ip_ocid` | found by `oke-tfvars` | OCID of the reserved public IP |
| `allowed_source_cidr` | found by `oke-tfvars` | The only source allowed on 6443 and 443 |
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

The repository is region-agnostic now. Everything follows `region=` in `~/.oci/config`:

1. **Nothing to change in the OpenTofu files.** The service gateway route uses `data.oci_core_services.all.services[0].cidr_block` instead of a region key such as `all-lin-services-…`, so it resolves in every region.
2. **The reserved IP belongs to one region.** Run `make oke-tfvars` in the new region, or create one there first with `oci network public-ip create --lifetime RESERVED --display-name dinner-lb`. Without it you get an ephemeral address.
3. **The OCIR host follows the region.** `OCIR_IMAGE` is derived from the region, so nothing to edit. If you set it by hand, update the host.
4. **CI needs the matching variables.** Set `OCIR_REGION`, `OCIR_NAMESPACE` and `HOST` as repository variables ([step 4](image.md#configure-the-repository-on-github)).

Remember that Always Free A1 capacity is available only in your home region.

## 3.3 Validate with `make plan`

```bash
make init     # downloads the OCI provider, pinned by .terraform.lock.hcl
make plan
```

`init` creates `infra/tf/.terraform/`. `plan` reads `workshop.auto.tfvars`, the `TF_VAR_*` values and the defaults in `variables.tf`, then prints what would be created without changing anything. On an empty compartment it ends with:

```text
Plan: 25 to add, 0 to change, 0 to destroy.
```

That is 12 network resources (VCN, three gateways, two route tables, two subnets, one security list, three NSGs), 11 NSG rules, the cluster and the node pool. Values such as the node image show as `(known after apply)`, because they depend on the cluster that does not exist yet.

!!! note
    `make plan` checks `workshop.auto.tfvars` and `HOST` first, and tells you what to run if either is missing. If OpenTofu prompts for a variable, you ran `tofu` directly instead of `make`.

!!! danger "The state file is precious"
    OpenTofu records what it created in `infra/tf/terraform.tfstate`, on your laptop. The file is git-ignored and blocked by the pre-commit hook, because it contains resource details. Without it, `make oke-down` cannot destroy anything, and you would have to delete the cluster and the network by hand in the Console. Back it up if you switch machines.

## Checklist

- [x] `infra/.secrets.env` filled, with no quotes and no placeholder left
- [x] `make oke-tfvars` ran, so `infra/tf/workshop.auto.tfvars` exists
- [x] `make oke-bootstrap` shows your tenancy and namespace
- [x] `make plan` ends with `Plan: 25 to add`

Next: [Step 4: Publish the image](image.md).
