# Troubleshooting

Each entry gives the **symptom** you see, the **cause**, and the **fix**. Many of them were hit for real while this setup was being built. Use the search box (top right) with a fragment of your error message.

## First moves for any Kubernetes problem

Replace `<ctx>` with `minikube` or `oke`:

```bash
kubectl --context <ctx> -n dinner get pods                          # which pod is unhappy, and its STATUS
kubectl --context <ctx> -n dinner describe pod <pod>                # the Events at the bottom say why
kubectl --context <ctx> -n dinner get events --sort-by=.lastTimestamp
kubectl --context <ctx> -n dinner logs <pod> -c <container>         # add --previous after a crash
kubectl --context <ctx> -n dinner get cluster db                    # CNPG's view of the database
```

The `STATUS` column alone often points to the right entry below: `ErrImageNeverPull`, `ImagePullBackOff`, `Init:0/1`, `CreateContainerConfigError`, `CrashLoopBackOff`.

## minikube

### `ErrImageNeverPull` on the app pod

**Cause.** `imagePullPolicy: Never` tells kubelet to use only images already inside minikube, and `dinner-roulette:local` is not there. Either it was never loaded, or it was built with another tag. The overlay expects exactly `dinner-roulette:local`.

**Fix.**

```bash
minikube image ls | grep dinner-roulette            # expect docker.io/library/dinner-roulette:local
cd .. && docker build -t dinner-roulette:local . && minikube image load dinner-roulette:local && cd infra
kubectl --context minikube -n dinner rollout restart deploy/app
```

### minikube does not start, or ignores `--cpus` and `--memory`

**Cause.** Resources are fixed when the cluster is created. An existing profile keeps its old size. On macOS and Windows, Docker Desktop's own memory limit can also be lower than the 4 GB requested.

**Fix.** `minikube delete`, then `make mk-up` again. Raise Docker Desktop's memory limit if needed. `minikube logs` shows the details of a failed start.

### The app pod stays in `Init:0/1`

**Cause.** The `wait-for-db` init container is still waiting for `db-rw` to accept connections. The database is not up yet, or failed.

**Fix.** Check the database and the operator:

```bash
kubectl --context minikube -n dinner logs deploy/app -c wait-for-db     # "db-rw:5432 - no response" while waiting
kubectl --context minikube -n dinner get cluster db
kubectl --context minikube -n dinner get pods                            # db-1-initdb and db-1
kubectl --context minikube -n cnpg-system logs -l app.kubernetes.io/name=cloudnative-pg --tail=50
```

On the first run, waiting a couple of minutes is normal: the PostgreSQL image is being downloaded. A failed `db-1-initdb` pod usually points to an error in `db/init.sql`; its logs show the SQL error.

### `CreateContainerConfigError`: secret "db-app" not found

**Cause.** The app refers to the Secret `db-app`, which CNPG creates when it bootstraps the `Cluster`. The bootstrap has not happened yet, or has failed.

**Fix.** Same checks as the previous entry. The pod recovers on its own as soon as the Secret exists.

### `no matches for kind "Cluster" in version "postgresql.cnpg.io/v1"`

**Cause.** The manifests were applied before the CNPG operator, so the API server does not know the `Cluster` type yet. That happens when you run `kubectl apply` by hand on a fresh cluster.

**Fix.** Install the operator, then apply again. `make mk-deploy` does both in the right order:

```bash
make cnpg CONTEXT=minikube
make mk-deploy
```

### Helm: "exists and cannot be imported into the current release"

**Symptom.** `make cnpg` fails with something like `Unable to continue with install: ServiceAccount "…" in namespace "cnpg-system" exists and cannot be imported into the current release: invalid ownership metadata`.

**Cause.** The operator was installed earlier without Helm, for example with `kubectl apply -f cnpg-1.x.y.yaml`. Helm refuses to take over objects it did not create.

**Fix.** Remove the old installation with the same manifest it was installed from (`kubectl delete -f <that file>`), or delete the `cnpg-system` namespace, then run `make cnpg CONTEXT=minikube` again.

!!! danger
    Deleting the CNPG CRDs deletes every PostgreSQL `Cluster` in the cluster, with its data. On minikube that is usually fine. Think twice anywhere else.

### `make mk-smoke` fails or returns 404

- **`404 Not Found` from nginx**: the request reached the ingress controller without `Host: dinner.local`, so no rule matched. Always send the header, or map `dinner.local` in `/etc/hosts`.
- **Connection refused on 18080**: the port-forward did not start. Check that the controller runs (`kubectl --context minikube -n ingress-nginx get pods`) and that nothing else uses port 18080.
- **`503 Service Temporarily Unavailable`**: the Ingress works, but the `app` Service has no ready pod. See the entries above.

### The app still runs the old code after a rebuild

**Cause.** The manifest did not change, so `kubectl apply` did not restart anything. The running pod keeps the image it started with.

**Fix.** After `minikube image load`, run `kubectl --context minikube -n dinner rollout restart deploy/app`.

### Changes to `db/init.sql` have no effect

**Cause.** CNPG runs it **once**, when the database is created. Updating the ConfigMap afterwards changes nothing in an existing database.

**Fix.** Recreate the database: `make mk-down && make mk-deploy`. This deletes the votes. On OKE, the next `oke-down` and `oke-up` cycle does the same.

## OCI authentication and Terraform

### "did not find a proper configuration for private key"

**Symptom.** `make plan` or `make oke-up` stops with `Error: can not create client, bad configuration: did not find a proper configuration for private key`.

**Cause.** The `[DEFAULT]` profile in `~/.oci/config` points to an **encrypted** private key and has no `pass_phrase`. Terraform cannot prompt for one. A wrong `key_file` path gives the same error.

**Fix.** Add `pass_phrase=<passphrase>` to the profile, or use a key without passphrase. Check that `key_file` exists and is readable. Then `oci iam region list` must work.

### NotAuthenticated (401) from OCI

**Cause.** The four values of the profile do not belong together: the key file, its `fingerprint`, the `user` OCID and the `tenancy` OCID. Typical cases are a key that was never uploaded to that user, a key that was replaced, or a profile copied from another tenancy. A wrong system clock can cause it too.

**Fix.** In the Console, under **My profile → API keys**, compare the fingerprint with the `fingerprint=` line. Upload the public key again if needed. Check the user and tenancy OCIDs, and that your clock is synchronised.

### `Missing TF_VAR_tenancy_ocid (infra/.secrets.env)`

**Cause.** `infra/.secrets.env` does not exist, the variable is empty, or `make` is running in another directory, where the file is not found.

**Fix.** Run from `infra/`, or use `make -C infra …`. Create the file from `.secrets.example` ([step 3](oke/configure.md)).

### Terraform asks for `var.tenancy_ocid`

**Cause.** Same as above, with `make plan`, which does not run the variable checks.

**Fix.** Press ++ctrl+c++ and fix `infra/.secrets.env`.

### Node pool fails with "Work request exceeded max retry count"

**Symptom.** Terraform has been creating the node pool for several minutes. The Console shows **0 nodes provisioned**. Then the apply fails with `Work request exceeded max retry count`, sometimes mentioning `Out of host capacity`, and OKE deletes the node pool.

**Cause.** The availability domain has no free hardware for this shape right now. It is not a quota or account problem. `VM.Standard.A1.Flex` is often full, and E-series shapes can be full too at times.

**Fix.** The cluster and the network are fine and stay in place.

1. Change the shape in `infra/tf/prod.tfvars`, for example:

    ```hcl
    node_shape      = "VM.Standard.E4.Flex"   # or E3.Flex, E5.Flex
    node_ocpus      = 1
    node_memory_gbs = 8
    ```

2. Make sure the image architecture matches the new shape ([step 4](oke/image.md#make-sure-the-architecture-matches)).
3. Run `make apply`, which runs only Terraform, then `make oke-up`.

If Terraform complains about a node pool that no longer exists, refresh the state first: `terraform -chdir=tf apply -refresh-only -var-file=prod.tfvars -auto-approve`. To check capacity before trying, use the capacity report from [step 1.9](oke/oci-account.md#19-optional-checks). Retrying the same shape later can also work.

### The node pool is rejected because of the SSH key

**Cause.** `TF_VAR_ssh_public_key` still holds the placeholder `ssh-ed25519 AAAA... you@laptop`, or the key is wrapped in quotes, which make keeps literally.

**Fix.** Put a real public key without quotes, for example the content of `~/.ssh/id_ed25519.pub`, or delete the line. Then `make apply`.

### Terraform: "Invalid index" on `local.oke_node_image_names`

**Cause.** No OKE node image matched the filters in `cluster.tf`: OKE image, cluster version, Oracle Linux 9, no GPU, the shape's architecture. The list is empty, and taking its last element fails. The usual reason is a `k8s_version` that OKE no longer offers images for.

**Fix.** List the supported versions and set a current one in `prod.tfvars`:

```bash
oci ce cluster-options get --cluster-option-id all --query 'data."kubernetes-versions"'
```

### The cluster's Kubernetes version is rejected

**Cause.** Creating the cluster fails because `k8s_version` is not, or no longer, a supported version.

**Fix.** Same as above: pick a listed version.

### `LimitExceeded` or quota errors

**Cause.** The tenancy has reached a service limit: number of clusters, OCPUs of a shape family, load balancers, or block volume storage. Always Free tenancies have low limits.

**Fix.** **Governance & Administration → Limits, Quotas and Usage** in the Console shows the limit and current usage. Delete unused resources, choose another shape, or request a limit increase on a paid account.

### Nodes never join: "node(s) register timeout" or the `uninitialized` taint

**Cause.** Network rules between the nodes and the control plane are missing. Nodes must reach the API endpoint on 6443 and 12250, and the control plane must reach the OCI APIs on 443. The repository's NSGs already include these rules. This happens only if you changed `network.tf`.

**Fix.** Restore the rules `endpoint_in_6443_nodes`, `endpoint_in_12250_nodes` and `endpoint_egress_https` in `infra/tf/network.tf`.

## kubectl and the API endpoint

### `context "oke" does not exist`

**Cause.** Plain `kubectl` reads only `~/.kube/config`. The `oke` context lives in `infra/kubeconfig`, which only the `Makefile` adds automatically. In a fresh clone the file does not exist at all.

**Fix.** `eval "$(make oke-env)"` in your terminal. If `infra/kubeconfig` is missing, run `make oke-up` again: on an existing cluster it rewrites the kubeconfig in seconds and changes nothing else.

### kubectl hangs: `dial tcp …:6443: i/o timeout`

**Cause.** Your public IP is no longer `allowed_source_cidr`, because of a VPN or a new address from your ISP.

**Fix.** `make oke-cidr CIDR="$(curl -4 -s https://ifconfig.me)/32"`. See [Day-2 operations](oke/operate.md#when-your-ip-address-changes).

### `executable oci not found`, or kubectl asks for a passphrase

**Cause.** The OKE kubeconfig runs `oci ce cluster generate-token` for every request. The OCI CLI must be in your `PATH`, and its key must be usable without a prompt.

**Fix.** Install the OCI CLI, or fix your `PATH`. Add `pass_phrase` to the profile if the key is encrypted.

## Load balancer, DNS and TLS

### The ingress-nginx Service stays `<pending>`, or `helm --wait` times out

**Cause.** The cloud controller manager could not create the load balancer. Common reasons: the reserved IP is already assigned to another resource, it lives in another region or compartment, the tenancy's load balancer limit is reached, or the NSG OCID is wrong.

**Fix.** The events say which one:

```bash
kubectl --context oke -n ingress-nginx describe svc ingress-nginx-controller
```

Check the reserved IP's state with the `public-ip list` command from [step 1.7](oke/oci-account.md#17-reserve-a-public-ip). It must be `AVAILABLE` before `oke-up`.

### `https://<host>` times out

Check, in this order:

```bash
dig +short A dinner.example.com          # 1. must be the reserved IP, not a Cloudflare address
curl -4 -s https://ifconfig.me; echo     # 2. must be inside allowed_source_cidr
kubectl --context oke -n ingress-nginx get svc ingress-nginx-controller   # 3. EXTERNAL-IP = reserved IP

# 4. bypass DNS entirely and talk to the load balancer
curl -sv --resolve dinner.example.com:443:203.0.113.10 https://dinner.example.com/health
```

1. **DNS returns other addresses**: the record is **Proxied** (orange cloud). Set it to **DNS only**. Cloudflare's servers are not in `allowed_source_cidr`, so their connections are dropped.
2. **Your IP is not allowed**: run `make oke-cidr`.
3. **The Service has no external IP**: see the previous entry.
4. **It works with `--resolve` but not without**: the problem is DNS. Wait for propagation, or check the nameservers.

Remember that **port 80 is closed on purpose**. `http://…` always times out. Typing the bare host name in a browser tries `http://` first, except on TLDs such as `.dev` that are on the HSTS preload list and always use HTTPS.

### Connections reset, or the load balancer reports its backends as critical

**Cause.** The load balancer cannot health-check the node. Its probe goes to kube-proxy's health port (10256), and the NSG rule `nodes_from_lb` must allow **all** traffic from the load balancer's NSG. With a narrower port range, the health check stays critical and the load balancer resets every connection.

**Fix.** Keep `nodes_from_lb` as it is in `infra/tf/network.tf`. In the Console, the load balancer's **Backend sets** page shows the health of each backend.

### The browser warns about "Kubernetes Ingress Controller Fake Certificate"

**Cause.** nginx serves its built-in self-signed certificate because `dinner-tls` does not exist yet: the certificate has not been issued.

**Fix.** Wait one to three minutes after the deploy. If the warning stays, see the next entry.

### The Certificate stays `READY False`

Follow the chain of objects cert-manager creates:

```bash
kubectl --context oke -n dinner describe certificate dinner-tls
kubectl --context oke -n dinner get certificaterequest,order,challenge
kubectl --context oke -n dinner describe challenge        # the most useful one
kubectl --context oke -n cert-manager logs deploy/cert-manager --tail=100
```

What the challenge usually says, and what to do:

| Message from the challenge | Cause | Fix |
|---|---|---|
| Authentication or permission error from Cloudflare | Wrong token, or a token without **Zone → DNS → Edit** (*DNS Settings* is not enough) | Fix the token ([2.3](oke/dns-tls.md#23-create-the-cloudflare-api-token)), update `.secrets.env`, run `make oke-up` again |
| The zone cannot be found | The token's Zone Resources do not include the zone, or the zone is in another Cloudflare account | Add the zone to the token |
| Waiting for DNS-01 challenge propagation | The TXT record is not visible on the authoritative nameservers. The zone may still be **Pending**, or the registrar may point elsewhere | Check `dig +short NS <zone>`, and wait for the zone to be **Active** |
| `rateLimited` | Too many certificates for the same host name this week | See the next entries |

After fixing the token, `make oke-up` updates the Secret. cert-manager retries on its own, but after a failure it waits longer and longer between attempts. To retry immediately, delete the Certificate: `kubectl --context oke -n dinner delete certificate dinner-tls`. cert-manager recreates it from the Ingress annotation right away and starts a fresh attempt.

### The ClusterIssuer is not Ready

**Cause.** cert-manager could not register the ACME account. Most often `ACME_EMAIL` is still a placeholder: Let's Encrypt rejects addresses at `example.com`.

**Fix.** `kubectl --context oke describe clusterissuer letsencrypt-cloudflare` shows the error. Put a real address in `.secrets.env` and run `make oke-up` again.

### `rateLimited` from Let's Encrypt

**Cause.** Let's Encrypt issues at most 5 certificates for the exact same set of host names every 7 days, and every `oke-up` after an `oke-down` requests a new one.

**Fix.** Wait for the window to pass. While experimenting, use the staging endpoint, as explained in [step 2](oke/dns-tls.md#25-what-cert-manager-will-do-with-all-this).

## The app on OKE

### ImagePullBackOff on the app pod

`kubectl --context oke -n dinner describe pod -l app=app` shows the registry's answer in the Events:

| Message | Cause | Fix |
|---|---|---|
| `Repository Name Unknown`, `not found` | The image was never pushed to this path. The repository does not exist, or the tag, the namespace or the region in `OCIR_IMAGE` is wrong | Push it ([step 4](oke/image.md)). With CI, check that `OCIR_NAMESPACE` is **your** namespace |
| `unauthorized`, `denied`, `403` | The `ocir` Secret has wrong credentials: username format or token | Fix `.secrets.env`, then `make registry-secret` |
| `no match for platform in manifest` | The image does not contain the node's architecture | Rebuild for the right platform ([step 4](oke/image.md#make-sure-the-architecture-matches)) |

After the fix, restart the rollout. Kubelet waits longer and longer between pull attempts, so do not wait for it:

```bash
kubectl --context oke -n dinner rollout restart deploy/app
kubectl --context oke -n dinner rollout status deploy/app
```

### `exec format error`, or `CrashLoopBackOff` right after start

**Cause.** The image's architecture differs from the node's: an amd64 image on an A1 node, or an arm64 image on an E-series node. `make oke-push` builds for your laptop's architecture only.

**Fix.** Push a multi-architecture image through CI, or build with `docker buildx --platform` ([step 4](oke/image.md#make-sure-the-architecture-matches)). Then restart the rollout.

### `rollout status` times out in `make oke-deploy`

**Cause.** The new pod did not become Ready within 300 seconds. The real reason is in the pod: an image problem, the database not ready, or a crash.

**Fix.** Go through the [first moves](#first-moves-for-any-kubernetes-problem). After fixing the cause, `make oke-deploy` alone may not be enough. Add a `kubectl rollout restart` as shown above.

### `docker login` to OCIR fails

**Cause.** Usually the username format, a token that is too new, or special characters in the token.

**Fix.**

- The username is `<tenancy-namespace>/<username>`, with the identity domain in the middle if your profile shows one ([step 1.6](oke/oci-account.md#16-work-out-your-registry-host-and-username)). The namespace is the Object Storage namespace, not the tenancy name.
- A new token can take a minute to work.
- Through `make`, a token with `$` or `#` is mangled. See [special characters](oke/configure.md#special-characters-in-values).
- The registry host must match the region: `eu-milan-1.ocir.io` for Milan.

## Teardown

See [If the teardown fails](oke/teardown.md#if-the-teardown-fails).
