# Reference

## Make targets

Run from `infra/`, or with `make -C infra <target>` from the repository root. `make` alone prints this list.

### Terraform

| Target | What it does |
|---|---|
| `fmt` | `terraform fmt -recursive` on `infra/tf/` |
| `init` | `terraform init`: downloads the OCI provider pinned by `.terraform.lock.hcl` |
| `plan` | Shows what `apply` would change, for `prod.tfvars` |
| `apply` | `init` plus `apply -auto-approve`. Terraform only, no kubeconfig and no add-ons. Useful after a partial `oke-up` |

### OKE

| Target | What it does |
|---|---|
| `oke-up` | Terraform, kubeconfig, cert-manager, ingress-nginx, ClusterIssuer, then `oke-deploy`. About 20 minutes from nothing |
| `oke-deploy` | Namespace, `ocir` Secret, CNPG operator, `db-init`, OKE overlay with your image, rollout wait |
| `oke-push` | `docker login`, build for the local architecture, and push to `OCIR_IMAGE` |
| `oke-status` | Pods, Services, Ingress, PVCs and certificates in `dinner` |
| `oke-env` | Prints the `KUBECONFIG` export and `use-context oke`. Use as `eval "$(make oke-env)"` |
| `oke-smoke` | `curl -sf https://<host>/suggestion` |
| `oke-cidr` | `make oke-cidr CIDR=x.x.x.x/32`: rewrites `allowed_source_cidr` in `prod.tfvars` and applies |
| `oke-down` | Deletes the workloads, then `terraform destroy`, then lists leftover load balancers |

### minikube

| Target | What it does |
|---|---|
| `mk-up` | `minikube start --cpus=2 --memory=4g`, ingress addon, `docker build`, `minikube image load` |
| `mk-deploy` | Namespace, CNPG operator, `db-init`, minikube overlay, rollout wait |
| `mk-status` | Pods, Services, Ingress and PVCs in `dinner` |
| `mk-env` | Prints the `KUBECONFIG` export and `use-context minikube` |
| `mk-smoke` | Temporary port-forward to the ingress controller, then `GET /suggestion` with `Host: dinner.local` |
| `mk-down` | Deletes the `dinner` namespace. Keeps the cluster and the image |

### Internal

These are called by the targets above. You can run them on their own when you need just one step.

| Target | What it does |
|---|---|
| `cnpg CONTEXT=<ctx>` | Installs or upgrades the CloudNativePG operator with Helm, on `oke` or `minikube` |
| `db-init CONTEXT=<ctx>` | Creates or updates the `db-init` ConfigMap from `db/init.sql`, on `oke` or `minikube` |
| `registry-secret` | Creates or updates the `ocir` pull Secret on OKE |
| `check-terraform`, `check-registry`, `check-letsencrypt` | Stop early when a required variable is empty |
| `check-context` | Rejects a `CONTEXT` other than `oke` or `minikube` |

## Variables

| Variable | Local source | CI source | Used by |
|---|---|---|---|
| `TF_VAR_tenancy_ocid` | `infra/.secrets.env` | none | Terraform |
| `TF_VAR_ssh_public_key` | `infra/.secrets.env`, optional | none | Terraform, node pool |
| `ACME_EMAIL` | `infra/.secrets.env` | none | `oke-up`, ClusterIssuer |
| `CLOUDFLARE_API_TOKEN` | `infra/.secrets.env` | none | `oke-up`, Secret `cloudflare-api-token` |
| `OCIR_USERNAME` | `infra/.secrets.env` | secret `OCIR_USERNAME` | `oke-push`, `registry-secret`, `build` workflow |
| `OCIR_AUTH_TOKEN` | `infra/.secrets.env` | secret `OCIR_AUTH_TOKEN` | `oke-push`, `registry-secret`, `build` workflow |
| `OCIR_IMAGE` | `infra/.secrets.env` | built from the variables `OCIR_REGION` and `OCIR_NAMESPACE` | `oke-push`, `oke-deploy` |
| `KUBECONFIG` | set by the `Makefile` | from the secret `KUBECONFIG_B64` | every `kubectl` and `helm` call |
| `CIDR` | command line | none | `oke-cidr` |
| `CONTEXT` | set by the calling target | none | `cnpg`, `db-init` |

Terraform inputs are listed in [step 3](oke/configure.md#32-edit-infratfprodtfvars).

## Pinned versions

| Component | Version | Where |
|---|---|---|
| cert-manager chart | `v1.17.1` | `CERT_MANAGER_VERSION` in `infra/Makefile` |
| ingress-nginx chart | `4.12.1` | `INGRESS_NGINX_VERSION` in `infra/Makefile` |
| CloudNativePG chart | `0.29.1` | `CNPG_VERSION` in `infra/Makefile` |
| PostgreSQL | `17` | `imageName` in `infra/k8s/base/db.yaml` |
| Kubernetes on OKE | `v1.34.10` | `k8s_version` default in `infra/tf/variables.tf` |
| OCI Terraform provider | `~> 6.20`, locked to `6.37.0` | `infra/tf/versions.tf`, `.terraform.lock.hcl` |
| Terraform | `>= 1.12` | `infra/tf/versions.tf` |
| Node.js | 22 in CI, `node:slim` in the image | `.github/workflows/build.yml`, `Dockerfile` |

To bump a chart, change the version in the `Makefile`, read the chart's release notes, and test on minikube first where possible.

## What runs in the cluster

| Namespace | Main objects | Created by |
|---|---|---|
| `dinner` | Deployment, Service and Ingress `app`; CNPG Cluster `db` with pod `db-1`, PVC `db-1`, Services `db-rw`, `db-ro`, `db-r`; Secrets `db-app`, `ocir`, `dinner-tls`; ConfigMap `db-init`; Certificate `dinner-tls` | `mk-deploy` or `oke-deploy`, CNPG, cert-manager |
| `cnpg-system` | CloudNativePG operator | `make cnpg` |
| `cert-manager` | cert-manager controller, webhook, CA injector; Secrets `cloudflare-api-token`, `letsencrypt-account` | `oke-up` |
| `ingress-nginx` | ingress-nginx controller, Service `ingress-nginx-controller` of type LoadBalancer | `oke-up`, or the minikube addon |
| cluster-wide | ClusterIssuer `letsencrypt-cloudflare`; CRDs of CNPG and cert-manager | `oke-up`, Helm |

## Cheat sheet

```bash
# Where am I?
kubectl config get-contexts
eval "$(make oke-env)"                    # or mk-env

# State
kubectl -n dinner get pods,svc,ingress,pvc
kubectl -n dinner get cluster db
kubectl -n dinner get certificate,challenge
kubectl -n dinner get events --sort-by=.lastTimestamp

# Debug a pod
kubectl -n dinner describe pod <pod>
kubectl -n dinner logs <pod> -c <container> --previous

# Restart the app (after pushing or loading a new image)
kubectl -n dinner rollout restart deploy/app && kubectl -n dinner rollout status deploy/app

# Database
kubectl -n dinner exec -it db-1 -c postgres -- psql -d dinner_roulette
kubectl -n dinner get secret db-app -o jsonpath='{.data.password}' | base64 -d; echo

# Render the manifests without applying them
kubectl kustomize k8s/overlays/minikube
kubectl kustomize k8s/overlays/oke

# Terraform outputs
terraform -chdir=tf output

# Your current public IP, for allowed_source_cidr
curl -4 -s https://ifconfig.me; echo
```

## Glossary

ACME
:   The protocol Let's Encrypt speaks. A client such as cert-manager orders a certificate, proves control of the domain with a challenge (here DNS-01), and receives the certificate.

Availability domain (AD)
:   An isolated data center within an OCI region. Milan has one. Terraform puts the node in the first AD of the region.

Basic cluster
:   OKE cluster type with a free control plane and no financially backed SLA. Enhanced clusters add features and cost $0.10 per hour.

CCM (cloud controller manager)
:   The OKE component that turns Kubernetes Services of type LoadBalancer into OCI Load Balancers, and initialises nodes with their cloud metadata.

CNPG (CloudNativePG)
:   A Kubernetes operator that runs PostgreSQL clusters described by `Cluster` resources.

Compartment
:   A folder for OCI resources, with its own policies. The root compartment is the tenancy itself.

CRD (CustomResourceDefinition)
:   A new object type added to the Kubernetes API, such as CNPG's `Cluster` or cert-manager's `Certificate`.

CSI driver
:   The component that creates and attaches storage for PersistentVolumeClaims. On OKE, the `oci-bv` storage class creates OCI block volumes.

DNS-01
:   An ACME challenge in which you prove control of a domain by publishing a TXT record. It needs no inbound connection to your server.

Flannel
:   The overlay pod network used by this cluster (`FLANNEL_OVERLAY`). Pods get addresses from an internal range, not from the VCN.

Kustomize
:   A tool built into kubectl that combines a base set of manifests with per-environment overlays, without templates.

NSG (network security group)
:   A set of firewall rules attached to specific resources, such as the load balancer, the nodes or the API endpoint, rather than to a whole subnet.

OCID
:   Oracle Cloud ID, the unique identifier of every OCI resource, for example `ocid1.tenancy.oc1..aaaa…`.

OCIR
:   Oracle Cloud Infrastructure Registry, Oracle's container image registry, at `<region>.ocir.io`.

Object Storage namespace (tenancy namespace)
:   A short random string unique to your tenancy, used as the first segment of OCIR image paths and usernames.

Reserved public IP
:   A public IPv4 address that belongs to your tenancy until you delete it, independently of the resource it is attached to.

Security list
:   Subnet-wide firewall rules. Here the public subnet's list is deliberately empty, and NSGs do the filtering.

Service Gateway
:   Lets resources in a private subnet reach Oracle services such as OCIR without going through the internet.

Tenancy
:   Your Oracle Cloud account: the root of all your compartments and resources.

VCN (virtual cloud network)
:   A private network in OCI, the equivalent of a VPC in other clouds.

## Working on this site

The guide is written in Markdown in `docs/` and built with [MkDocs Material](https://squidfunk.github.io/mkdocs-material/). Some code blocks are not copies: they embed the real files of the repository (`--8<-- "path/to/file"`), so they always show the current manifests and workflows.

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r docs/requirements.txt
mkdocs serve          # live preview on http://127.0.0.1:8000
mkdocs build --strict # what CI runs: fails on broken links, anchors and missing embedded files
```

The `pages` workflow (`.github/workflows/pages.yml`) builds the site and publishes it to GitHub Pages on every push to `main` that touches `docs/`, `mkdocs.yml`, `infra/`, the workflows or `db/init.sql`. Pages must be enabled once by a repository admin: **Settings → Pages → Build and deployment → Source: GitHub Actions**.
