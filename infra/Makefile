# All targets run from infra/. `make -C infra ...`
# OpenTofu lives in tf/ and is invoked with -chdir, so the k8s paths stay relative to infra/.
K8S := k8s
TF := tofu -chdir=tf

CERT_MANAGER_VERSION := v1.17.1
INGRESS_NGINX_VERSION := 4.12.1
CNPG_VERSION := 0.29.1

# Local secrets file, git-ignored. See .secrets.example. CI passes the same variables
# through the environment instead.
-include .secrets.env
export

# Read from the OCI profile instead of being pasted into .secrets.env. Every user of the
# repo already has this file, created by `oci setup config`.
OCI_CONFIG := $(HOME)/.oci/config
OCI_PROFILE := $(or $(OCI_CLI_PROFILE),DEFAULT)

# awk, not grep and cut: the file is INI, and a profile can be preceded by a comment.
oci_config_get = awk -F= -v want='$(1)' \
	'/^\[/ { in_profile = ($$0 == "[" "$(OCI_PROFILE)" "]") } \
	 in_profile && $$1 == want { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }' $(OCI_CONFIG)

# The tenancy OCID is the one value OpenTofu cannot look up: data.oci_identity_tenancy
# requires tenancy_id explicitly, and the provider does not expose its own. Everything else
# is derived in tf/locals.tf. Also picked up by the oci CLI, which reads the same profile.
export TF_VAR_tenancy_ocid ?= $(if $(wildcard $(OCI_CONFIG)),$(shell $(call oci_config_get,tenancy)),)
export TF_VAR_region ?= $(if $(wildcard $(OCI_CONFIG)),$(shell $(call oci_config_get,region)),)

# The generated file (git-ignored) that carries the values `oke-tfvars` works out. OpenTofu
# loads *.auto.tfvars automatically, so no -var-file anywhere.
AUTO_TFVARS := tf/workshop.auto.tfvars

# The kubeconfig created by `oke-up` is kept in infra/ (git-ignored) and merged with yours,
# so the minikube context is never clobbered.
export KUBECONFIG := $(HOME)/.kube/config:$(CURDIR)/kubeconfig

# Registry path derived from what the user already filled in, so the host, the namespace and
# the username cannot drift apart. Set OCIR_USERNAME and HOST; OCIR_IMAGE is optional and
# only needed to pin a tag other than :latest.
OCIR_NAMESPACE ?= $(firstword $(subst /, ,$(OCIR_USERNAME)))
OCIR_IMAGE ?= $(TF_VAR_region).ocir.io/$(OCIR_NAMESPACE)/dinner-roulette:latest

# Public host name served by the ingress. Set HOST in .secrets.env.
HOST ?=
export TF_VAR_host ?= $(HOST)

# Registry host taken from the image reference, so the pull secret cannot point elsewhere.
OCIR_SERVER := $(firstword $(subst /, ,$(OCIR_IMAGE)))

# Compartment for the leftover-LB check in `oke-down`. It cannot come from `tofu output`:
# after a destroy the state has no outputs and tofu prints its "No outputs found" warning
# to stdout with exit 0, so the substitution yields garbage. Resolve like tf/locals.tf:
# the generated tfvars first, then TF_VAR_compartment_ocid, then the tenancy.
LB_COMPARTMENT := $(shell awk -F'"' '/^compartment_ocid/ {print $$2}' $(AUTO_TFVARS) 2>/dev/null)
LB_COMPARTMENT := $(or $(LB_COMPARTMENT),$(TF_VAR_compartment_ocid),$(TF_VAR_tenancy_ocid))

# Bare `make` lists the targets instead of hitting the first one.
.DEFAULT_GOAL := help

.PHONY: help fmt init plan apply \
	oke-up oke-deploy oke-push oke-status oke-env oke-smoke oke-cidr oke-down \
	oke-tfvars oke-bootstrap oke-secrets \
	mk-up mk-deploy mk-status mk-env mk-smoke mk-down \
	check-context check-oci check-tfvars check-registry check-letsencrypt check-host \
	db-init cnpg registry-secret

help: ## List available targets
	@awk 'BEGIN { FS = ":.*## " } /^[a-zA-Z0-9_.-]+:.*## / { n = $$1; d = $$2; x = ""; if (match(d, / @ /)) { x = substr(d, RSTART + 3); d = substr(d, 1, RSTART - 1) } if (n == "help") g = "gen"; else if (n ~ /^oke-/) g = "oke"; else if (n ~ /^mk-/) g = "mk"; else g = "tf"; line[g] = line[g] sprintf("  \033[36m%-14s\033[0m %s\n", n, d); if (x != "") line[g] = line[g] sprintf("  %-14s \033[2me.g. %s\033[0m\n", "", x) } END { print "General:"; printf "%s", line["gen"]; print "\nOpenTofu, from infra/tf/:"; printf "%s", line["tf"]; print "\nOKE:"; printf "%s", line["oke"]; print "\nminikube:"; printf "%s", line["mk"] }' $(firstword $(MAKEFILE_LIST))

# ---------------------------------------------------------------- OpenTofu

fmt: ## Format the OpenTofu files
	$(TF) fmt -recursive .

init: ## Initialise the OpenTofu working directory
	$(TF) init

plan: check-tfvars ## Show the OpenTofu plan
	$(TF) plan

# OpenTofu only, no kubeconfig or addons. Useful after a partial `oke-up`.
apply: check-tfvars ## Apply without the full bootstrap
	$(TF) init
	$(TF) apply -auto-approve

# ---------------------------------------------------------------- OKE

# Writes tf/workshop.auto.tfvars from what your account already answers, so a fresh clone
# needs no OCIDs or CIDR pasted anywhere. OpenTofu loads *.auto.tfvars automatically.
# Idempotent: run it again after your public IP changes. Anything you want to override
# (node_shape and friends) goes in .secrets.env as TF_VAR_<name>, not in this file.
oke-tfvars: check-oci ## Derive region, public CIDR and reserved IP from your account
	@set -e; \
	region="$(TF_VAR_region)"; \
	cidr="$$(curl -s --max-time 5 https://checkip.amazonaws.com | tr -d '[:space:]')"; \
	case "$$cidr" in \
		''|*[!0-9.]*|*.*.*.*.*) echo "Could not read your public address from checkip.amazonaws.com."; \
			echo "Set it by hand instead: make oke-cidr CIDR=x.x.x.x/32"; cidr="";; \
	esac; \
	ip="$$(oci network public-ip list --scope REGION --lifetime RESERVED --all --output json 2>/dev/null \
		| python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(next((x["id"] for x in d if x["display-name"].startswith("dinner-lb")), ""))' \
		2>/dev/null || true)"; \
	ns="$$(oci os ns get --query data --raw-output 2>/dev/null || true)"; \
	{ \
	  echo "# Generated by \`make oke-tfvars\`. Git-ignored, safe to delete and regenerate."; \
	  test -z "$$region" || echo "region              = \"$$region\""; \
	  test -z "$$cidr"   || echo "allowed_source_cidr = \"$$cidr/32\""; \
	  test -z "$$ip"     || echo "lb_reserved_ip_ocid = \"$$ip\""; \
	} > $(AUTO_TFVARS); \
	echo "Wrote $(AUTO_TFVARS):"; sed 's/^/  /' $(AUTO_TFVARS); \
	echo; \
	echo "Object Storage namespace (for OCIR_USERNAME): $$ns"; \
	if [ -n "$$ip" ]; then echo "Reserved IP dinner-lb found: the DNS record stays valid across oke-up/oke-down."; \
	else echo "No reserved IP named dinner-lb in this region: the load balancer gets an"; \
	     echo "ephemeral address that changes on every oke-up. Make one with:"; \
	     echo "  oci network public-ip create --lifetime RESERVED --display-name dinner-lb"; fi

# One-time setup help for a fresh clone. Prints the exact values to paste, and stops at the
# two things OCI only lets you create in the Console.
oke-bootstrap: ## Show what is missing in .secrets.env and how to fill it
	@echo "OCI profile: $(OCI_CONFIG)"
	@if [ ! -f "$(OCI_CONFIG)" ]; then \
		echo; echo "Missing. Create it with:"; echo "  oci setup config"; echo; \
	else \
		echo "  profile     $(OCI_PROFILE)"; \
		echo "  tenancy     $$($(call oci_config_get,tenancy))"; \
		echo "  user        $$($(call oci_config_get,user))"; \
		echo "  region      $$($(call oci_config_get,region))"; \
		echo "  namespace   $$(oci os ns get --query data --raw-output 2>/dev/null || echo '<run: oci os ns get>')"; \
		echo "  username    <namespace>/<your-login>"; \
	fi
	@echo; echo "Auth token (Console only, no API):"
	@echo "  https://cloud.oracle.com/identity/domains/my-profile/auth-tokens"
	@echo "Cloudflare API token, Zone:DNS:Edit + Zone:Zone:Read:"
	@echo "  https://dash.cloudflare.com/profile/api-tokens"
	@echo
	@if [ ! -f .secrets.env ]; then \
		echo "Next: make oke-secrets, then paste the values above into .secrets.env"; \
	else \
		echo ".secrets.env exists. Still a placeholder:"; \
		grep -n 'REPLACE\|example.com' .secrets.env || echo "  nothing, you are good to go"; \
	fi

# Copies .secrets.example, never overwrites an existing file with real values in it.
oke-secrets: ## Create .secrets.env from .secrets.example
	@if [ -f .secrets.env ]; then echo ".secrets.env already exists, not touching it."; \
	else cp .secrets.example .secrets.env; echo "Created .secrets.env, now fill it in."; fi

oke-up: check-oci check-tfvars check-registry check-letsencrypt ## Create the cluster, the addons and deploy (~20 min)
	$(TF) init
	$(TF) apply -auto-approve
	rm -f $(CURDIR)/kubeconfig
	oci ce cluster create-kubeconfig --cluster-id "$$($(TF) output -raw cluster_id)" \
		--file $(CURDIR)/kubeconfig --region "$$($(TF) output -raw region)" --token-version 2.0.0
	KUBECONFIG=$(CURDIR)/kubeconfig kubectl config rename-context \
		"$$(KUBECONFIG=$(CURDIR)/kubeconfig kubectl config current-context)" oke
	helm repo add jetstack https://charts.jetstack.io >/dev/null
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
	helm repo update jetstack ingress-nginx >/dev/null
	helm upgrade --install cert-manager jetstack/cert-manager --version $(CERT_MANAGER_VERSION) \
		--namespace cert-manager --create-namespace --set crds.enabled=true --kube-context oke --wait
	# The LB annotations belong on the controller Service, which is what the CCM reads.
	# lb_ip is "" when no reserved IP is configured, so the annotation is omitted entirely
	# rather than passed empty, and the CCM allocates an ephemeral address.
	@set -- --set controller.service.annotations."service\.beta\.kubernetes\.io/oci-load-balancer-security-list-management-mode"=None \
		--set controller.service.annotations."oci\.oraclecloud\.com/oci-network-security-groups"="$$($(TF) output -raw lb_nsg_id)"; \
	ip="$$($(TF) output -raw lb_ip)"; \
	if [ -n "$$ip" ]; then \
		set -- "$$@" --set controller.service.annotations."oci\.oraclecloud\.com/reserved-ips"="$$ip"; \
	fi; \
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --version $(INGRESS_NGINX_VERSION) \
		--namespace ingress-nginx --create-namespace --kube-context oke --wait "$$@"
	kubectl --context oke wait --for=condition=established crd/clusterissuers.cert-manager.io --timeout=120s
	@kubectl --context oke -n cert-manager create secret generic cloudflare-api-token \
		--from-literal=token="$$CLOUDFLARE_API_TOKEN" --dry-run=client -o yaml | kubectl --context oke apply -f -
	sed "s|__ACME_EMAIL__|$$ACME_EMAIL|" $(K8S)/clusterissuer.yaml | kubectl --context oke apply -f -
	kubectl --context oke wait --for=condition=Ready clusterissuer/letsencrypt-cloudflare --timeout=120s
	$(MAKE) oke-deploy
	@echo "Ready: https://$(HOST)"
	@reserved="$$($(TF) output -raw lb_ip)"; \
	ip="$$reserved"; \
	[ -n "$$ip" ] || ip="$$(kubectl --context oke -n ingress-nginx get svc ingress-nginx-controller \
		-o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"; \
	if [ -n "$$ip" ]; then \
		echo "Point the A record for $(HOST) at: $$ip"; \
		[ -n "$$reserved" ] || echo "That is an ephemeral address: it changes on the next oke-up."; \
	fi

oke-deploy: check-registry check-host ## Apply the manifests and wait for the app @ make oke-deploy OCIR_IMAGE=eu-milan-1.ocir.io/<namespace>/dinner-roulette:1.1.0
	kubectl --context oke create namespace dinner --dry-run=client -o yaml | kubectl --context oke apply -f -
	$(MAKE) registry-secret
	$(MAKE) cnpg CONTEXT=oke
	$(MAKE) db-init CONTEXT=oke
	kubectl kustomize $(K8S)/overlays/oke \
		| sed -e "s|__OCIR_IMAGE__|$(OCIR_IMAGE)|" -e "s|__HOST__|$(HOST)|" \
		| kubectl --context oke apply -f -
	kubectl --context oke -n dinner rollout status deploy/app --timeout=300s

# Builds for the architecture of the local Docker daemon. E3/E4 nodes are amd64, A1.Flex is arm64.
oke-push: check-registry ## Build the app image and push it to OCIR @ make oke-push OCIR_IMAGE=eu-milan-1.ocir.io/<namespace>/dinner-roulette:1.1.0
	@printf '%s' "$$OCIR_AUTH_TOKEN" | docker login "$(OCIR_SERVER)" -u "$(OCIR_USERNAME)" --password-stdin
	docker build --build-arg COMMIT_SHA="$$(git -C .. rev-parse --short=7 HEAD)" -t "$(OCIR_IMAGE)" ..
	docker push "$(OCIR_IMAGE)"

oke-status: ## Show pods, services, ingress, PVCs and certificates
	kubectl --context oke -n dinner get pods,svc,ingress,pvc -o wide
	-kubectl --context oke -n dinner get certificates

# Usage: eval "$(make -C infra oke-env)"
oke-env: ## Export KUBECONFIG and select the oke context for kubectl
	@echo 'export KUBECONFIG="$(KUBECONFIG)"'
	@echo 'kubectl config use-context oke >/dev/null'

oke-smoke: check-host ## Hit /suggestion over HTTPS
	curl -sf https://$(HOST)/suggestion; echo

# Rewrites the generated tfvars, so a later `oke-up` cannot silently revert the old CIDR.
oke-cidr: check-oci check-host ## Update the allowed source IP and apply @ make oke-cidr CIDR=1.2.3.4/32
	@test -n "$(CIDR)" || { echo "Usage: make oke-cidr CIDR=x.x.x.x/32"; exit 1; }
	@case "$(CIDR)" in */*) ;; *) echo "CIDR must be a block, e.g. 1.2.3.4/32"; exit 1 ;; esac
	@test -f $(AUTO_TFVARS) || $(MAKE) --no-print-directory oke-tfvars
	@if grep -q '^allowed_source_cidr' $(AUTO_TFVARS); then \
		sed -i.bak 's|^allowed_source_cidr.*|allowed_source_cidr = "$(CIDR)"|' $(AUTO_TFVARS); \
	else echo 'allowed_source_cidr = "$(CIDR)"' >> $(AUTO_TFVARS); fi
	@rm -f $(AUTO_TFVARS).bak
	@grep -n '^allowed_source_cidr' $(AUTO_TFVARS)
	$(TF) apply -auto-approve

# Destroy needs the same inputs as apply: without them tofu prompts and, on a terminal-less
# shell, fails after the workloads are already gone.
oke-down: check-oci check-tfvars ## Delete the workloads and destroy the cluster
	-kubectl --context oke delete namespace dinner --ignore-not-found
	-kubectl --context oke delete clusterissuer letsencrypt-cloudflare --ignore-not-found
	-kubectl --context oke delete namespace ingress-nginx cert-manager --ignore-not-found
	-kubectl --context oke wait --for=delete namespace/dinner namespace/ingress-nginx namespace/cert-manager --timeout=300s
	$(TF) destroy -auto-approve
	@echo "Leftover load balancers (expect none):"
	@oci lb load-balancer list --compartment-id "$(LB_COMPARTMENT)" --all \
		--query 'data[].{name:"display-name",state:"lifecycle-state"}' --output table || true

# ---------------------------------------------------------------- minikube

mk-up: ## Start minikube, enable ingress, build and load the image
	minikube start --cpus=2 --memory=4g
	minikube addons enable ingress
	cd .. && docker build -t dinner-roulette:local .
	minikube image load dinner-roulette:local

mk-deploy: ## Apply the manifests and wait for the app
	kubectl --context minikube create namespace dinner --dry-run=client -o yaml | kubectl --context minikube apply -f -
	$(MAKE) cnpg CONTEXT=minikube
	$(MAKE) db-init CONTEXT=minikube
	kubectl kustomize $(K8S)/overlays/minikube | kubectl --context minikube apply -f -
	kubectl --context minikube -n dinner rollout status deploy/app --timeout=300s

mk-status: ## Show pods, services, ingress and PVCs
	kubectl --context minikube -n dinner get pods,svc,ingress,pvc -o wide

# Usage: eval "$(make -C infra mk-env)"
mk-env: ## Export KUBECONFIG and select the minikube context for kubectl
	@echo 'export KUBECONFIG="$(KUBECONFIG)"'
	@echo 'kubectl config use-context minikube >/dev/null'

# `minikube ip` is not routable with the docker driver on macOS, so tunnel through a
# temporary port-forward instead.
mk-smoke: ## Hit /suggestion on dinner.local
	@kubectl --context minikube -n ingress-nginx port-forward svc/ingress-nginx-controller 18080:80 >/dev/null 2>&1 & \
		pid=$$!; sleep 3; \
		curl -sf -H 'Host: dinner.local' http://127.0.0.1:18080/suggestion; \
		rc=$$?; kill $$pid 2>/dev/null; echo; exit $$rc

mk-down: ## Delete the workloads, keep the VM and the image
	-kubectl --context minikube delete namespace dinner --ignore-not-found
	-kubectl --context minikube wait --for=delete namespace/dinner --timeout=120s

# ---------------------------------------------------------------- internal

check-context:
	@case "$(CONTEXT)" in \
		oke|minikube) ;; \
		*) echo "Internal target: pass CONTEXT=oke or CONTEXT=minikube"; exit 1 ;; \
	esac

check-oci:
	@test -f "$(OCI_CONFIG)" || { echo "Missing $(OCI_CONFIG). Create it with:"; \
		echo "  oci setup config"; exit 1; }
	@test -n "$(TF_VAR_tenancy_ocid)" || { echo "$(OCI_CONFIG) has no 'tenancy=' line in profile [$(OCI_PROFILE)]"; exit 1; }
	@test -n "$(TF_VAR_region)" || { echo "$(OCI_CONFIG) has no 'region=' line in profile [$(OCI_PROFILE)]"; exit 1; }

check-host:
	@test -n "$(HOST)" || { echo "Missing HOST (infra/.secrets.env), e.g. HOST=dinner.yourdomain.com"; exit 1; }
	@case "$(HOST)" in \
		*example.com|*example.org|*example.net) echo "HOST is still the placeholder: $(HOST)"; \
			echo "Set the host name your DNS record points at."; exit 1 ;; \
	esac

check-tfvars: check-host
	@test -f "$(AUTO_TFVARS)" || { echo "Missing $(AUTO_TFVARS). Generate it with:"; \
		echo "  make oke-tfvars"; exit 1; }
	@grep -q '^allowed_source_cidr' $(AUTO_TFVARS) || { echo "$(AUTO_TFVARS) has no allowed_source_cidr."; \
		echo "Regenerate it with: make oke-tfvars"; exit 1; }

check-registry:
	@test -n "$(OCIR_USERNAME)" || { echo "Missing OCIR_USERNAME (infra/.secrets.env): <namespace>/<your-login>"; exit 1; }
	@test -n "$(OCIR_AUTH_TOKEN)" || { echo "Missing OCIR_AUTH_TOKEN (infra/.secrets.env)"; exit 1; }
	@test -n "$(OCIR_SERVER)" && test "$(OCIR_SERVER)" != ".ocir.io" || { echo "Cannot work out the registry host: is region set in $(OCI_CONFIG)?"; exit 1; }

check-letsencrypt:
	@test -n "$$ACME_EMAIL" || { echo "Missing ACME_EMAIL (infra/.secrets.env)"; exit 1; }
	@test -n "$$CLOUDFLARE_API_TOKEN" || { echo "Missing CLOUDFLARE_API_TOKEN (infra/.secrets.env)"; exit 1; }

# The private image cannot be pulled without this. Idempotent, and it reads the registry
# host from OCIR_IMAGE. Needs the dinner namespace to exist.
registry-secret: check-registry
	@kubectl --context oke -n dinner create secret docker-registry ocir \
		--docker-server="$(OCIR_SERVER)" \
		--docker-username="$(OCIR_USERNAME)" \
		--docker-password="$(OCIR_AUTH_TOKEN)" \
		--dry-run=client -o yaml | kubectl --context oke apply -f -

# The CloudNativePG operator and its CRDs, which db.yaml needs. Idempotent.
cnpg: check-context
	helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null
	helm repo update cnpg >/dev/null
	helm upgrade --install cnpg cnpg/cloudnative-pg --version $(CNPG_VERSION) \
		--namespace cnpg-system --create-namespace --kube-context $(CONTEXT) --wait

# db/init.sql is read by Postgres on first init; the namespace must exist.
db-init: check-context
	kubectl --context $(CONTEXT) -n dinner create configmap db-init \
		--from-file=init.sql=../db/init.sql --dry-run=client -o yaml | kubectl --context $(CONTEXT) apply -f -
