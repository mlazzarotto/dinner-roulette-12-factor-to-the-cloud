# Step 1: Prepare your Oracle Cloud account

At the end of this step, Terraform and the OCI CLI can authenticate to your tenancy, Docker can log in to the Oracle container registry (OCIR), and you have a reserved public IP for the load balancer.

**Time:** 20 to 40 minutes, once.

## 1.1 Create the account

Sign up at [oracle.com/cloud/free](https://www.oracle.com/cloud/free/). A credit card is needed for identity verification.

!!! warning "Choose the home region carefully"
    The **home region** is picked at sign-up and cannot be changed later. Always Free Ampere A1 capacity exists only in the home region. The repository uses `eu-milan-1` (Milan). Any region works, but if you choose another one you must change the region in a few places, as described in [step 3](configure.md#if-you-use-another-region).

An Always Free account can create only Always Free resources. If you want the paid fallback shapes for when A1 has no capacity (see [costs](index.md#what-it-costs)), upgrade to Pay As You Go under **Billing & Cost Management → Upgrade and Manage Payment**. Always Free resources stay free after the upgrade.

## 1.2 Collect your identifiers

OCI identifies every resource with an **OCID**, a long string such as `ocid1.tenancy.oc1..aaaa…`. Collect these values; you will use them in the next steps.

| Value | Where to find it in the Console | Example | Used for |
|---|---|---|---|
| Tenancy OCID | Profile menu (top right) → **Tenancy: <name>** → OCID → Copy | `ocid1.tenancy.oc1..aaaa…` | `TF_VAR_tenancy_ocid`, often also `compartment_ocid` |
| Home region identifier | Tenancy details → **Home region** | `eu-milan-1` | `region` in `prod.tfvars`, the OCIR host name |
| Object Storage namespace | Tenancy details → **Object storage namespace** | `axabcdef1234` | The OCIR path and username |
| User OCID | Profile menu → **My profile** → OCID | `ocid1.user.oc1..aaaa…` | The API key configuration |
| Username | Shown at the top of the Profile menu | `you@example.com` | The OCIR username |

The **Object Storage namespace**, also called the tenancy namespace, is a short random string. It is not your tenancy name. OCIR uses it as the first part of every image path.

## 1.3 Choose a compartment

A **compartment** is a folder for resources, with its own access policies. The repository puts everything in the **root compartment**: `compartment_ocid` in `prod.tfvars` is the tenancy OCID itself. That is fine for a personal tenancy.

To keep the workshop separate, create a compartment and use its OCID as `compartment_ocid` instead:

```bash
oci iam compartment create \
  --compartment-id <tenancy-ocid> \
  --name dinner-roulette \
  --description "Dinner Roulette workshop" \
  --query 'data.id' --raw-output
```

Use the **same compartment** for the reserved IP in [1.7](#17-reserve-a-public-ip). OKE expects the reserved IP to be in the cluster's compartment.

!!! info "Permissions"
    This guide assumes your user is in the tenancy's **Administrators** group, which is the case for the user that created the tenancy. Otherwise an administrator has to grant your group the OKE policies, so that it can manage clusters, networking, instances, load balancers, volumes and repositories in the compartment. Oracle lists them in [Policy Configuration for Cluster Creation and Deployment](https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengpolicyconfig.htm).

## 1.4 Create an API signing key and configure the OCI CLI

Terraform's OCI provider and the OCI CLI authenticate with an **API signing key**: an RSA key pair whose public half is registered on your user. Both tools read the `[DEFAULT]` profile in `~/.oci/config`. `infra/tf/backend.tf` sets only the region, and everything else comes from that file.

=== "Console (recommended)"

    1. Open the Profile menu → **My profile** → **API keys** (on newer consoles, under the **Tokens and keys** tab) → **Add API key**.
    2. Select **Generate API key pair**, click **Download private key**, then **Add**.
    3. The Console shows a **Configuration file preview**. Copy it.
    4. Move the key and write the configuration:

        ```bash
        mkdir -p ~/.oci
        mv ~/Downloads/*.pem ~/.oci/oci_api_key.pem   # adjust to the file you downloaded
        chmod 600 ~/.oci/oci_api_key.pem
        ${EDITOR:-nano} ~/.oci/config
        ```

        Paste the preview and set `key_file`:

        ```ini title="~/.oci/config"
        [DEFAULT]
        user=ocid1.user.oc1..aaaa…
        fingerprint=12:34:56:78:9a:bc:de:f0:12:34:56:78:9a:bc:de:f0
        tenancy=ocid1.tenancy.oc1..aaaa…
        region=eu-milan-1
        key_file=~/.oci/oci_api_key.pem
        ```

        ```bash
        chmod 600 ~/.oci/config
        ```

=== "OCI CLI"

    ```bash
    oci setup config
    ```

    The wizard asks for the config location (accept `~/.oci/config`), your user OCID, your tenancy OCID and your region. Answer `Y` to generate a new key pair. When it asks for a passphrase, type `N/A` for none, or see the note below.

    Then register the public key: Profile menu → **My profile** → **API keys** → **Add API key** → **Paste a public key**, and paste the content of `~/.oci/oci_api_key_public.pem`. The fingerprint shown by the Console must match the `fingerprint=` line that the wizard wrote.

!!! danger "Encrypted keys need `pass_phrase`"
    Terraform cannot prompt for a passphrase. If your private key is encrypted and the profile has no passphrase, `terraform plan` stops with:

    ```text
    Error: can not create client, bad configuration: did not find a proper configuration for private key
    ```

    Either use a key without passphrase, or add `pass_phrase=<your passphrase>` to the `[DEFAULT]` profile. The OCI CLI reads the same line, which also stops `kubectl` from asking for the passphrase on every command against OKE.

### Check it

```bash
oci iam region list --output table     # any successful answer means authentication works
oci os ns get                          # prints your Object Storage namespace
```

A `NotAuthenticated` (401) error means the key, the fingerprint, the user OCID or the tenancy OCID do not match each other. See [Troubleshooting](../troubleshooting.md#notauthenticated-401-from-oci).

This one key is used by:

- **Terraform**, to create and destroy the infrastructure;
- **`oci ce cluster create-kubeconfig`**, to write `infra/kubeconfig`;
- **`kubectl`**, every time it talks to OKE: the kubeconfig runs `oci ce cluster generate-token` to get a short-lived token. Any machine that uses this kubeconfig needs the OCI CLI and a valid profile;
- the `Makefile`'s final check for leftover load balancers in `oke-down`.

## 1.5 Generate an auth token for the registry

OCIR does not accept API keys. Docker and Kubernetes log in with a username and an **auth token**, which works like a password.

1. Profile menu → **My profile** → **Auth tokens** (or **Tokens and keys** → Auth tokens) → **Generate token**.
2. Description: `dinner-ocir`. Click **Generate token**.
3. **Copy the token now.** Oracle shows it only once.

The same with the CLI:

```bash
oci iam auth-token create --user-id <user-ocid> --description dinner-ocir \
  --query 'data.token' --raw-output
```

Each user can have at most two auth tokens. The token is used in three places: `docker login` for `make oke-push`, the `OCIR_AUTH_TOKEN` secret of the GitHub `build` workflow, and the `ocir` pull Secret in the cluster. Keep it as secret as a password.

!!! tip
    Auth tokens can contain characters such as `$`, `#` or `;`. That matters when you put the token in `infra/.secrets.env`, which `make` reads. See [step 3](configure.md#special-characters-in-values).

## 1.6 Work out your registry host and username

| What | Format | Example |
|---|---|---|
| Registry host | `<region-identifier>.ocir.io` | `eu-milan-1.ocir.io` |
| Image path | `<host>/<tenancy-namespace>/<repository>:<tag>` | `eu-milan-1.ocir.io/axabcdef1234/dinner-roulette:latest` |
| Username, Default domain | `<tenancy-namespace>/<username>` | `axabcdef1234/you@example.com` |
| Username, with identity domain | `<tenancy-namespace>/<domain>/<username>` | `axabcdef1234/Default/you@example.com` |
| Username, federated (IDCS) | `<tenancy-namespace>/oracleidentitycloudservice/<username>` | `axabcdef1234/oracleidentitycloudservice/you@example.com` |

Rule of thumb: the namespace, a slash, then the username exactly as shown at the top of the Profile menu, including the domain if there is one. The region key also works as host (`lin.ocir.io` for Milan).

Test the login now. It saves a lot of debugging later:

```bash
docker login eu-milan-1.ocir.io -u '<tenancy-namespace>/<username>'
# Password: paste the auth token
# Login Succeeded
```

A new token can take a minute before it is accepted.

## 1.7 Reserve a public IP

The load balancer gets its public address from a **reserved** IP. An ephemeral IP would change every time the load balancer is recreated, and you would have to update DNS after each `oke-up`. A reserved IP belongs to your tenancy until you delete it.

```bash
COMPARTMENT=<compartment-ocid>    # the tenancy OCID if you use the root compartment

oci network public-ip create \
  --compartment-id "$COMPARTMENT" \
  --lifetime RESERVED \
  --display-name dinner-lb \
  --query 'data.{id:id, ip:"ip-address", state:"lifecycle-state"}' --output table
```

```text
+----------------------------------------------------------+---------------+-----------+
| id                                                       | ip            | state     |
+----------------------------------------------------------+---------------+-----------+
| ocid1.publicip.oc1.eu-milan-1.amaaaaaa…                  | 203.0.113.10  | AVAILABLE |
+----------------------------------------------------------+---------------+-----------+
```

Write both down:

- the **`id`** goes into `lb_reserved_ip_ocid` in `infra/tf/prod.tfvars`;
- the **`ip`** goes into your DNS A record in [step 2](dns-tls.md).

**Why it is not managed by Terraform:** `terraform destroy` would delete it, and the next `oke-up` would get a different address. Terraform only **reads** it through a data source (`infra/tf/outputs.tf`) to turn the OCID into an address. `make oke-up` passes that address to the ingress-nginx Service in the `oci.oraclecloud.com/reserved-ips` annotation, which takes an IP address, not an OCID.

The IP must be in the same region as the cluster and **unassigned** when the load balancer is created. To list your reserved IPs and see which ones are in use:

```bash
oci network public-ip list --compartment-id "$COMPARTMENT" --scope REGION --lifetime RESERVED \
  --query 'data[].{name:"display-name", ip:"ip-address", state:"lifecycle-state", assignedTo:"assigned-entity-type"}' \
  --output table
```

`AVAILABLE` means free. `ASSIGNED` means a load balancer or another resource is using it.

## 1.8 Find your source IP

Only one address block can reach the Kubernetes API and the website: `allowed_source_cidr`. Use the public IPv4 address your traffic comes from:

```bash
curl -4 -s https://ifconfig.me; echo
# 203.0.113.25
```

That becomes `allowed_source_cidr = "203.0.113.25/32"`. `/32` means exactly one address. A wider block such as an office range (`198.51.100.0/24`) works too.

!!! note
    If you use a VPN, this is the VPN's exit address, and it changes when you switch the VPN on or off. Many home connections also get a new address from time to time. When it changes, `kubectl` and `curl` simply time out. Fix it with [`make oke-cidr`](operate.md#when-your-ip-address-changes).

## 1.9 Optional checks

These take a minute and avoid the most common failure of the first `oke-up`.

**Is the Kubernetes version still offered?** The default is in `infra/tf/variables.tf` (`k8s_version`). OKE supports only recent versions, so a version that worked months ago may be gone:

```bash
oci ce cluster-options get --cluster-option-id all --query 'data."kubernetes-versions"'
```

If `v1.34.10` (or the value you set) is not in the list, put a listed version in `prod.tfvars` as `k8s_version = "v1.xx.y"`.

**Is there capacity for the node shape?** Terraform places the node in the first availability domain. Ask OCI whether it can host the shape right now:

```bash
TENANCY=<tenancy-ocid>
AD=$(oci iam availability-domain list --compartment-id "$TENANCY" --query 'data[0].name' --raw-output)

oci compute compute-capacity-report create \
  --compartment-id "$TENANCY" \
  --availability-domain "$AD" \
  --shape-availabilities '[{"instanceShape":"VM.Standard.A1.Flex","instanceShapeConfig":{"ocpus":2,"memoryInGBs":12}}]' \
  --query 'data."shape-availabilities"[].{shape:"instance-shape", status:"availability-status"}' \
  --output table
```

`AVAILABLE` is good news. `OUT_OF_HOST_CAPACITY` means the node pool would fail right now: choose another shape (see [step 3](configure.md#choose-the-node-shape)) or try later. The report is a snapshot, not a reservation.

## Checklist

Before moving on, you should have:

- [x] `oci iam region list` working with the `[DEFAULT]` profile
- [x] the tenancy OCID, the compartment OCID and the region identifier
- [x] the Object Storage namespace
- [x] an auth token and a working `docker login <region>.ocir.io`
- [x] a reserved public IP: its OCID and its address
- [x] your source IP as a `/32` block

Next: [Step 2: Domain and TLS](dns-tls.md).
