# Step 5: Bring it up

One command creates the network, the cluster, the add-ons, the database and the app:

```bash
cd infra
make oke-up
```

**Time:** about 20 minutes from nothing. A few minutes if the cluster already exists.

This page explains everything that command does, in order, and how to check each part.

## Pre-flight checklist

- [x] `oci iam region list` works ([step 1](oci-account.md))
- [x] `dig +short A <your-host>` returns the reserved IP, record **DNS only** ([step 2](dns-tls.md))
- [x] `infra/.secrets.env` is complete, and `make plan` shows `Plan: 25 to add` ([step 3](configure.md))
- [x] the image exists in OCIR for the node's architecture ([step 4](image.md))
- [x] your current IP still matches `allowed_source_cidr` (`curl -4 -s https://ifconfig.me`)

!!! warning "No confirmation prompt"
    `make oke-up` runs `terraform apply -auto-approve`: it does not stop to ask whether the plan is right. Run `make plan` first if you want to review the changes.

The last lines of a successful run:

```text
deployment "app" successfully rolled out
Ready: https://dinner.example.com
```

## What happens, step by step

### 5.1 Pre-flight checks

Three internal targets check that the variables are not empty, and stop with a clear message otherwise:

- `check-terraform`: `TF_VAR_tenancy_ocid`;
- `check-registry`: `OCIR_IMAGE`, `OCIR_USERNAME`, `OCIR_AUTH_TOKEN`;
- `check-letsencrypt`: `ACME_EMAIL`, `CLOUDFLARE_API_TOKEN`.

```text
Missing OCIR_AUTH_TOKEN (infra/.secrets.env or environment)
```

They only check that a value exists, not that it is correct. A wrong token is detected later, by the service that rejects it.

### 5.2 Terraform creates the infrastructure

```bash
terraform -chdir=tf init
terraform -chdir=tf apply -var-file=prod.tfvars -auto-approve
```

`-chdir=tf` runs Terraform inside `infra/tf/` while `make` stays in `infra/`, so the relative paths to the Kubernetes files keep working. Terraform builds a dependency graph and creates resources in parallel where it can:

1. **VCN**, then the **Internet, NAT and Service gateways**, the **route tables**, the empty **security list** and the three **NSGs**. About one minute.
2. The **subnets** and the **11 NSG rules**.
3. The **OKE cluster**. Oracle provisions a control plane for you. This is the longest wait, usually 7 to 10 minutes, with `Still creating... [5m0s elapsed]` lines in the meantime.
4. The **node pool options** data source, which needs the cluster and is read only now, to pick the newest OKE node image.
5. The **node pool**. OCI boots the VM, installs the node software and waits until the node registers with the cluster. 5 to 10 minutes. This is where a shape without capacity fails, after several minutes stuck at "0 nodes provisioned".

You can follow the progress in the Console under **Developer Services → Kubernetes Clusters (OKE) → dinner-roulette**, or from a second terminal:

```bash
oci ce cluster list --compartment-id <compartment-ocid> --name dinner-roulette \
  --query 'data[].{name:name, state:"lifecycle-state", version:"kubernetes-version"}' --output table
```

When Terraform is done, it prints its outputs: the cluster OCID, the region, the NSG of the load balancer and the reserved IP's address and OCID. The next steps read them with `terraform output -raw <name>`.

### 5.3 The kubeconfig

```bash
rm -f infra/kubeconfig
oci ce cluster create-kubeconfig \
  --cluster-id "$(terraform -chdir=tf output -raw cluster_id)" \
  --file infra/kubeconfig \
  --region "$(terraform -chdir=tf output -raw region)" \
  --token-version 2.0.0
KUBECONFIG=infra/kubeconfig kubectl config rename-context "<generated name>" oke
```

The old file is removed first, so a context from a previous cluster never lingers. The OCI CLI writes a kubeconfig whose user does not contain a password or a certificate. Instead, it contains an **exec plugin**:

```yaml
users:
  - name: user-c…
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1beta1
        command: oci
        args: [ce, cluster, generate-token, --cluster-id, "ocid1.cluster.oc1…", --region, eu-milan-1]
```

Every time `kubectl` needs to authenticate, it runs that command. The OCI CLI signs a request with your API key and returns a short-lived token. Nothing long-lived is stored in the file, but every machine that uses it needs the OCI CLI and a working `~/.oci/config`.

The generated context name is renamed to `oke`, which is the name every later command uses with `--context oke`. Your `~/.kube/config` is not touched. See [kubeconfig, contexts and `--context`](../concepts.md#kubeconfig-contexts-and-context).

### 5.4 cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update jetstack ingress-nginx

helm upgrade --install cert-manager jetstack/cert-manager --version v1.17.1 \
  --namespace cert-manager --create-namespace --set crds.enabled=true --kube-context oke --wait
```

`crds.enabled=true` installs cert-manager's resource types (`Certificate`, `ClusterIssuer`, `Order`, `Challenge`, …) together with the chart. Three deployments start in the `cert-manager` namespace: the controller, the webhook that validates cert-manager objects, and the CA injector.

### 5.5 ingress-nginx and the load balancer

```bash
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --version 4.12.1 \
  --namespace ingress-nginx --create-namespace --kube-context oke --wait \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/oci-load-balancer-security-list-management-mode"=None \
  --set controller.service.annotations."oci\.oraclecloud\.com/oci-network-security-groups"="$(terraform -chdir=tf output -raw lb_nsg_id)" \
  --set controller.service.annotations."oci\.oraclecloud\.com/reserved-ips"="$(terraform -chdir=tf output -raw lb_reserved_ip)"
```

The chart creates the controller Deployment and a Service named `ingress-nginx-controller` of type **LoadBalancer**. On OKE, the **cloud controller manager** (CCM) watches such Services and creates a real OCI Load Balancer for each of them. The three annotations tell it how:

`service.beta.kubernetes.io/oci-load-balancer-security-list-management-mode: None`
:   Do not edit any security list. By default the CCM would add rules to the subnet's security list, opening the listener ports to the internet. Here all filtering is done by NSGs managed by Terraform, so the CCM must leave the security lists alone.

`oci.oraclecloud.com/oci-network-security-groups: <lb_nsg_id>`
:   Attach the load balancer to the `dinner-lb` NSG. Terraform owns its rules: 443 from your CIDR in, everything to the nodes out.

`oci.oraclecloud.com/reserved-ips: <address>`
:   Use the reserved IP instead of a random one. The annotation takes the **address**, which `outputs.tf` reads from the OCID in `prod.tfvars`.

The load balancer is placed in the public subnet, because the cluster's `service_lb_subnet_ids` option points there. It gets a TCP listener on 80 and one on 443, each forwarding to the matching NodePort on the worker node, plus health checks on the node. The listeners pass TLS through: nginx terminates it in the cluster.

Check:

```bash
kubectl --context oke -n ingress-nginx get svc ingress-nginx-controller
```

```text
NAME                       TYPE           CLUSTER-IP     EXTERNAL-IP    PORT(S)                      AGE
ingress-nginx-controller   LoadBalancer   10.96.45.120   203.0.113.10   80:3xxxx/TCP,443:3xxxx/TCP   3m
```

`EXTERNAL-IP` must be your reserved IP. If it stays `<pending>`, the events explain why: `kubectl --context oke -n ingress-nginx describe svc ingress-nginx-controller`.

### 5.6 The Let's Encrypt issuer

```bash
kubectl --context oke wait --for=condition=established crd/clusterissuers.cert-manager.io --timeout=120s

kubectl --context oke -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=token="$CLOUDFLARE_API_TOKEN" --dry-run=client -o yaml | kubectl --context oke apply -f -

sed "s|__ACME_EMAIL__|$ACME_EMAIL|" k8s/clusterissuer.yaml | kubectl --context oke apply -f -
kubectl --context oke wait --for=condition=Ready clusterissuer/letsencrypt-cloudflare --timeout=120s
```

1. Wait until the API server serves the `ClusterIssuer` type, so the apply below cannot fail on a type that is still being registered.
2. Store the Cloudflare token in a Secret. In the `Makefile` this line starts with `@`, so make does not print it, and the token never shows up in your terminal.
3. Fill in the email and apply the issuer.
4. Wait until it is `Ready`, which means cert-manager registered an ACME account with Let's Encrypt.

The Secret lives in `cert-manager` because cert-manager looks up the secrets of a **Cluster**Issuer in its own namespace.

### 5.7 Deploy the app (`make oke-deploy`)

```bash
kubectl --context oke create namespace dinner --dry-run=client -o yaml | kubectl --context oke apply -f -
make registry-secret                      # the ocir pull Secret, see step 4
make cnpg CONTEXT=oke                     # Helm: CloudNativePG operator 0.29.1 in cnpg-system
make db-init CONTEXT=oke                  # ConfigMap db-init from ../db/init.sql
kubectl kustomize k8s/overlays/oke | sed "s|__OCIR_IMAGE__|$OCIR_IMAGE|" | kubectl --context oke apply -f -
kubectl --context oke -n dinner rollout status deploy/app --timeout=300s
```

Same as on minikube, with three OKE-specific twists:

- **The image** is pulled from OCIR, with the `ocir` Secret. `sed` puts your `OCIR_IMAGE` in place of the placeholder.
- **The volume.** The PVC `db-1` uses the default storage class `oci-bv`. The OCI CSI driver creates a block volume of 50 GB, the minimum, and attaches it to the node. The class waits for the pod to be scheduled before creating the volume, so the volume ends up in the node's availability domain.
- **The certificate.** As soon as the Ingress exists, cert-manager starts the DNS-01 challenge described in [step 2](dns-tls.md#25-what-cert-manager-will-do-with-all-this). Until it finishes, about one to three minutes, nginx serves its self-signed "Kubernetes Ingress Controller Fake Certificate".

### 5.8 Done

```text
Ready: https://dinner.example.com
```

`rollout status` succeeded, so the app pod is Ready. The certificate may need another minute.

## Check that it works

```bash
make oke-status
make oke-smoke
```

`oke-status` shows the pods, Services, Ingress, PVC and certificate of the `dinner` namespace. Abridged:

```text
NAME                      READY   STATUS    RESTARTS   AGE   IP            NODE
pod/app-6c9f7d8b5-abcde   1/1     Running   0          3m    10.244.0.25   10.0.1.123
pod/db-1                  1/1     Running   0          4m    10.244.0.23   10.0.1.123

NAME            TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
service/app     ClusterIP   10.96.120.10   <none>        80/TCP     4m
service/db-rw   ClusterIP   10.96.88.31    <none>        5432/TCP   4m
…

NAME                            CLASS   HOSTS                ADDRESS        PORTS     AGE
ingress.networking.k8s.io/app   nginx   dinner.example.com   203.0.113.10   80, 443   4m

NAME                         STATUS   VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
persistentvolumeclaim/db-1   Bound    csi-…    50Gi       RWO            oci-bv         4m

NAME                                     READY   SECRET       AGE
certificate.cert-manager.io/dinner-tls   True    dinner-tls   4m
```

On OKE a node is named after its private IP. Pods get addresses from Flannel's overlay network (`10.244.x.x`), not from the VCN.

`oke-smoke` calls the public URL over HTTPS:

```bash
curl -sf https://dinner.example.com/suggestion; echo
# {"restaurant":{"id":"trattoria","name":"Trattoria da Mario","category":"italian","votes":0},"votes":0}
```

`-f` makes curl fail on HTTP errors, and certificate errors make it fail too, so a successful smoke test also proves that the certificate is valid. Try the rest of the API:

```bash
BASE=https://dinner.example.com
curl -s -H 'Content-Type: application/json' -d '{"user":"alice","restaurantId":"sakura"}' "$BASE/votes"; echo
curl -s "$BASE/suggestion"; echo
curl -s "$BASE/version"; echo        # the commit SHA of the image

# Who issued the certificate, and until when it is valid
curl -svo /dev/null "$BASE/health" 2>&1 | grep -E 'subject:|issuer:|expire date:'
```

## Use kubectl directly

```bash
eval "$(make oke-env)"
kubectl get nodes -o wide
kubectl get pods -A
```

`oke-env` prints an `export KUBECONFIG=…` line with absolute paths, so the result works from any directory, and a `use-context oke`. It lasts for the current terminal only.

## See it in the Console

- **Developer Services → Kubernetes Clusters (OKE) → dinner-roulette**: the cluster, its node pool and the node.
- **Networking → Load balancers**: the load balancer created by the CCM, with your reserved IP. Its backend sets should be healthy (**OK**).
- **Storage → Block volumes**: the PostgreSQL volume created by the CSI driver.
- **Networking → Virtual cloud networks → dinner-roulette**: subnets, route tables, gateways and the three NSGs with their rules.

## If it stops halfway

`make oke-up` is designed to be run again. Terraform only creates what is missing, `helm upgrade --install` upgrades in place, and the `kubectl apply` commands converge. Fix the cause, then run `make oke-up` again.

The most common stop is the node pool failing for lack of capacity. The cluster and the network stay in place. Change the shape in `prod.tfvars`, run `make apply`, which runs only Terraform, then `make oke-up`. See [Troubleshooting](../troubleshooting.md#node-pool-fails-with-work-request-exceeded-max-retry-count).

## Without make

??? example "The whole `oke-up`, command by command"
    Run from `infra/`. First load `.secrets.env` the way make does. A plain `source` would break on the unquoted SSH key, because the shell treats the words after the first space as a command.

    ```bash
    cd infra
    while IFS='=' read -r key value; do
      case "$key" in ''|\#*) continue ;; esac
      export "$key=$value"
    done < .secrets.env
    export KUBECONFIG="$HOME/.kube/config:$PWD/kubeconfig"
    OCIR_SERVER="${OCIR_IMAGE%%/*}"
    ```

    **Terraform and kubeconfig**

    ```bash
    terraform -chdir=tf init
    terraform -chdir=tf apply -var-file=prod.tfvars -auto-approve

    rm -f "$PWD/kubeconfig"
    oci ce cluster create-kubeconfig \
      --cluster-id "$(terraform -chdir=tf output -raw cluster_id)" \
      --file "$PWD/kubeconfig" \
      --region "$(terraform -chdir=tf output -raw region)" \
      --token-version 2.0.0
    KUBECONFIG="$PWD/kubeconfig" kubectl config rename-context \
      "$(KUBECONFIG="$PWD/kubeconfig" kubectl config current-context)" oke
    ```

    **Add-ons**

    ```bash
    helm repo add jetstack https://charts.jetstack.io
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo update jetstack ingress-nginx

    helm upgrade --install cert-manager jetstack/cert-manager --version v1.17.1 \
      --namespace cert-manager --create-namespace --set crds.enabled=true --kube-context oke --wait

    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --version 4.12.1 \
      --namespace ingress-nginx --create-namespace --kube-context oke --wait \
      --set controller.service.annotations."service\.beta\.kubernetes\.io/oci-load-balancer-security-list-management-mode"=None \
      --set controller.service.annotations."oci\.oraclecloud\.com/oci-network-security-groups"="$(terraform -chdir=tf output -raw lb_nsg_id)" \
      --set controller.service.annotations."oci\.oraclecloud\.com/reserved-ips"="$(terraform -chdir=tf output -raw lb_reserved_ip)"

    kubectl --context oke wait --for=condition=established crd/clusterissuers.cert-manager.io --timeout=120s
    kubectl --context oke -n cert-manager create secret generic cloudflare-api-token \
      --from-literal=token="$CLOUDFLARE_API_TOKEN" --dry-run=client -o yaml | kubectl --context oke apply -f -
    sed "s|__ACME_EMAIL__|$ACME_EMAIL|" k8s/clusterissuer.yaml | kubectl --context oke apply -f -
    kubectl --context oke wait --for=condition=Ready clusterissuer/letsencrypt-cloudflare --timeout=120s
    ```

    **App (`oke-deploy`)**

    ```bash
    kubectl --context oke create namespace dinner --dry-run=client -o yaml | kubectl --context oke apply -f -

    kubectl --context oke -n dinner create secret docker-registry ocir \
      --docker-server="$OCIR_SERVER" --docker-username="$OCIR_USERNAME" --docker-password="$OCIR_AUTH_TOKEN" \
      --dry-run=client -o yaml | kubectl --context oke apply -f -

    helm repo add cnpg https://cloudnative-pg.github.io/charts
    helm repo update cnpg
    helm upgrade --install cnpg cnpg/cloudnative-pg --version 0.29.1 \
      --namespace cnpg-system --create-namespace --kube-context oke --wait

    kubectl --context oke -n dinner create configmap db-init \
      --from-file=init.sql=../db/init.sql --dry-run=client -o yaml | kubectl --context oke apply -f -

    kubectl kustomize k8s/overlays/oke | sed "s|__OCIR_IMAGE__|$OCIR_IMAGE|" | kubectl --context oke apply -f -
    kubectl --context oke -n dinner rollout status deploy/app --timeout=300s
    ```

Next: [Step 6: Day-2 operations](operate.md).
