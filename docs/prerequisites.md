# Prerequisites

You need a handful of command-line tools. minikube needs only the first four; OKE needs all of them plus three accounts.

## Tools

| Tool | Needed for | Tested with | Why |
|---|---|---|---|
| Docker | both | 28.5 | Builds the image, and is the minikube driver |
| kubectl | both | 1.34 | Talks to the clusters, renders Kustomize overlays |
| minikube | minikube | 1.39 | The local cluster |
| Helm | both | 4.3 (3.x works too) | Installs CloudNativePG, cert-manager, ingress-nginx |
| GNU make | both | 4.x | Runs the targets in `infra/Makefile` |
| Terraform | OKE | 1.14 (1.12 or newer is required) | Creates the network, cluster and node pool |
| OCI CLI | OKE | 3.95 | Authenticates Terraform's provider, writes the kubeconfig, and issues the tokens `kubectl` uses on OKE |
| curl, dig | both | any | Smoke tests and DNS checks |
| gh (GitHub CLI) | optional | 2.82 | Sets CI secrets and triggers workflows |
| Node.js 22 | optional | 22 | Runs the tests locally and in the pre-commit hook |
| trufflehog | optional | any | Secret scan in the pre-commit hook |

!!! note "Hardware for minikube"
    `make mk-up` starts minikube with **2 CPUs and 4 GB of RAM**. Leave at least that much free, plus about 20 GB of disk for images. On macOS and Windows, Docker Desktop has its own memory limit. Raise it in Docker Desktop's settings if minikube refuses to start.

## Install

=== "Linux (Debian/Ubuntu)"

    ```bash
    # Docker Engine, then let your user talk to it without sudo (log out and back in afterwards)
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"

    # kubectl
    curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl

    # minikube
    curl -LO https://github.com/kubernetes/minikube/releases/latest/download/minikube-linux-amd64
    sudo install minikube-linux-amd64 /usr/local/bin/minikube && rm minikube-linux-amd64

    # Helm (see https://helm.sh/docs/intro/install/ for other methods)
    sudo snap install helm --classic

    # make, curl, dig
    sudo apt-get install -y make curl dnsutils

    # Terraform, from HashiCorp's apt repository
    wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
      | sudo tee /etc/apt/sources.list.d/hashicorp.list
    sudo apt-get update && sudo apt-get install -y terraform

    # OCI CLI (interactive installer, accept the defaults)
    bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
    ```

    On an ARM machine, replace `amd64` with `arm64` in the kubectl and minikube URLs.

=== "macOS (Homebrew)"

    ```bash
    brew install --cask docker          # Docker Desktop; start it once from Applications
    brew install kubectl minikube helm make
    brew tap hashicorp/tap && brew install hashicorp/tap/terraform
    brew install oci-cli
    ```

    macOS ships an old GNU make 3.81. The `Makefile` uses nothing exotic and should work with it. If you hit odd parsing errors, `brew install make` gives you a current version as `gmake`.

??? tip "OpenTofu instead of Terraform"
    The Terraform code is plain HCL and has no Terraform-only features. The `Makefile` calls the `terraform` binary through a single variable, so you can override it without editing files, for example `make TF="tofu -chdir=tf" plan`. This path has not been tested end to end with this repository, so expect to sort out the provider download yourself on the first `tofu init`.

## Check the installation

```bash
docker version --format 'Docker {{.Server.Version}}'   # fails if the daemon is not running
minikube version --short
kubectl version --client
helm version --short
make --version | head -1
terraform version | head -1
oci --version
```

Each command should print a version. If `docker version` prints the client but fails on the server, the Docker daemon is not running, or your user is not in the `docker` group yet (log out and back in after `usermod`).

## Accounts (OKE only)

| Account | What for | Cost |
|---|---|---|
| [Oracle Cloud](https://www.oracle.com/cloud/free/) | The cluster, the registry, the load balancer | Free tier available, see [costs](oke/index.md#what-it-costs) |
| [Cloudflare](https://dash.cloudflare.com/sign-up) | DNS for your domain, and the API that cert-manager uses for DNS-01 | Free plan is enough |
| A domain name | The public hostname and its certificate | Depends on the registrar and the TLD |
| GitHub (optional) | The `build` workflow that pushes multi-arch images to OCIR | Free |

[Step 1](oke/oci-account.md) and [step 2](oke/dns-tls.md) of the OKE section walk through every setting in these accounts.

## Get the code

```bash
git clone https://github.com/mlazzarotto/dinner-roulette-12-factor-to-the-cloud.git
cd dinner-roulette-12-factor-to-the-cloud

# Optional but recommended: blocks commits of secrets and Terraform state, and runs the tests
git config core.hooksPath .githooks
```

The pre-commit hook refuses to commit `.secrets.env`, `.env`, `*.tfstate` and `kubeconfig` files, even with `git add -f`. If `trufflehog` is installed, it also scans the staged files for credentials. Then it runs `npm test`, so run `npm ci` once if you want commits to pass.
