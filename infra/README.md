# Infrastructure

OKE cluster on Oracle Cloud, plus the manifests to run the app there or on minikube.

The stack is created and destroyed around a workshop session: `oke-up` before, `oke-down` after. Only the reserved public IP and the OCIR images survive. Terraform state is local, in `infra/tf/terraform.tfstate` and git-ignored: without it `oke-down` cannot run.

## One-time setup

Create the reserved IP once and put its OCID in `tf/prod.tfvars`:

```bash
oci network public-ip create --lifetime RESERVED --compartment-id <compartment> --display-name dinner-lb
```

Then copy `.secrets.example` to `.secrets.env` and fill it in: tenancy OCID, ACME email, Cloudflare token, `OCIR_IMAGE` and the registry credentials (`OCIR_USERNAME`, `OCIR_AUTH_TOKEN`). The SSH public key is optional. The last two are the same auth token as the `OCIR_AUTH_TOKEN` repository secret, and they create the `ocir` pull secret.

In Cloudflare, point an A record for `alessandroperetti.dev` at the reserved IP, DNS-only.

## Day-to-day

```bash
cd infra

make oke-up              # cluster, cert-manager, ingress-nginx, deploy (~20 min cold)
make oke-status          # pods, services, ingress, PVCs, certificates
make oke-smoke           # hits /suggestion over HTTPS
make oke-down            # workloads first, then destroy
```

You are the only allowed source IP (`allowed_source_cidr`). When it changes:

```bash
make oke-cidr CIDR=1.2.3.4/32
```

It rewrites the value in `tf/prod.tfvars` and applies, so the next `oke-up` does not revert it.

`make oke-deploy` creates the namespace, the pull secret and the db-init ConfigMap, installs the CloudNativePG operator with helm, applies the kustomize overlay and waits for the rollout. The manifests live in `k8s/base`, with one overlay per environment in `k8s/overlays`.

## Local, with minikube

```bash
cd infra
make mk-up               # minikube, ingress addon, build, load the image
make mk-deploy
make mk-smoke            # tunnels through a temporary port-forward
```

`minikube ip` is not routable with the docker driver on macOS, so `mk-smoke` forwards the ingress controller locally. No TLS locally.

## What is created where

Terraform, in `tf/`, owns the VCN, the cluster and the node pool. Postgres runs as a CloudNativePG `Cluster` (service `db-rw`). CNPG also generates the `db-app` Secret, with a random password, and the app reads its `uri` key as `DATABASE_URL`. The load balancer and the Postgres volume come from the OKE cloud-controller-manager and the CSI driver when the manifests are applied, which is why `oke-down` deletes the workloads first.

Port 80 is closed: cert-manager issues TLS through Cloudflare DNS-01, so the LB listens on 443 only, for your source IP. The LB itself is the ingress-nginx Service, configured by `oke-up`'s helm install (reserved IP, NSG, no security list management).

## Secrets

Nothing secret is committed. `.secrets.env` is ignored. The database password exists only in the cluster: `kubectl -n dinner get secret db-app -o jsonpath='{.data.password}' | base64 -d`. CI reads secrets `OCIR_AUTH_TOKEN`, `OCIR_USERNAME`, `KUBECONFIG_B64` and variables `OCIR_REGION`, `OCIR_NAMESPACE`, and deploys with the same `make oke-deploy` target.

`KUBECONFIG_B64` expires 24h after each `oke-up`.
