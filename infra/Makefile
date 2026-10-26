# All targets run from infra/. `make -C infra ...`
K8S := k8s

CERT_MANAGER_VERSION := v1.17.1
INGRESS_NGINX_VERSION := 4.12.1

# Local secrets file, git-ignored. See .secrets.example. CI passes the same variables
# through the environment instead.
-include .secrets.env
export

# The kubeconfig created by `oke-up` is kept in infra/ (git-ignored) and merged with yours,
# so the minikube context is never clobbered.
export KUBECONFIG := $(HOME)/.kube/config:$(CURDIR)/kubeconfig

# Registry host taken from the image reference, so the pull secret cannot point elsewhere.
OCIR_SERVER := $(firstword $(subst /, ,$(OCIR_IMAGE)))

# Bare `make` lists the targets instead of hitting the first one.
.DEFAULT_GOAL := help

.PHONY: help fmt init plan apply \
	oke-up oke-deploy oke-status oke-env oke-smoke oke-cidr oke-down \
	mk-up mk-deploy mk-status mk-env mk-smoke mk-down \
	check-context check-terraform check-registry check-letsencrypt \
	db-init registry-secret

help: ## List available targets
	@awk 'BEGIN { FS = ":.*## " } /^[a-zA-Z0-9_.-]+:.*## / { n = $$1; if (n == "help") g = "gen"; else if (n ~ /^oke-/) g = "oke"; else if (n ~ /^mk-/) g = "mk"; else g = "tf"; line[g] = line[g] sprintf("  \033[36m%-14s\033[0m %s\n", n, $$2) } END { print "Generale:"; printf "%s", line["gen"]; print "\nTerraform, da infra/:"; printf "%s", line["tf"]; print "\nOKE:"; printf "%s", line["oke"]; print "\nminikube:"; printf "%s", line["mk"] }' $(firstword $(MAKEFILE_LIST))

# ---------------------------------------------------------------- Terraform

fmt: ## Format the Terraform files
	terraform fmt -recursive .

init: ## Initialise the Terraform working directory
	terraform init

plan: ## Show the Terraform plan for prod.tfvars
	terraform plan -var-file=prod.tfvars

# Terraform only, no kubeconfig or addons. Useful after a partial `oke-up`.
apply: check-terraform ## Apply prod.tfvars without the full bootstrap
	terraform init
	terraform apply -var-file=prod.tfvars -auto-approve

# ---------------------------------------------------------------- OKE

oke-up: check-terraform check-registry check-letsencrypt ## Create the cluster, the addons and deploy (~20 min)
	terraform init
	terraform apply -var-file=prod.tfvars -auto-approve
	rm -f $(CURDIR)/kubeconfig
	oci ce cluster create-kubeconfig --cluster-id "$$(terraform output -raw cluster_id)" \
		--file $(CURDIR)/kubeconfig --region "$$(terraform output -raw region)" --token-version 2.0.0
	KUBECONFIG=$(CURDIR)/kubeconfig kubectl config rename-context \
		"$$(KUBECONFIG=$(CURDIR)/kubeconfig kubectl config current-context)" oke
	helm repo add jetstack https://charts.jetstack.io >/dev/null
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
	helm repo update jetstack ingress-nginx >/dev/null
	helm upgrade --install cert-manager jetstack/cert-manager --version $(CERT_MANAGER_VERSION) \
		--namespace cert-manager --create-namespace --set crds.enabled=true --kube-context oke --wait
	# The LB annotations belong on the controller Service, which is what the CCM reads.
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --version $(INGRESS_NGINX_VERSION) \
		--namespace ingress-nginx --create-namespace --kube-context oke --wait \
		--set controller.service.annotations."service\.beta\.kubernetes\.io/oci-load-balancer-security-list-management-mode"=None \
		--set controller.service.annotations."oci\.oraclecloud\.com/oci-network-security-groups"="$$(terraform output -raw lb_nsg_id)" \
		--set controller.service.annotations."oci\.oraclecloud\.com/reserved-ips"="$$(terraform output -raw lb_reserved_ip)"
	kubectl --context oke wait --for=condition=established crd/clusterissuers.cert-manager.io --timeout=120s
	@kubectl --context oke -n cert-manager create secret generic cloudflare-api-token \
		--from-literal=token="$$CLOUDFLARE_API_TOKEN" --dry-run=client -o yaml | kubectl --context oke apply -f -
	sed "s|__ACME_EMAIL__|$$ACME_EMAIL|" $(K8S)/clusterissuer.yaml | kubectl --context oke apply -f -
	kubectl --context oke wait --for=condition=Ready clusterissuer/letsencrypt-cloudflare --timeout=120s
	$(MAKE) oke-deploy
	@echo "Ready: https://dinner.lazzarotto.dev"

oke-deploy: check-registry ## Apply the manifests and wait for the app
	$(MAKE) registry-secret
	kubectl --context oke create namespace dinner --dry-run=client -o yaml | kubectl --context oke apply -f -
	$(MAKE) db-init CONTEXT=oke
	kubectl kustomize $(K8S)/overlays/oke | sed "s|__OCIR_IMAGE__|$(OCIR_IMAGE)|" | kubectl --context oke apply -f -
	kubectl --context oke -n dinner rollout status deploy/app --timeout=180s

oke-status: ## Show pods, services, ingress, PVCs and certificates
	kubectl --context oke -n dinner get pods,svc,ingress,pvc -o wide
	-kubectl --context oke -n dinner get certificates

# Usage: eval "$(make -C infra oke-env)"
oke-env: ## Export KUBECONFIG and select the oke context for kubectl
	@echo 'export KUBECONFIG="$(KUBECONFIG)"'
	@echo 'kubectl config use-context oke >/dev/null'

oke-smoke: ## Hit /suggestion over HTTPS
	curl -sf https://dinner.lazzarotto.dev/suggestion; echo

# Rewrites prod.tfvars, so a later `oke-up` cannot silently revert the old CIDR.
oke-cidr: check-terraform ## Update the allowed source IP: make oke-cidr CIDR=1.2.3.4/32
	@test -n "$(CIDR)" || { echo "Usage: make oke-cidr CIDR=x.x.x.x/32"; exit 1; }
	@case "$(CIDR)" in */*) ;; *) echo "CIDR must be a block, e.g. 1.2.3.4/32"; exit 1 ;; esac
	sed -i.bak 's|^allowed_source_cidr.*|allowed_source_cidr = "$(CIDR)"|' prod.tfvars
	@rm -f prod.tfvars.bak
	@grep -n '^allowed_source_cidr' prod.tfvars
	terraform apply -var-file=prod.tfvars -auto-approve

oke-down: ## Delete the workloads and destroy the cluster
	-kubectl --context oke delete namespace dinner --ignore-not-found
	-kubectl --context oke delete clusterissuer letsencrypt-cloudflare --ignore-not-found
	-kubectl --context oke delete namespace ingress-nginx cert-manager --ignore-not-found
	-kubectl --context oke wait --for=delete namespace/dinner namespace/ingress-nginx namespace/cert-manager --timeout=300s
	terraform destroy -var-file=prod.tfvars -auto-approve
	@echo "Leftover load balancers (expect none):"
	@oci lb load-balancer list --compartment-id "$$(grep compartment_ocid prod.tfvars | cut -d'"' -f2)" --all \
		--query 'data[].{name:"display-name",state:"lifecycle-state"}' --output table || true

# ---------------------------------------------------------------- minikube

mk-up: ## Start minikube, enable ingress, build and load the image
	minikube start --cpus=2 --memory=4g
	minikube addons enable ingress
	cd .. && docker build -t dinner-roulette:latest .
	minikube image load dinner-roulette:latest

mk-deploy: ## Apply the manifests and wait for the app
	kubectl --context minikube create namespace dinner --dry-run=client -o yaml | kubectl --context minikube apply -f -
	$(MAKE) db-init CONTEXT=minikube
	kubectl kustomize $(K8S)/overlays/minikube | kubectl --context minikube apply -f -
	kubectl --context minikube -n dinner rollout status deploy/app --timeout=180s

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

check-terraform:
	@test -n "$(TF_VAR_tenancy_ocid)" || { echo "Missing TF_VAR_tenancy_ocid (infra/.secrets.env)"; exit 1; }

check-registry:
	@test -n "$(OCIR_IMAGE)" || { echo "Missing OCIR_IMAGE (infra/.secrets.env or environment)"; exit 1; }
	@test -n "$(OCIR_USERNAME)" || { echo "Missing OCIR_USERNAME (infra/.secrets.env or environment)"; exit 1; }
	@test -n "$(OCIR_AUTH_TOKEN)" || { echo "Missing OCIR_AUTH_TOKEN (infra/.secrets.env or environment)"; exit 1; }

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

# db/init.sql is read by Postgres on first init; the namespace must exist.
db-init: check-context
	kubectl --context $(CONTEXT) -n dinner create configmap db-init \
		--from-file=init.sql=../db/init.sql --dry-run=client -o yaml | kubectl --context $(CONTEXT) apply -f -
