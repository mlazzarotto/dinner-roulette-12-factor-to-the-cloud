# All targets run from infra/. `make -C infra ...`
ENV ?=
K8S := k8s
RENDERED := $(K8S)/rendered

# Local secrets file, git-ignored. See .secrets.example.
-include .secrets.env
export

# The kubeconfig created by `oke-up` is kept in infra/ (git-ignored) and merged with yours,
# so the minikube context is never clobbered.
export KUBECONFIG := $(HOME)/.kube/config:$(CURDIR)/kubeconfig

# OKE uses the context "oke"; minikube uses its own profile context.
CONTEXT := $(ENV)

# Registry host taken from the image reference, so the pull secret cannot point elsewhere.
OCIR_SERVER := $(firstword $(subst /, ,$(OCIR_IMAGE)))

# Bare `make` lists the targets instead of hitting the first one.
.DEFAULT_GOAL := help

.PHONY: help check-env check-secrets check-registry \
	init plan apply \
	oke-up oke-deploy oke-status oke-smoke oke-cidr oke-down \
	mk-up mk-deploy mk-status mk-smoke mk-down \
	manifests registry-secret db-init deploy status smoke down

help: ## List available targets
	@awk 'BEGIN { FS = ":.*## " } /^[a-zA-Z0-9_.-]+:.*## / { n = $$1; if (n == "help") g = "gen"; else if (n ~ /^oke-/) g = "oke"; else if (n ~ /^mk-/) g = "mk"; else g = "tf"; line[g] = line[g] sprintf("  \033[36m%-14s\033[0m %s\n", n, $$2) } END { print "Generale:"; printf "%s", line["gen"]; print "\nTerraform, da infra/:"; printf "%s", line["tf"]; print "\nOKE:"; printf "%s", line["oke"]; print "\nminikube:"; printf "%s", line["mk"] }' $(firstword $(MAKEFILE_LIST))

# ---------------------------------------------------------------- Terraform

init: ## Initialise the Terraform working directory
	terraform init

plan: ## Show the Terraform plan for prod.tfvars
	terraform plan -var-file=prod.tfvars

# Terraform only, no kubeconfig or addons. Useful after a partial `oke-up`.
apply: check-secrets ## Apply prod.tfvars without the full bootstrap
	terraform init
	terraform apply -var-file=prod.tfvars -auto-approve

# ---------------------------------------------------------------- OKE

oke-up: check-secrets ## Create the cluster, the addons and deploy (~20 min)
	terraform init
	terraform apply -var-file=prod.tfvars -auto-approve
	oci ce cluster create-kubeconfig --cluster-id "$$(terraform output -raw cluster_id)" \
		--file $(CURDIR)/kubeconfig --region "$$(terraform output -raw region)" --token-version 2.0.0
	kubectl config rename-context "$$(terraform output -raw cluster_id)" oke
	helm repo add jetstack https://charts.jetstack.io >/dev/null
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
	helm repo update >/dev/null
	helm upgrade --install cert-manager jetstack/cert-manager --version v1.17.1 \
		--namespace cert-manager --create-namespace --set crds.enabled=true --kube-context oke --wait
	# The LB annotations belong on the controller Service, which is what the CCM reads.
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --version 4.12.1 \
		--namespace ingress-nginx --create-namespace --kube-context oke --wait \
		--set controller.service.annotations."service\.beta\.kubernetes\.io/oci-load-balancer-security-list-management-mode"=None \
		--set controller.service.annotations."oci\.oraclecloud\.com/oci-network-security-groups"="$$(terraform output -raw lb_nsg_id)" \
		--set controller.service.annotations."oci\.oraclecloud\.com/reserved-ips"="$$(terraform output -raw lb_reserved_ip)"
	kubectl --context oke wait --for=condition=established crd/clusterissuers.cert-manager.io --timeout=120s
	kubectl --context oke -n cert-manager create secret generic cloudflare-api-token \
		--from-literal=token="$$CLOUDFLARE_API_TOKEN" --dry-run=client -o yaml | kubectl --context oke apply -f -
	$(MAKE) manifests
	kubectl --context oke apply -f $(RENDERED)/clusterissuer.yaml
	kubectl --context oke wait --for=condition=Ready clusterissuer/letsencrypt-cloudflare --timeout=120s
	$(MAKE) deploy ENV=oke
	@echo "Ready: https://dinner.lazzarotto.dev"

oke-deploy: ## Apply the manifests and wait for the app
	$(MAKE) deploy ENV=oke

oke-status: ## Show pods, services, ingress, PVCs and certificates
	$(MAKE) status ENV=oke

oke-smoke: ## Hit /suggestion over HTTPS
	$(MAKE) smoke ENV=oke

# Rewrites prod.tfvars, so a later `oke-up` cannot silently revert the old CIDR.
oke-cidr: check-secrets ## Update the allowed source IP: make oke-cidr CIDR=1.2.3.4/32
	@test -n "$(CIDR)" || { echo "Usage: make oke-cidr CIDR=x.x.x.x/32"; exit 1; }
	@case "$(CIDR)" in */*) ;; *) echo "CIDR must be a block, e.g. 1.2.3.4/32"; exit 1 ;; esac
	sed -i.bak 's|^allowed_source_cidr.*|allowed_source_cidr = "$(CIDR)"|' prod.tfvars
	@rm -f prod.tfvars.bak
	@grep -n '^allowed_source_cidr' prod.tfvars
	terraform apply -var-file=prod.tfvars -auto-approve

oke-down: ## Delete the workloads and destroy the cluster
	$(MAKE) down ENV=oke

# ---------------------------------------------------------------- minikube

mk-up: ## Start minikube, enable ingress, build and load the image
	minikube start --cpus=2 --memory=4g
	minikube addons enable ingress
	cd .. && docker build -t dinner-roulette:latest .
	minikube image load dinner-roulette:latest

mk-deploy: ## Apply the manifests and wait for the app
	$(MAKE) deploy ENV=minikube

mk-status: ## Show pods, services, ingress and PVCs
	$(MAKE) status ENV=minikube

mk-smoke: ## Hit /suggestion on dinner.local
	$(MAKE) smoke ENV=minikube

mk-down: ## Delete the workloads, keep the VM and the image
	$(MAKE) down ENV=minikube

# ---------------------------------------------------------------- internal

check-env:
	@case "$(ENV)" in \
		oke|minikube) ;; \
		*) echo "Internal target: ENV must be oke or minikube. Use oke-* or mk-*."; exit 1 ;; \
	esac

check-secrets:
	@test -f .secrets.env || { echo "Missing infra/.secrets.env (copy .secrets.example)"; exit 1; }
	@test -n "$(OCIR_IMAGE)" || { echo "OCIR_IMAGE is empty in infra/.secrets.env"; exit 1; }

check-registry:
	@test -n "$(OCIR_IMAGE)" || { echo "OCIR_IMAGE is empty in infra/.secrets.env"; exit 1; }
	@test -n "$(OCIR_USERNAME)" || { echo "OCIR_USERNAME is empty in infra/.secrets.env"; exit 1; }
	@test -n "$(OCIR_AUTH_TOKEN)" || { echo "OCIR_AUTH_TOKEN is empty in infra/.secrets.env"; exit 1; }

# Renders the placeholders into k8s/rendered/, which is git-ignored.
manifests:
	mkdir -p $(RENDERED)
	sed "s|__ACME_EMAIL__|$$ACME_EMAIL|" $(K8S)/clusterissuer.yaml > $(RENDERED)/clusterissuer.yaml
	sed "s|__OCIR_IMAGE__|$$OCIR_IMAGE|" $(K8S)/app-oke.yaml > $(RENDERED)/app-oke.yaml

# The private image cannot be pulled without this. Idempotent, and it reads the registry
# host from OCIR_IMAGE. Needs the dinner namespace to exist (db.yaml creates it).
registry-secret: check-env check-registry
	kubectl --context $(CONTEXT) -n dinner create secret docker-registry ocir \
		--docker-server="$(OCIR_SERVER)" \
		--docker-username="$(OCIR_USERNAME)" \
		--docker-password="$(OCIR_AUTH_TOKEN)" \
		--dry-run=client -o yaml | kubectl --context $(CONTEXT) apply -f -

# db/init.sql is read by Postgres on first init; the namespace must exist.
db-init: check-env
	kubectl --context $(CONTEXT) -n dinner create configmap db-init \
		--from-file=init.sql=../db/init.sql --dry-run=client -o yaml | kubectl --context $(CONTEXT) apply -f -

deploy: check-env
ifeq ($(ENV),oke)
	$(MAKE) manifests
	# Namespace first: the pods need the pull secret before they are scheduled.
	kubectl --context oke create namespace dinner --dry-run=client -o yaml | kubectl --context oke apply -f -
	$(MAKE) registry-secret ENV=oke
	kubectl --context oke apply -f $(K8S)/db.yaml -f $(RENDERED)/app-oke.yaml -f $(K8S)/ingress-oke.yaml
	$(MAKE) db-init ENV=oke
	kubectl --context oke -n dinner rollout status deploy/app --timeout=180s
else
	kubectl --context minikube apply -f $(K8S)/db.yaml -f $(K8S)/app-minikube.yaml -f $(K8S)/ingress-minikube.yaml
	$(MAKE) db-init ENV=minikube
	kubectl --context minikube -n dinner rollout status deploy/app --timeout=180s
endif

status: check-env
	kubectl --context $(CONTEXT) -n dinner get pods,svc,ingress,pvc -o wide
	-kubectl --context $(CONTEXT) -n dinner get certificates

# Workloads first: the LB and the block volume are created by the CCM and the CSI driver,
# so `destroy` would block on a subnet still in use.
down: check-env
ifeq ($(ENV),oke)
	$(MAKE) manifests
	-kubectl --context oke -n dinner delete -f $(K8S)/ingress-oke.yaml --ignore-not-found
	-kubectl --context oke -n dinner delete -f $(RENDERED)/app-oke.yaml --ignore-not-found
	-kubectl --context oke -n dinner delete -f $(K8S)/db.yaml --ignore-not-found
	-kubectl --context oke -n dinner delete pvc --all --ignore-not-found
	-kubectl --context oke delete namespace ingress-nginx cert-manager --ignore-not-found
	-kubectl --context oke wait --for=delete namespace/ingress-nginx namespace/cert-manager --timeout=300s
	terraform destroy -var-file=prod.tfvars -auto-approve
	@echo "Leftover load balancers (expect none):"
	@oci lb load-balancer list --compartment-id "$$(grep compartment_ocid prod.tfvars | cut -d'"' -f2)" --all \
		--query 'data[].{name:"display-name",state:"lifecycle-state"}' --output table || true
else
	-kubectl --context minikube -n dinner delete -f $(K8S)/ingress-minikube.yaml --ignore-not-found
	-kubectl --context minikube -n dinner delete -f $(K8S)/app-minikube.yaml --ignore-not-found
	-kubectl --context minikube -n dinner delete -f $(K8S)/db.yaml --ignore-not-found
	-kubectl --context minikube wait --for=delete namespace/dinner --timeout=120s
endif

# The app has no DB-backed health check, so smoke-test a real query path.
smoke: check-env
ifeq ($(ENV),minikube)
	curl -sf -H 'Host: dinner.local' http://$$(minikube ip)/suggestion
else
	curl -sf https://dinner.lazzarotto.dev/suggestion
endif
