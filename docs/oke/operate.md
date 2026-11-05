# Step 6: Day-2 operations

Everyday tasks once the stack is up: checking it, shipping a new version, reading logs, working with the database, following your IP when it changes, and deploying from CI.

All commands run from `infra/`. Those that use plain `kubectl` assume you ran `eval "$(make oke-env)"` in the same terminal. The `make` targets do not need it.

## Check the state

```bash
make oke-status                                    # pods, Services, Ingress, PVC, certificate
make oke-smoke                                     # GET /suggestion over HTTPS
kubectl -n dinner get events --sort-by=.lastTimestamp | tail -20    # what happened recently
kubectl -n dinner get cluster db                   # Postgres health, according to CNPG
```

## Deploy a new version of the app

### With the moving `latest` tag

Push a new image first, through CI or `make oke-push` ([step 4](image.md)). Then:

```bash
kubectl --context oke -n dinner rollout restart deploy/app
kubectl --context oke -n dinner rollout status deploy/app
```

`make oke-deploy` alone does **not** roll out the new image. The manifest still says `…/dinner-roulette:latest`, so for Kubernetes nothing has changed. `rollout restart` changes an annotation in the pod template, which starts a rolling update. The new pod pulls `latest` again (`imagePullPolicy: Always`) and gets the new image.

### With immutable tags (better)

CI also pushes every image under its full commit SHA. Deploying a specific SHA makes the manifest change, gives you a real rollout history and makes rollbacks exact:

```bash
SHA=$(git rev-parse HEAD)     # a commit that the build workflow has already pushed
make oke-deploy OCIR_IMAGE="eu-milan-1.ocir.io/<tenancy-namespace>/dinner-roulette:$SHA"

kubectl --context oke -n dinner rollout history deploy/app
kubectl --context oke -n dinner rollout undo deploy/app        # back to the previous version
```

Pass `OCIR_IMAGE` **as a make argument**, after the target, as above. Variables given on the command line override the file. An environment variable (`OCIR_IMAGE=… make oke-deploy`) would not, because the value in `.secrets.env` wins over the environment.

### With a release-please version

The [`release` workflow](https://github.com/mlazzarotto/dinner-roulette-12-factor-to-the-cloud/blob/main/.github/workflows/release.yml) cuts a semver tag and deploys that image. It runs on every push to `main`, but it only acts when release-please creates a release. `app.yaml` stays `image: __OCIR_IMAGE__`. The registry path is filled in at deploy time, from the region and `OCIR_USERNAME`, exactly as for a manual deploy. Only the tag changes, from `latest` to the version release-please just published (`1.1.0`). Kubernetes sees a different image string and rolls the Deployment out.

What happens, push by push:

1. A push to `main` whose message starts with `feat:` or `fix:` makes release-please open or update a release PR. That PR bumps `package.json` and `package-lock.json` and writes `CHANGELOG.md` (the first one creates it). `build.yml` still pushes `:<sha>` and `:latest`. The cluster does not move.
2. Merging the release PR creates the GitHub Release and the tag `v1.1.0`. The `publish` job checks out that commit, pushes `dinner-roulette:1.1.0` and runs `make oke-deploy OCIR_IMAGE="…/dinner-roulette:1.1.0"`.
3. A push that is not a conventional commit, or that only updates the open release PR, leaves `release_created` false. The `publish` job is skipped.

`1.0.0` in `.release-please-manifest.json` is the last released version, matching `package.json`. The next release PR starts from the conventional commits after that. The repository setting **Allow GitHub Actions to create and approve pull requests** must be on, otherwise release-please cannot open the PR.

The `publish` job reaches the cluster the same way as the manual `deploy` workflow, so the three conditions in [Deploy from GitHub Actions](#deploy-from-github-actions) apply to it too. It also needs the same variables there: `TF_VAR_region`, `HOST`, `OCIR_USERNAME` and `OCIR_AUTH_TOKEN`. `OCIR_IMAGE` is passed as a make argument, for the reason in the section above. If the cluster is down, the image is still in OCIR under the version tag. Deploy it later with `make oke-deploy OCIR_IMAGE="…/dinner-roulette:1.1.0"`.

`publish` builds the image again from the release commit, rather than retagging the `:<sha>` image `build.yml` already pushed. That is deliberately redundant: the job does not depend on `build.yml` having finished for the same push, which it cannot guarantee. If you want the quicker variant later, `docker buildx imagetools create -t …:<version> …:<sha>` copies the existing multi-arch manifest in a second, but it fails whenever the build has not pushed that SHA yet.

## Read the logs

```bash
kubectl --context oke -n dinner logs deploy/app                    # the app container
kubectl --context oke -n dinner logs deploy/app -c wait-for-db     # the init container
kubectl --context oke -n dinner logs db-1                          # PostgreSQL, JSON lines
kubectl --context oke -n ingress-nginx logs deploy/ingress-nginx-controller --tail=50   # access log of every request
```

!!! info "Where are the request logs?"
    `kubectl logs deploy/app` shows little more than the start-up line. The app still writes its request log to `logs/app.log` **inside the container**, which is one of the defects the workshop is about (12-Factor **XI. Logs**: treat logs as event streams on stdout). Until it is fixed, read the file directly:

    ```bash
    kubectl --context oke -n dinner exec deploy/app -- tail -f logs/app.log
    ```

    The file disappears with the pod. That is exactly the problem the workshop's incident card describes.

The operators log to stdout as usual:

```bash
kubectl --context oke -n cert-manager logs deploy/cert-manager --tail=50
kubectl --context oke -n cnpg-system logs -l app.kubernetes.io/name=cloudnative-pg --tail=50
```

## Work with the database

The same commands as on minikube, with `--context oke`:

```bash
# Query as the superuser, from inside the pod
kubectl --context oke -n dinner exec -it db-1 -c postgres -- \
  psql -d dinner_roulette -c 'SELECT id, votes FROM restaurants ORDER BY votes DESC;'

# The app user's password, generated by CNPG and never stored anywhere else
kubectl --context oke -n dinner get secret db-app -o jsonpath='{.data.password}' | base64 -d; echo

# A local client, through a tunnel to the primary
kubectl --context oke -n dinner port-forward svc/db-rw 5432:5432
```

??? tip "Keeping the votes across sessions"
    `make oke-down` deletes the database volume, so every session starts from the seed data. To carry the votes over, dump them before the teardown and load them after the next `oke-up`:

    ```bash
    # before make oke-down
    kubectl --context oke -n dinner exec db-1 -c postgres -- \
      pg_dump -d dinner_roulette --data-only --table=restaurants > restaurants.sql

    # after the next make oke-up
    kubectl --context oke -n dinner exec -i db-1 -c postgres -- \
      psql -d dinner_roulette -c 'TRUNCATE restaurants;'
    kubectl --context oke -n dinner exec -i db-1 -c postgres -- \
      psql -d dinner_roulette < restaurants.sql
    ```

    `TRUNCATE` removes the seed rows first, so the restored rows do not clash with them.

## When your IP address changes

Symptoms: `kubectl` hangs and fails with `dial tcp <endpoint>:6443: i/o timeout`, and `curl https://…` times out. Both NSG rules still allow only your old address.

```bash
make oke-cidr CIDR="$(curl -4 -s https://ifconfig.me)/32"
```

The target:

1. checks that `CIDR` is set and contains a `/`;
2. rewrites the `allowed_source_cidr` line in `tf/workshop.auto.tfvars`, so a later `oke-up` does not put the old value back;
3. runs `tofu apply`, which updates the two NSG rules in place in a few seconds.

`workshop.auto.tfvars` is git-ignored, because it describes your account. Nothing to commit. Running `make oke-tfvars` does the same thing from your current public address, without typing the CIDR.

## Scale and resize

**More app replicas.** `kubectl --context oke -n dinner scale deploy/app --replicas=2` works, since votes live in the database. The manifest says `replicas: 1`, though, so the next `make oke-deploy` goes back to one. Change `app.yaml` to make it permanent.

**More nodes.** Add `TF_VAR_node_count=2` to `.secrets.env` and run `make apply`. OKE adds a node to the pool.

**Bigger nodes.** Changing `node_shape`, `node_ocpus` or `node_memory_gbs` updates the node pool, but OKE applies node pool changes only to **new** nodes. Basic clusters do not support automatic node cycling, so existing nodes keep their old size until they are replaced. For this ephemeral stack, the simplest way is `make oke-down` followed by `make oke-up`.

**Kubernetes upgrades.** The same applies to `k8s_version`. OpenTofu upgrades the control plane and then the node pool definition, but existing nodes keep the old version until they are replaced. A fresh `oke-down` and `oke-up` with the new version is the easy path.

## Deploy from GitHub Actions

The repository has a manual `deploy` workflow. It applies `:latest`, because that is the tag the `Makefile` derives when nothing is pinned. Merging a release PR deploys the version tag instead, through the `release` workflow described above.

```yaml title=".github/workflows/deploy.yml"
--8<-- ".github/workflows/deploy.yml"
```

It writes a kubeconfig from the `KUBECONFIG_B64` secret and runs the same `make oke-deploy` as your laptop, with the registry values from repository variables and secrets instead of `.secrets.env`. For it to work, three conditions must hold.

**1. The kubeconfig must not need the OCI CLI.** The kubeconfig written by `oke-up` authenticates through `oci ce cluster generate-token`, and the runner has no OCI configuration. One way to get a self-contained kubeconfig is a ServiceAccount token:

```bash
eval "$(make oke-env)"

kubectl -n kube-system create serviceaccount github-deployer
kubectl create clusterrolebinding github-deployer \
  --clusterrole=cluster-admin --serviceaccount=kube-system:github-deployer

SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
TOKEN=$(kubectl -n kube-system create token github-deployer --duration=24h)

cat > /tmp/kubeconfig-ci <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: oke
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA}
users:
  - name: github-deployer
    user:
      token: ${TOKEN}
contexts:
  - name: oke
    context:
      cluster: oke
      user: github-deployer
current-context: oke
EOF

gh secret set KUBECONFIG_B64 --body "$(base64 -w0 < /tmp/kubeconfig-ci)"   # macOS: base64 < /tmp/kubeconfig-ci
rm /tmp/kubeconfig-ci
```

The context **must be called `oke`**, because every command in the `Makefile` uses `--context oke`. The token expires after the requested duration, or earlier if the API server enforces a shorter limit. Every `oke-up` creates a new cluster with a new endpoint and CA, so the secret must be regenerated after each one. `cluster-admin` is broad: the deploy needs cluster-wide rights only because it installs the CNPG operator and its CRDs. For anything beyond a workshop, give the account a narrower role.

**2. The runner must reach the API endpoint.** The `dinner-endpoint` NSG accepts port 6443 only from `allowed_source_cidr`. GitHub-hosted runners connect from addresses outside it, so the job times out when it contacts the cluster. Use a [self-hosted runner](https://docs.github.com/en/actions/hosting-your-own-runners) on a machine inside `allowed_source_cidr`, or run `make oke-deploy` from your laptop instead.

**3. The repository variables and secrets must exist:** `OCIR_REGION`, `OCIR_NAMESPACE`, `OCIR_USERNAME`, `OCIR_AUTH_TOKEN` (see [step 4](image.md#configure-the-repository-on-github)) and `KUBECONFIG_B64`.

Then:

```bash
gh workflow run deploy --ref main
gh run watch
```

Next: [Step 7: Tear it down](teardown.md).
