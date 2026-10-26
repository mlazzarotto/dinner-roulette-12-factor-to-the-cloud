# Infrastructure

OKE cluster on Oracle Cloud, plus the manifests to run the app there or on minikube.

The stack is created and destroyed around a workshop session: `make up` before, `make down` after. Only the reserved public IP and the OCIR images survive. Terraform state is local, in `infra/terraform.tfstate` and git-ignored: without it `make down` cannot run.

## One-time setup

Create the reserved IP once and put its OCID in `prod.tfvars`:

```bash
oci network public-ip create --lifetime RESERVED --compartment-id <compartment> --display-name dinner-lb
```

Then copy `.secrets.example` to `.secrets.env` and fill it in: tenancy OCID, SSH public key, ACME email, Cloudflare token, `OCIR_IMAGE` and the registry credentials (`OCIR_USERNAME`, `OCIR_AUTH_TOKEN`). The last two are the same auth token as the `OCIR_AUTH_TOKEN` repository secret, and they create the `ocir` pull secret.

In Cloudflare, point an A record for `dinner.lazzarotto.dev` at the reserved IP, DNS-only.

## Day-to-day

```bash
cd infra

make up                  # cluster, cert-manager, ingress-nginx, deploy (~15 min cold)
make status ENV=oke      # pods, services, ingress, PVCs, certificates
make smoke ENV=oke       # hits /suggestion over HTTPS
make down                # workloads first, then destroy
```

You are the only allowed source IP (`allowed_source_cidr`). When it changes:

```bash
make allow-cidr CIDR=1.2.3.4/32
```

It rewrites the value in `prod.tfvars` and applies, so the next `make up` does not revert it.

`make deploy ENV=oke` renders the manifests, creates the namespace and the pull secret, applies everything and waits for the rollout.

## Local, with minikube

```bash
cd infra
make mk-up               # minikube, ingress addon, build, load the image
make deploy ENV=minikube
```

`curl -H 'Host: dinner.local' http://$(minikube ip)/suggestion`, or add `dinner.local` to `/etc/hosts`. No TLS locally.

## What is created where

Terraform owns the VCN, the cluster and the node pool. The load balancer and the Postgres volume come from the OKE cloud-controller-manager and the CSI driver when the manifests are applied, which is why `make down` deletes the workloads first.

Port 80 is closed: cert-manager issues TLS through Cloudflare DNS-01, so the LB listens on 443 only, for your source IP. The LB itself is the ingress-nginx Service, configured by `make up`'s helm install (reserved IP, NSG, no security list management).

## Secrets

Nothing secret is committed. `.secrets.env` and `infra/k8s/rendered/` are ignored. CI reads secrets `OCIR_AUTH_TOKEN`, `OCIR_USERNAME`, `KUBECONFIG_B64` and variables `OCIR_REGION`, `OCIR_NAMESPACE`.

`KUBECONFIG_B64` expires 24h after each `make up`.
