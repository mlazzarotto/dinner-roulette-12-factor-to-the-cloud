# Dinner Roulette: From Code to Cloud (Native)

[![build](https://github.com/mlazzarotto/dinner-roulette-12-factor-to-the-cloud/actions/workflows/build.yml/badge.svg)](https://github.com/mlazzarotto/dinner-roulette-12-factor-to-the-cloud/actions/workflows/build.yml)

Dinner Roulette is a small TypeScript API that suggests where to have dinner, based on votes: the app built in a [12-factor](https://12factor.net/) coding dojo. This repository answers the next question: where does such an app run?

The same app deploys unchanged in three places: plain Docker on your laptop, Kubernetes on minikube, and managed Kubernetes on Oracle Cloud (OKE).

Every step is explained in the [step-by-step guide](https://mlazzarotto.github.io/dinner-roulette-12-factor-to-the-cloud/). This README is the overview.

## The workshop

<img align="right" width="160" src="https://raw.githubusercontent.com/cncf/artwork/master/other/cncf/horizontal/color/cncf-color.svg" alt="Cloud Native Trento is a CNCF community group">

This repository is the support material for **Cloud Native Trento #7: From Code to Cloud (Native)**, a hands-on workshop organized with [XPUG Trento](https://luma.com/xpugtn).

- **When and where:** November 5, 2026, 18:45, at OpenMove, Via per Marco 12/E, Mori (Trentino). [Event page](https://ocgroups.dev/cncf/group/cloud-native-trento/event/2wwzk8e)
- **Speakers:** [Alessandro Peretti](https://www.linkedin.com/in/alessandro-peretti/) and [Marco Lazzarotto](https://www.linkedin.com/in/marco-lazzarotto/)
- **Part I of the series:** [Coding Dojo: 12-factor App](https://luma.com/mng6wf99), where the app was built

Part I took a real application and applied the 12 factors to it: configuration in the environment, explicit dependencies, no state in the process, a database behind a URL. Part II takes the result to the cloud: deploying to Kubernetes, mapping the build, release and run stages onto manifests, ConfigMaps and Secrets, managing image versions, and moving the app from commit to cluster with GitHub Actions.

> [!IMPORTANT]
> Coming to the workshop? Prepare your laptop before the session:
>
> 1. Install **Docker**, **kubectl**, **minikube**, **Helm** and **GNU make**. Add **OpenTofu** and the **OCI CLI** only if you want to repeat the cloud part on your own Oracle account.
> 2. Check that each tool answers: `docker version`, `kubectl version --client`, `minikube version --short`, `helm version --short`.
> 3. Clone this repository.
> 4. Optional sanity check: run `docker compose up --build`, then `curl http://localhost:8080/suggestion`.
>
> Install commands for Linux and macOS are in the [prerequisites](https://mlazzarotto.github.io/dinner-roulette-12-factor-to-the-cloud/prerequisites/) page of the guide.

## The app

This is the app as it came out of Part I:

- configuration comes from the environment (`DATABASE_URL`), never from the code;
- restaurants and votes live in PostgreSQL, so the process keeps no state;
- dependencies are declared and locked, and the Docker image is a clean multi-stage build.

| Endpoint | What it does |
|---|---|
| `POST /votes` | Adds a vote. Body: `{"user": "alice", "restaurantId": "sakura"}` |
| `GET /suggestion` | Returns the most voted restaurant, picked at random on ties |
| `GET /health` | Always answers `{"status": "ok"}` |
| `GET /version` | Returns the commit SHA baked into the image at build time |

The server listens on port 8080. The database is created and seeded by [`db/init.sql`](db/init.sql) with three restaurants: sakura, napoli and trattoria.

## What is in the repo

```text
.
├── src/, test/              # the API and its tests
├── db/init.sql              # schema and seed data, run once when the database is created
├── Dockerfile               # multi-stage build: tests and tsc, then a slim runtime image
├── docker-compose.yml       # the plain Docker environment
├── .githooks/pre-commit     # blocks secrets and OpenTofu state, runs the tests
├── .github/workflows/       # build, deploy, pages
├── docs/                    # the step-by-step guide (MkDocs Material)
└── infra/
    ├── Makefile             # every command used in the guide
    ├── .secrets.example     # template for infra/.secrets.env, git-ignored
    ├── tf/                  # OpenTofu: VCN, OKE cluster, node pool
    └── k8s/
        ├── base/            # namespace, app Deployment and Service, CNPG Cluster
        └── overlays/        # minikube and OKE variations of the base
```

The entry points in `infra/Makefile`:

| Target | What it does |
|---|---|
| `mk-up`, `mk-deploy`, `mk-smoke` | Start minikube, deploy the stack, hit `/suggestion` |
| `mk-status`, `mk-env`, `mk-down` | Inspect the namespace, export the kubeconfig context, delete the workloads |
| `oke-up` | OpenTofu, kubeconfig, cert-manager, ingress-nginx, deploy. About 20 minutes from nothing |
| `oke-deploy` | Manifests only: namespace, pull secret, database, app |
| `oke-push` | Build the image and push it to the Oracle registry |
| `oke-status`, `oke-env`, `oke-smoke` | Inspect, export the context, hit the public URL |
| `oke-cidr CIDR=1.2.3.4/32` | Update the allowed source IP and apply |
| `oke-down` | Delete the workloads, then destroy the cluster |
| `init`, `plan`, `apply` | OpenTofu only, useful after a partial `oke-up` |

Run `make` inside `infra/` for the full list with one-line descriptions.

## The guide

The [step-by-step guide](https://mlazzarotto.github.io/dinner-roulette-12-factor-to-the-cloud/) is the main artifact of this repository. Every command can be copy-pasted, every step explains what happens behind the scenes, and the troubleshooting page lists errors that were hit for real while this setup was built.

- [Concepts](https://mlazzarotto.github.io/dinner-roulette-12-factor-to-the-cloud/concepts/): the Kubernetes objects, Kustomize, Helm, the operators, and where the 12 factors show up
- [Prerequisites](https://mlazzarotto.github.io/dinner-roulette-12-factor-to-the-cloud/prerequisites/): the tools to install and the accounts you need
- [minikube](https://mlazzarotto.github.io/dinner-roulette-12-factor-to-the-cloud/minikube/): the whole stack on your machine
- [OKE in seven steps](https://mlazzarotto.github.io/dinner-roulette-12-factor-to-the-cloud/oke/): from an empty Oracle account to HTTPS on your domain
- [Troubleshooting](https://mlazzarotto.github.io/dinner-roulette-12-factor-to-the-cloud/troubleshooting/): real errors with causes and fixes
- [Reference](https://mlazzarotto.github.io/dinner-roulette-12-factor-to-the-cloud/reference/): make targets, variables, pinned versions and a cheat sheet

## License and credits

Apache 2.0, see [LICENSE](LICENSE).

The workshop is organized by [Cloud Native Trento](https://www.linkedin.com/company/cloud-native-trento/), a CNCF community group, together with [XPUG Trento](https://luma.com/xpugtn).
