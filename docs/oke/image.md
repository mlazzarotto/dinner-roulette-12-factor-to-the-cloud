# Step 4: Publish the image to OCIR

At the end of this step, the app image is in your tenancy's private registry, at the path in `OCIR_IMAGE`, for the CPU architecture of your node.

**Time:** 5 to 10 minutes.

## Why a registry

On minikube the image was copied straight into the node. An OKE node is a VM in Oracle's cloud: it can only **pull** images from a registry. OCIR (Oracle Cloud Infrastructure Registry) is Oracle's registry. It sits next to the cluster, it is reached through the Service Gateway, and the repository is private by default.

Do this step before the first `make oke-up`. Otherwise the app pod stays in `ImagePullBackOff` with `Repository Name Unknown`, as described in [Troubleshooting](../troubleshooting.md#imagepullbackoff-on-the-app-pod).

There are two ways to publish the image.

## Option A: the GitHub Actions `build` workflow

This is the recommended way: it builds for **both** architectures, so the same image runs on A1 (arm64) and E-series (amd64) nodes.

```yaml title=".github/workflows/build.yml"
--8<-- ".github/workflows/build.yml"
```

What it does:

1. installs the dependencies with `npm ci`, runs the tests and compiles, so a broken commit never produces an image;
2. sets up QEMU and Buildx, which let an amd64 runner build arm64 images through emulation;
3. logs in to OCIR with the repository secrets;
4. builds for `linux/amd64` and `linux/arm64` and pushes two tags: the full commit SHA and `latest`.

### Configure the repository on GitHub

The workflow reads two repository **variables** and two **secrets**:

| Name | Kind | Value |
|---|---|---|
| `OCIR_REGION` | variable | Region identifier, e.g. `eu-milan-1` |
| `OCIR_NAMESPACE` | variable | Your tenancy's Object Storage namespace |
| `OCIR_USERNAME` | secret | `<tenancy-namespace>/<username>` |
| `OCIR_AUTH_TOKEN` | secret | The auth token from step 1.5 |

Set them in **Settings → Secrets and variables → Actions**, or with the GitHub CLI from the repository folder:

```bash
gh variable set OCIR_REGION    --body eu-milan-1
gh variable set OCIR_NAMESPACE --body <tenancy-namespace>
gh secret   set OCIR_USERNAME  --body '<tenancy-namespace>/<username>'
gh secret   set OCIR_AUTH_TOKEN          # prompts for the value, so it stays out of your shell history
```

!!! note "Who can set them"
    Repository secrets and variables can be managed by the owner of a personal repository, or by admins of an organization repository. With write access only, ask the owner.

`OCIR_NAMESPACE` must be **your** namespace. If it points to another tenancy, the build succeeds but pushes the image somewhere your cluster never looks.

### Run it

The workflow runs on every push to `main`. To start it by hand:

```bash
gh workflow run build --ref main
gh run watch                        # follow the run live
```

Or on GitHub: **Actions → build → Run workflow**, branch `main`. The workflow file and the code used are the ones on `main`, not your local changes.

## Option B: from your machine with `make oke-push`

```bash
cd infra
make oke-push
```

The target runs three commands:

```bash
printf '%s' "$OCIR_AUTH_TOKEN" | docker login "<registry host from OCIR_IMAGE>" -u "$OCIR_USERNAME" --password-stdin
docker build --build-arg COMMIT_SHA="$(git -C .. rev-parse --short=7 HEAD)" -t "$OCIR_IMAGE" ..
docker push "$OCIR_IMAGE"
```

The token is passed on standard input, so it never appears in the process list or in your shell history. The short commit SHA is baked in, so `GET /version` reports it.

!!! warning "Single architecture"
    `docker build` produces an image for **your machine's** architecture. That is fine when they match: an amd64 laptop with an E-series node, or an Apple Silicon Mac with an A1 node. When they differ, log in first (as in [step 1.6](oci-account.md#16-work-out-your-registry-host-and-username)), then build for the node's platform from the repository root:

    ```bash
    docker buildx build --platform linux/arm64 \
      --build-arg COMMIT_SHA="$(git rev-parse --short=7 HEAD)" \
      -t eu-milan-1.ocir.io/<tenancy-namespace>/dinner-roulette:latest --push .
    ```

    For the same multi-architecture image as CI, use `--platform linux/amd64,linux/arm64`, after creating a builder that supports it once: `docker buildx create --use --name multiarch`. On Linux, building for another architecture also needs the QEMU emulators, installed once with `docker run --privileged --rm tonistiigi/binfmt --install all`. Docker Desktop has them built in.

## Check the result

In the Console: **Developer Services → Containers & Artifacts → Container Registry**, in the right region. The first push creates a **private** repository named `dinner-roulette` in the root compartment.

From the terminal, after `docker login`:

```bash
docker buildx imagetools inspect eu-milan-1.ocir.io/<tenancy-namespace>/dinner-roulette:latest
```

```text
Name:      eu-milan-1.ocir.io/<tenancy-namespace>/dinner-roulette:latest
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:…

Manifests:
  Name:      …@sha256:…
  Platform:  linux/amd64

  Name:      …@sha256:…
  Platform:  linux/arm64
```

An image pushed by `make oke-push` shows a single platform.

## Make sure the architecture matches

| Node shape | The image must contain |
|---|---|
| `VM.Standard.A1.Flex` | `linux/arm64` |
| `VM.Standard.E3.Flex`, `E4.Flex`, `E5.Flex` | `linux/amd64` |

With the wrong architecture, the pod either fails to pull (`no match for platform in manifest`) or starts and crashes immediately with `exec format error`.

## How the cluster pulls the image

You do not have to do anything here: `make oke-deploy` takes care of it. It runs `make registry-secret`, which creates a `docker-registry` Secret named `ocir` in the `dinner` namespace. The server is taken from `OCIR_IMAGE`, and the username and token from `.secrets.env`:

```bash
kubectl --context oke -n dinner create secret docker-registry ocir \
  --docker-server="eu-milan-1.ocir.io" \
  --docker-username="$OCIR_USERNAME" \
  --docker-password="$OCIR_AUTH_TOKEN" \
  --dry-run=client -o yaml | kubectl --context oke apply -f -
```

The Deployment lists `ocir` under `imagePullSecrets`, and kubelet uses it for every pull. Because the server comes from `OCIR_IMAGE` itself, the Secret cannot point at a different registry than the image.

Next: [Step 5: Bring it up](provision.md).
