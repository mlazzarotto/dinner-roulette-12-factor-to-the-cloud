# Step 7: Tear it down

At the end of a session, remove everything that costs money or capacity:

```bash
cd infra
make oke-down
```

**Time:** 10 to 15 minutes. Only the reserved IP, the images in OCIR and your DNS setup remain, ready for the next `make oke-up`.

!!! warning "Check your IP first"
    The first half of `oke-down` talks to the cluster. If your IP changed since the last `oke-up`, those `kubectl` commands time out. Their errors are ignored, so the run goes on to destroy the cluster while the load balancer and the block volume are still there. Run `make oke-cidr CIDR=…/32` first if `kubectl --context oke get nodes` hangs.

## What it does, in order

The first four commands start with `-` in the `Makefile`: their errors are ignored, so a half-broken cluster can still be destroyed.

**1. Delete the `dinner` namespace.**

```bash
kubectl --context oke delete namespace dinner --ignore-not-found
```

Kubernetes deletes everything inside it: the app, the Ingress, the CNPG `Cluster`, the Secrets and the PVC `db-1`. Deleting the PVC makes the OCI CSI driver delete the **block volume**, since the `oci-bv` class uses the `Delete` reclaim policy. The votes go with it.

**2. Delete the ClusterIssuer.** It is cluster-scoped, so deleting a namespace does not remove it.

**3. Delete the `ingress-nginx` and `cert-manager` namespaces.** Deleting the `ingress-nginx-controller` Service of type LoadBalancer makes the cloud controller manager delete the **OCI Load Balancer**. The reserved IP is released and goes back to `AVAILABLE`.

**4. Wait** up to five minutes until the three namespaces are really gone, so the load balancer and the volume are deleted while the cluster still exists.

**5. `terraform destroy`.** Removes the node pool, the cluster, the NSG rules, the NSGs, the subnets, the route tables, the gateways and the VCN, in reverse dependency order. The node pool has `eviction_grace_duration = "PT0S"`, so OKE does not wait for pods to drain before deleting the node.

**6. List leftover load balancers** in the compartment, as a final check:

```text
Destroy complete! Resources: 25 destroyed.
Leftover load balancers (expect none):
Query returned empty result, no output to show.
```

## Why the order matters

Terraform knows only what it created. The load balancer and the block volume were created by OKE's controllers, in response to a Service and a PVC. If Terraform destroyed the cluster first:

- the **load balancer** would stay in the public subnet, and `terraform destroy` would then fail to delete the subnet and the VCN, because a resource still uses them;
- the **block volume** would stay unattached, and keep counting against your storage, or your bill.

Deleting the workloads first lets those controllers clean up while they still run.

## Check that nothing is left

```bash
C=<compartment-ocid>

oci lb load-balancer list --compartment-id "$C" --all \
  --query 'data[].{name:"display-name", state:"lifecycle-state"}' --output table

oci bv volume list --compartment-id "$C" --lifecycle-state AVAILABLE \
  --query 'data[].{name:"display-name", sizeGB:"size-in-gbs"}' --output table

oci ce cluster list --compartment-id "$C" --lifecycle-state ACTIVE --query 'data[].name'

oci network public-ip list --compartment-id "$C" --scope REGION --lifetime RESERVED \
  --query 'data[].{name:"display-name", ip:"ip-address", state:"lifecycle-state"}' --output table
```

The first three should return nothing. The last one should show your reserved IP as `AVAILABLE`.

## What survives

| Kept | Where | Why |
|---|---|---|
| Reserved public IP | OCI | The DNS record never has to change |
| Images | OCIR | The next `oke-up` can deploy right away |
| DNS record and API token | Cloudflare | Same hostname, same certificate flow |
| API key and auth token | OCI, your user | Needed for the next session |
| `infra/tf/terraform.tfstate` | Your laptop | Now nearly empty, but keep it: it is what the next `oke-up` starts from |
| `infra/kubeconfig` | Your laptop | Points at a cluster that no longer exists; `oke-up` replaces it |
| The CNPG operator | Nowhere | It was never deleted explicitly, but it disappeared with the cluster |

## If the teardown fails

**`terraform destroy` fails on a subnet or the VCN with a conflict.** Something Terraform did not create still uses the subnet, almost always the load balancer. Find and delete it, then destroy again:

```bash
oci lb load-balancer list --compartment-id "$C" --all --query 'data[].{id:id, name:"display-name"}' --output table
oci lb load-balancer delete --load-balancer-id <lb-ocid> --force --wait-for-state SUCCEEDED
make oke-down
```

**A namespace stays in `Terminating`.** Usually a finalizer is waiting for a controller that is already gone. Check with `kubectl --context oke get namespace dinner -o yaml` and `kubectl --context oke -n dinner get all`. The `Makefile` only waits five minutes and then continues anyway, and the destroy removes the cluster. Still check for a leftover load balancer and volume afterwards.

**The Terraform state is lost.** Terraform cannot destroy what it does not know about. Delete the resources by hand in the Console: the cluster under **Kubernetes Clusters (OKE)**, which also deletes the node pool, then the load balancer, the block volumes, and finally the VCN under **Virtual cloud networks**. The Console offers to delete the VCN together with its subnets, gateways and NSGs.

## Removing everything for good

When the workshop is over for good, also remove what `oke-down` keeps:

```bash
# Reserved IP: remove the DNS record first, or the name keeps pointing at an address you no longer own
oci network public-ip delete --public-ip-id <reserved-ip-ocid> --force

# OCIR repository and all its images
oci artifacts container repository list --compartment-id <tenancy-ocid> --display-name dinner-roulette \
  --query 'data.items[].id' --raw-output
oci artifacts container repository delete --repository-id <repository-ocid> --force
```

Then, by hand:

- **Cloudflare**: delete the A record, and revoke the API token under **My Profile → API Tokens**;
- **OCI**: delete the auth token and the API key under **My profile**, unless you use them elsewhere;
- **GitHub**: delete the repository secrets and variables;
- **your laptop**: `infra/.secrets.env`, `infra/kubeconfig` and `infra/tf/terraform.tfstate*`.
