# Run it on minikube

This page runs the whole stack on your machine: a one-node Kubernetes cluster, the CloudNativePG operator, a PostgreSQL instance, the app and an ingress controller. No cloud account and no secrets are needed.

**Time:** about 15 minutes, most of it spent downloading images the first time.
**You need:** Docker, kubectl, minikube, Helm and make, as described in [Prerequisites](prerequisites.md).

The whole flow is three commands:

```bash
cd infra
make mk-up        # start minikube, enable the ingress addon, build and load the image
make mk-deploy    # install the Postgres operator, create the DB and deploy the app
make mk-smoke     # call GET /suggestion through the ingress
```

The rest of this page explains what each command does, how to check it, and what to do next.

## Step 1: Start the cluster and build the image

```bash
cd infra
make mk-up
```

`mk-up` runs four commands in sequence.

### 1a. `minikube start --cpus=2 --memory=4g`

minikube creates a Kubernetes cluster made of a single node. With the Docker driver, which minikube picks automatically when Docker is installed, that node is a Docker container running a full Kubernetes control plane, kubelet and a container runtime. minikube then:

- writes a context called `minikube` into `~/.kube/config` and makes it the current context;
- installs the default storage class `standard`, which creates volumes on the node's disk.

!!! note "CPU and memory only count the first time"
    `--cpus` and `--memory` are applied when the cluster is **created**. If a `minikube` profile already exists with other values, minikube starts it as it is and prints a warning. To change them, run `minikube delete` first. That removes the cluster and everything in it.

If minikube picks a driver you do not want, force it: `minikube start --driver=docker --cpus=2 --memory=4g`, or set it permanently with `minikube config set driver docker`.

### 1b. `minikube addons enable ingress`

This deploys the ingress-nginx controller into the `ingress-nginx` namespace and registers the `nginx` IngressClass that the app's Ingress asks for. On OKE the same controller is installed with Helm instead.

### 1c. `docker build -t dinner-roulette:local .`

Run from the repository root, this builds the app image with your local Docker:

```dockerfile title="Dockerfile"
--8<-- "Dockerfile"
```

The **build stage** installs all dependencies, **runs the test suite**, and compiles TypeScript to `dist/`. A failing test therefore fails the build, and no broken image is ever produced. The **runtime stage** starts again from a clean `node:slim`, installs only the production dependencies (`npm ci --omit=dev`) and copies the compiled `dist/`. Compilers and test tools never reach the runtime image.

!!! info "`/version` is empty on minikube"
    `mk-up` does not pass the `COMMIT_SHA` build argument, so `GET /version` returns `{"commit":""}`. CI and `make oke-push` pass the short commit SHA. To get it locally too, build with `--build-arg COMMIT_SHA="$(git rev-parse --short=7 HEAD)"`.

### 1d. `minikube image load dinner-roulette:local`

minikube's node has its own container runtime, separate from your laptop's Docker. This command copies the image from your Docker into the node. Because the image is already there, the minikube overlay sets `imagePullPolicy: Never`: kubelet uses the local copy and never tries to reach a registry.

### Check step 1

```bash
kubectl --context minikube get nodes
kubectl --context minikube -n ingress-nginx get pods
minikube image ls | grep dinner-roulette
```

You should see something like:

```text
NAME       STATUS   ROLES           AGE   VERSION
minikube   Ready    control-plane   2m    v1.3x.x

NAME                                        READY   STATUS      RESTARTS   AGE
ingress-nginx-admission-create-xxxxx        0/1     Completed   0          90s
ingress-nginx-admission-patch-xxxxx         0/1     Completed   0          90s
ingress-nginx-controller-xxxxxxxxxx-xxxxx   1/1     Running     0          90s

docker.io/library/dinner-roulette:local
```

## Step 2: Deploy the database and the app

```bash
make mk-deploy
```

`mk-deploy` runs five steps. Every one of them can be re-run safely.

### 2a. Create the namespace

```bash
kubectl --context minikube create namespace dinner --dry-run=client -o yaml | kubectl --context minikube apply -f -
```

The namespace has to exist before the ConfigMap in step 2c can be created inside it. The [create-then-apply pattern](concepts.md#the-idempotent-create-then-apply-pattern) makes this a no-op when it already exists.

### 2b. Install the CloudNativePG operator (`make cnpg CONTEXT=minikube`)

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update cnpg
helm upgrade --install cnpg cnpg/cloudnative-pg --version 0.29.1 \
  --namespace cnpg-system --create-namespace --kube-context minikube --wait
```

This installs the `Cluster` CRD and the operator's controller into `cnpg-system`. `--wait` returns only when the operator is running, so the next steps never apply a `Cluster` before its type exists.

### 2c. Create the `db-init` ConfigMap (`make db-init CONTEXT=minikube`)

```bash
kubectl --context minikube -n dinner create configmap db-init \
  --from-file=init.sql=../db/init.sql --dry-run=client -o yaml | kubectl --context minikube apply -f -
```

The `Cluster` in `db.yaml` refers to this ConfigMap and runs `init.sql` once, right after the database is created. See [the database](concepts.md#the-database-a-cloudnativepg-cluster) for the details.

### 2d. Apply the minikube overlay

```bash
kubectl kustomize k8s/overlays/minikube | kubectl --context minikube apply -f -
```

This renders the base plus the minikube changes (local image, no pull secret, HTTP ingress) and sends the result to the cluster. Kubernetes now starts working in parallel:

1. The CNPG operator sees the new `Cluster db`, creates the PVC `db-1`, and runs a `db-1-initdb` pod that creates the database and runs `init.sql`.
2. The operator starts the PostgreSQL pod `db-1`, creates the Services `db-rw`, `db-ro` and `db-r`, and writes the Secret `db-app`.
3. The `app` pod starts its init container `wait-for-db`, which loops until `db-rw` accepts connections.
4. The `app` container starts with `DATABASE_URL` taken from `db-app`, and becomes Ready once port 8080 answers.

### 2e. Wait for the rollout

```bash
kubectl --context minikube -n dinner rollout status deploy/app --timeout=300s
```

This blocks until the new app pod is Ready, or fails after five minutes. The first run takes longer because the PostgreSQL images are downloaded.

### Check step 2

Watch the pods appear in a second terminal while `mk-deploy` runs:

```bash
kubectl --context minikube -n dinner get pods -w
```

The sequence looks like this:

```text
NAME                READY   STATUS            RESTARTS   AGE
db-1-initdb-xxxxx   0/1     Init:0/1          0          5s
app-xxxxxxxxx-xxx   0/1     Init:0/1          0          5s
db-1-initdb-xxxxx   0/1     Completed         0          40s
db-1                1/1     Running           0          55s
app-xxxxxxxxx-xxx   0/1     PodInitializing   0          60s
app-xxxxxxxxx-xxx   1/1     Running           0          65s
```

Then check the database and everything else in the namespace:

```bash
kubectl --context minikube -n dinner get cluster db
make mk-status
```

```text
NAME   AGE   INSTANCES   READY   STATUS                     PRIMARY
db     2m    1           1       Cluster in healthy state   db-1
```

`make mk-status` lists the pods, Services, the Ingress and the PVC of the `dinner` namespace, with node and IP columns.

## Step 3: Smoke test

```bash
make mk-smoke
```

Expected output, with a random restaurant because nobody has voted yet:

```json
{"restaurant":{"id":"napoli","name":"Pizzeria Napoli","category":"pizza","votes":0},"votes":0}
```

What the target does:

1. starts `kubectl port-forward svc/ingress-nginx-controller 18080:80` in the background, which opens port 18080 on your laptop and tunnels it to the ingress controller;
2. waits three seconds, then runs `curl -H 'Host: dinner.local' http://127.0.0.1:18080/suggestion`;
3. kills the port-forward and exits with curl's exit code.

The `Host` header matters. The ingress controller picks the route by host name, and the Ingress only has a rule for `dinner.local`. Without the header, nginx answers `404 Not Found`.

The port-forward exists because the minikube node's IP (`minikube ip`) is not reachable from the host with the Docker driver on macOS. A port-forward works the same way on every OS.

??? tip "Other ways to reach the app"
    **Linux, Docker driver.** The node IP is routable from the host, and the ingress addon listens on the node's ports 80 and 443:

    ```bash
    curl -H 'Host: dinner.local' "http://$(minikube ip)/suggestion"

    # or map the name once and use it like a real site
    echo "$(minikube ip) dinner.local" | sudo tee -a /etc/hosts
    curl http://dinner.local/suggestion
    ```

    **macOS, Docker driver.** Run `minikube tunnel` in a separate terminal (it asks for your password), add `127.0.0.1 dinner.local` to `/etc/hosts`, then `curl http://dinner.local/suggestion`.

    **Skip the ingress entirely.** Port-forward straight to the app's Service:

    ```bash
    kubectl --context minikube -n dinner port-forward svc/app 8080:80
    curl http://127.0.0.1:8080/suggestion
    ```

## Step 4: Use the API

Open a port-forward in one terminal and leave it running:

```bash
kubectl --context minikube -n ingress-nginx port-forward svc/ingress-nginx-controller 18080:80
```

In a second terminal:

```bash
BASE=http://127.0.0.1:18080
H='Host: dinner.local'

# Vote twice for sakura and once for napoli
curl -s -H "$H" -H 'Content-Type: application/json' -d '{"user":"alice","restaurantId":"sakura"}' "$BASE/votes"; echo
curl -s -H "$H" -H 'Content-Type: application/json' -d '{"user":"bob","restaurantId":"sakura"}'   "$BASE/votes"; echo
curl -s -H "$H" -H 'Content-Type: application/json' -d '{"user":"carol","restaurantId":"napoli"}' "$BASE/votes"; echo

# sakura now wins every time
curl -s -H "$H" "$BASE/suggestion"; echo

# Validation: unknown restaurant gives 404, missing fields give 400
curl -s -o /dev/null -w '%{http_code}\n' -H "$H" -H 'Content-Type: application/json' -d '{"user":"dave","restaurantId":"kebab"}' "$BASE/votes"
curl -s -o /dev/null -w '%{http_code}\n' -H "$H" -H 'Content-Type: application/json' -d '{}' "$BASE/votes"
```

```text
{"user":"alice","restaurantId":"sakura"}
{"user":"bob","restaurantId":"sakura"}
{"user":"carol","restaurantId":"napoli"}
{"restaurant":{"id":"sakura","name":"Sakura","category":"japanese","votes":2},"votes":2}
404
400
```

## Step 5: Prove that the pod is disposable

Votes live in PostgreSQL, not in the app's memory (12-Factor **VI. Processes**). Kill the app pod and check that nothing is lost:

```bash
kubectl --context minikube -n dinner delete pod -l app=app
kubectl --context minikube -n dinner rollout status deploy/app
curl -s -H "$H" "$BASE/suggestion"; echo     # still sakura with 2 votes
```

The Deployment notices that it has zero pods instead of one and starts a replacement. The replacement connects to the same database and sees the same votes.

!!! note
    The port-forward from step 4 keeps working, because it points at the ingress controller, not at the app. A port-forward to `svc/app` would break: `kubectl port-forward` picks one pod behind the Service when it starts and stays attached to it.

## Step 6: Look inside the database

Run `psql` inside the PostgreSQL pod. The container user is the database superuser, so no password is needed:

```bash
kubectl --context minikube -n dinner exec -it db-1 -c postgres -- \
  psql -d dinner_roulette -c 'SELECT id, name, votes FROM restaurants ORDER BY votes DESC;'
```

```text
    id     |        name        | votes
-----------+--------------------+-------
 sakura    | Sakura             |     2
 napoli    | Pizzeria Napoli    |     1
 trattoria | Trattoria da Mario |     0
```

The app connects as the `dinner` user, with the random password that CNPG generated:

```bash
# The password
kubectl --context minikube -n dinner get secret db-app -o jsonpath='{.data.password}' | base64 -d; echo

# The full connection string the app receives as DATABASE_URL
kubectl --context minikube -n dinner get secret db-app -o jsonpath='{.data.uri}' | base64 -d; echo
```

To use a local client such as `psql`, DBeaver or pgAdmin, forward the primary's Service:

```bash
kubectl --context minikube -n dinner port-forward svc/db-rw 5432:5432
# in another terminal
PGPASSWORD="$(kubectl --context minikube -n dinner get secret db-app -o jsonpath='{.data.password}' | base64 -d)" \
  psql -h 127.0.0.1 -U dinner -d dinner_roulette
```

## Step 7: Change the code and redeploy

After editing `src/`, rebuild the image, load it again and restart the pod:

```bash
cd ..
docker build -t dinner-roulette:local .
minikube image load dinner-roulette:local     # overwrites the old image with the same tag
cd infra
kubectl --context minikube -n dinner rollout restart deploy/app
kubectl --context minikube -n dinner rollout status deploy/app
```

`kubectl apply` would not restart anything here: the manifest did not change, it still says `dinner-roulette:local`. `rollout restart` adds a timestamp annotation to the pod template, and that change makes the Deployment roll out a new pod, which picks up the new image.

??? tip "Build directly inside minikube"
    `minikube image build -t dinner-roulette:local ..` (from `infra/`) builds the image inside the minikube node, which saves the load step. Running `make mk-up` again also works: it starts the existing cluster, rebuilds and reloads the image.

## Step 8: Work with plain kubectl

Typing `--context minikube -n dinner` gets old. To make minikube the current context in your shell:

```bash
eval "$(make mk-env)"
kubectl -n dinner get pods
kubectl config set-context --current --namespace=dinner   # optional: make dinner the default namespace
```

`mk-env` prints an `export KUBECONFIG=…` line, which merges your `~/.kube/config` with `infra/kubeconfig`, and a `kubectl config use-context minikube` line. `eval` runs both in the current shell. The change lasts until you close the terminal.

## Step 9: Clean up

Pick how far you want to go:

| Command | What it removes | What stays |
|---|---|---|
| `make mk-down` | The `dinner` namespace: app, database, PVC, Secrets, ConfigMap | The cluster, the CNPG operator, the ingress addon, the loaded image |
| `minikube stop` | Nothing, it stops the node | Everything, ready for `minikube start` |
| `minikube delete` | The whole cluster | Nothing |

After `make mk-down`, run `make mk-deploy` again to get a fresh, empty database. That is also how you apply a change to `db/init.sql`, since it runs only when the database is created.

To remove the operator as well: `helm --kube-context minikube -n cnpg-system uninstall cnpg`.

## Without make

??? example "The same flow, command by command"
    Run from `infra/`. These are the exact commands the targets execute.

    ```bash
    # mk-up
    minikube start --cpus=2 --memory=4g
    minikube addons enable ingress
    (cd .. && docker build -t dinner-roulette:local .)
    minikube image load dinner-roulette:local

    # mk-deploy
    kubectl --context minikube create namespace dinner --dry-run=client -o yaml | kubectl --context minikube apply -f -

    helm repo add cnpg https://cloudnative-pg.github.io/charts
    helm repo update cnpg
    helm upgrade --install cnpg cnpg/cloudnative-pg --version 0.29.1 \
      --namespace cnpg-system --create-namespace --kube-context minikube --wait

    kubectl --context minikube -n dinner create configmap db-init \
      --from-file=init.sql=../db/init.sql --dry-run=client -o yaml | kubectl --context minikube apply -f -

    kubectl kustomize k8s/overlays/minikube | kubectl --context minikube apply -f -
    kubectl --context minikube -n dinner rollout status deploy/app --timeout=300s

    # mk-smoke
    kubectl --context minikube -n ingress-nginx port-forward svc/ingress-nginx-controller 18080:80 &
    sleep 3
    curl -sf -H 'Host: dinner.local' http://127.0.0.1:18080/suggestion; echo
    kill %1

    # mk-down
    kubectl --context minikube delete namespace dinner --ignore-not-found
    ```

## Next

When everything here works, you know every moving part of the deployment. [OKE](oke/index.md) runs the same manifests on Oracle Cloud, adding a private registry, a load balancer, a domain and TLS.
