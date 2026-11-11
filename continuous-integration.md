# Continuous Integration

**GitHub Actions · Docker and Kubernetes validation · containerize-your-infra**

---

## Introduction

This document covers the CI layer of the repository: automated validation
triggered on every push and pull request, implemented with GitHub Actions.

CI does not deploy anything. It validates Docker Compose files, the custom
Dockerfiles, image references, Helm charts and Terraform syntax for both
runtimes before a human merges changes to `main`.

CI complements the automation layer documented in
[`stacks/full-infra/docker/automation.md`](stacks/full-infra/docker/automation.md)
and [`stacks/full-infra/kubernetes/automation.md`](stacks/full-infra/kubernetes/automation.md).
Terraform provisions the infrastructure layer of each runtime; Docker Compose
and Helm run the services; GitHub Actions verifies the repository artefacts
that define all of them.

---

## Runtime scope

CI validates both runtimes.

Docker workflows validate Compose configuration, Docker image builds, image
references, and Docker/EC2 Terraform syntax.
The `dns` Kubernetes job also builds the module's custom image, because the official image is amd64-only, and checks that the zone serial renders as an integer.

Kubernetes workflows validate the Helm chart of each module (`web-server`,
`reverse-proxy`, `dns`, `monitoring`) and the `full-infra` umbrella chart, plus
the Terraform that provisions EKS and the ECR repositories. Each Helm job runs
`helm lint` and `helm template` against the chart's baseline, dev, and prod
values — no cluster access, no AWS credentials, same "no `terraform plan` in CI"
discipline applied to Helm and to the EKS Terraform.

Docker and Kubernetes validation live in the same per-module workflow file but
as independent jobs, each with its own `paths` filter scope within that
workflow's trigger. A Docker-only change does not run the Helm job and vice
versa — `paths:` still gates the whole workflow at the event level, but within
a triggered run, each job validates only its own runtime.

---

## Design decisions

**Per-module Docker workflows, not a monolithic pipeline.** Each Docker module
triggers its own workflow using a runtime-specific `paths` filter. A change to
`modules/dns/docker/**` runs the DNS Docker workflow; it does not trigger
file-transfer, reverse-proxy, web-server, or Kubernetes checks. This
avoids unnecessary compute and keeps CI responsibility scoped to the runtime
and module that changed, the same way each module is independently deployable
in this repository.

**`paths` is an event-level gate, not a job conditional.** GitHub evaluates the
`paths` filter against the diff of a push or pull request before deciding
whether to run the workflow at all. If there is no match, the workflow does not
start — it is not skipped, it never triggers. This is different from an `if:`
condition inside a job, which runs after the workflow has already started.

**Official-image runtimes validate configuration, not builds.**
`file-transfer`, `monitoring` (in both runtimes), and the Docker runtimes of
`dns` and `reverse-proxy`, use published images — there is no Dockerfile in
those runtimes to build. `file-transfer`, `dns`, and `reverse-proxy` run
`docker compose config` for syntax and variable resolution, and
`docker compose pull` to confirm that image references are valid. Using a
placeholder `GRAFANA_ADMIN_PASSWORD` environment variable, `monitoring`
(`docker-validate`) adds:

- **Containerised tool checks:** reads the Prometheus and Blackbox Exporter
  image tags dynamically from `docker-compose.prod.yml` (`docker compose config
  --format json` + `jq`) and runs `promtool check config` and
  `blackbox_exporter --config.check`, plus `python3 -m json.tool` on the Grafana
  dashboard.
- **Inline workflow checks (`yq` and `jq` directly on the runner):** four
  named steps that close cross-file gaps neither Compose nor single-binary
  checks catch:
  - `Validate monitoring YAML syntax` — parses `prometheus.yml`, `blackbox.yml`,
    and Grafana datasource/dashboard provisioning YAML files with `yq`, ensuring
    each provisioning directory contains at least one file so Grafana does not
    boot with silent empty provisioning.
  - `Verify Prometheus probe modules exist in Blackbox config` — confirms every
    `params.module` referenced in `prometheus.yml` exists under `.modules` in
    `blackbox.yml` (`promtool` validates Prometheus syntax alone and cannot
    catch probe module typos that would fail with HTTP `400` at scrape time).
  - `Validate Grafana dashboard metadata and datasource` — checks valid JSON,
    non-empty `uid` and `title` on `configs/grafana/dashboards/lab-overview.json`,
    and cross-checks referenced panel datasource UIDs against provisioned
    datasources (emitting a `::notice::` if none is referenced) to catch UID
    drift before deployment.
  - `Verify module bind mount sources exist` — confirms every bind-mount
    source under `configs/` in `docker-compose.prod.yml` exists on disk
    (`docker compose config` does not check host paths, so Docker would create
    empty directories at runtime).

In Kubernetes, `monitoring` (`helm-validate`) runs `helm lint` and
`helm template monitoring` for dev and prod, confirms the prod render includes all
three Deployments (`monitoring-prometheus`, `monitoring-blackbox`,
`monitoring-grafana`), extracts the rendered `prometheus.yml` and `blackbox.yml`
ConfigMaps with `yq`, and runs `promtool check config --syntax-only` (skipping
on-disk checks for the in-cluster `ServiceAccount` token path) and
`blackbox_exporter --config.check` using the image tags read from `values.yaml`.
It also validates `helm/monitoring/dashboards/lab-overview-k8s.json` with
`python3 -m json.tool`, checks its non-empty `uid`/`title`, and confirms the
rendered datasource `uid` is `prometheus` and covers every `datasource.uid`
referenced by the dashboard.

This is appropriate for the current lab scope; a production pipeline could add
integration tests against running containers.

**All CI logic lives inline in workflows, with no helper scripts.** Every
check runs directly inside workflow `run:` steps using preinstalled runner
tools (`yq`, `jq`, Docker, Helm, Terraform). Centralizing everything under
`.github/workflows/` matches the rest of the repository and avoids maintaining a
separate script directory, at the intentional trade-off of repeating the
monitoring check steps between the push and pull-request workflows.

**`web-server` builds its custom image.** This is the only Docker-runtime module
with a Dockerfile, justified as a portfolio decision in `decisions-log.md`. Its
workflow runs an actual Docker build because a broken Dockerfile is a failure
mode that Compose configuration validation alone cannot detect.

**`dns` builds a custom image in its Kubernetes job.** The official ISC image is
published for amd64 only and the EKS nodes are arm64, so the Kubernetes runtime
builds its own (`modules/dns/kubernetes/Dockerfile`), recorded as an exception in
`decisions-log.md`. The Docker runtime keeps the official image. As with
`web-server`, `helm template` cannot detect a broken Dockerfile, so the Helm job
builds the image before linting and rendering the chart.

**`full-infra.yml` validates the integrated stack in both runtimes.** The
workflow has four independent jobs. It triggers on changes under
`stacks/full-infra/docker/**`, `stacks/full-infra/kubernetes/**`, any
`modules/**/docker/**` or `modules/**/kubernetes/**` path, or its own workflow
file. A change in any covered path runs all four jobs; the checks are cheap and
need no cloud access.

- **Compose job:** validates `docker compose config` against the full stack
  (passing a placeholder `GRAFANA_ADMIN_PASSWORD` for required variable
  interpolation without an `.env` file on the runner), runs two inline
  cross-module consistency steps (locating the repo root via
  `$GITHUB_WORKSPACE`), and runs `docker compose build` in the stack
  integration context:
  - `Verify Prometheus target hosts match stack services` — parses
    `modules/monitoring/docker/configs/prometheus/prometheus.yml` and the
    rendered full-stack Compose JSON to confirm every non-`localhost` host in
    `static_configs[].targets` and non-empty `relabel_configs[].replacement`
    matches a Compose service name or `container_name`. Because the stack shares
    the module's Prometheus config, this catches stale container or service
    renames that isolated module checks cannot see.
  - `Verify stack bind mount sources exist` — inspects every bind-mount source
    under `modules/` in the rendered `docker-compose.prod.yml` and confirms the
    path exists on disk, exempting host-generated unversioned keys and
    certificates matching `*/configs/ssh/*`, `*/configs/keys/*`, and
    `*/traefik/certs*` (created during host setup rather than committed) so
    missing repository config files are caught before Docker silently creates
    empty directories.
  The web-server Dockerfile is already validated in isolation by
  `web-server.yml`, but build behaviour can differ when it is invoked through
  the full-stack Compose file. Re-running the build here confirms that the
  integrated Docker stack remains valid.
- **Terraform job:** copies `main.tf.example` to `main.tf` and
  `outputs.tf.example` to `outputs.tf` (both files are gitignored, so without
  this materialization step Terraform would validate only `variables.tf`),
  checks `user_data.sh` with `bash -n` and `shellcheck --severity=warning`, and
  runs `terraform fmt -check`, `terraform init -backend=false`, and
  `terraform validate` against
  `stacks/full-infra/docker/automation/terraform/`. These checks validate
  bootstrap shell syntax, formatting, provider/module initialization without a
  remote backend, and internal Terraform configuration syntax. They do not
  create, modify, or inspect AWS resources.
- **Helm job:** builds the dependencies bottom-up — the Traefik dependency of
  `reverse-proxy` first, then the umbrella chart, because the umbrella packages
  `reverse-proxy` as it is on disk — and runs `helm lint` and `helm template`
  for the dev and prod values. Image repositories are passed with `--set` and a
  placeholder, because the real URI depends on the AWS account and Helm does
  not resolve image references. The render fails if stale standalone module
  Service names (`web-server-web-server`, `dns-dns`, `reverse-proxy-traefik`)
  remain — the umbrella release is called `full-infra`, so an un-overridden
  module name would only fail at runtime — and confirms that both dev and prod
  renders include `full-infra-prometheus`, `full-infra-blackbox`, and
  `full-infra-grafana` Deployments.
- **Terraform Kubernetes job:** materializes existing ignored `.tf.example`
  files (`main.tf` and `outputs.tf` in `cluster/`, `outputs.tf` in `registry/`)
  using non-clobbering existence checks before running `terraform fmt -check`,
  `terraform init -backend=false`, and `terraform validate` against
  `automation/terraform/cluster/` (EKS platform) and
  `automation/terraform/registry/` (ECR repositories) as independent matrix
  entries, since they are separate states.

**`terraform plan` is explicitly excluded from CI.** Running `plan` requires
AWS credentials and may require access to the configured state backend. That
would add secrets and cloud access to CI for a check that is not required to
validate the Terraform configuration itself. `terraform plan` remains a manual
step before `apply`, as documented in each runtime's `automation.md`, for the
Docker/EC2 host and for the EKS and registry states alike. This follows the same
discipline applied to `terraform.tfvars`: no credentials committed and no
credentials exposed to CI unless explicitly justified.

**No Docker Hub authentication by default.** GitHub-hosted runners can hit
Docker Hub anonymous pull rate limits because runner IP addresses are shared
across many concurrent jobs. This repository does not pre-configure a
`DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` secret pair. If workflows begin to
fail with `429 Too Many Requests`, authentication can be added reactively — not
as a preventive default that manages a secret without a demonstrated need.

---

## Workflow structure

```text
.github/workflows/
├── web-server.yml       # docker-validate: builds the custom Docker image
│                         # helm-validate: lints and templates the Kubernetes chart
├── file-transfer.yml    # Validates Docker Compose configuration and image references
├── dns.yml              # docker-validate: Compose configuration and image references
│                         # helm-validate: builds the custom image, lints and templates the Kubernetes chart
├── reverse-proxy.yml    # docker-validate: Compose configuration and image references
│                         # helm-validate: resolves dependencies, lints and templates the Kubernetes chart
├── monitoring.yml       # docker-validate: Compose syntax, image pulls, promtool, blackbox, Grafana JSON and inline checks
│                         # helm-validate: chart lint/template, rendered ConfigMap checks and dashboard/datasource consistency
├── full-infra.yml       # compose + terraform: integrated Compose, inline stack cross-checks, and Docker/EC2 Terraform
│                         # helm + terraform-kubernetes: umbrella chart and EKS/registry Terraform
└── pull-request.yml     # Detects affected Docker, Helm and Terraform paths and publishes a PR summary
```

Each module workflow triggers on pushes to its corresponding
`modules/<name>/docker/**` path, its module README, or its own workflow file.
`web-server.yml`, `reverse-proxy.yml`, `dns.yml` and `monitoring.yml`
additionally trigger on their `modules/<name>/kubernetes/**` path, covering both
runtimes in one file with two independent jobs.

`full-infra.yml` triggers on the Docker and Kubernetes stack paths, the Docker
and Kubernetes artefacts of the modules, or changes to its workflow definition.

`pull-request.yml` triggers on pull requests targeting `main`. It detects the
Docker, Helm and Terraform paths affected by the diff and runs only the
corresponding technical validation jobs.

---

## Actions used

| Action | Used in | Purpose |
|---|---|---|
| `actions/checkout@v7` | All workflows | Checks out the repository into the runner |
| `docker/setup-buildx-action@v4` | `web-server.yml`, `dns.yml`, `full-infra.yml`, `pull-request.yml` | Enables BuildKit for Docker image builds |
| `docker/build-push-action@v7` | `web-server.yml`, `dns.yml`, `pull-request.yml` | Builds the custom web-server and dns images with `push: false` |
| `hashicorp/setup-terraform@v4` | `full-infra.yml`, `pull-request.yml` | Installs Terraform for format and validation checks of both runtimes |
| `azure/setup-helm@v5` | `web-server.yml`, `reverse-proxy.yml`, `dns.yml`, `monitoring.yml`, `full-infra.yml`, `pull-request.yml` | Installs Helm for chart lint and template validation |

---

## Design decisions — Pull Request workflow

**A dedicated `pull-request.yml`, not reused module workflows.** A pull request
can touch several modules at once. The push workflows are scoped to a single
module path and would require duplicated cross-module trigger logic to cover a
pull request correctly. A PR-scoped workflow detects every relevant changed path
in one diff and runs the corresponding checks conditionally.

**Diff detection with `dorny/paths-filter@v4`, not shell scripting.** GitHub
Actions does not natively expose reusable outputs for module path changes in a
pull request diff. `paths-filter` provides one boolean output per defined path
pattern, consumed by `if:` conditions in later jobs. Without it, the workflow
would need manual `git diff` parsing, which adds code and failure surface with
less clarity.

**PR validation uses independent path filters per runtime.** `detect-changes`
exposes `<module>-docker` and `<module>-helm` as separate outputs for
`web-server`, `reverse-proxy`, `dns` and `monitoring`, each scoped to its own
runtime path (`modules/<module>/docker/**` / `modules/<module>/kubernetes/**`).
A Docker-only change does not trigger the Helm job, and a Kubernetes-only
change does not trigger the Docker job — same compute-avoidance discipline
already applied to module workflows, extended per runtime instead of per module.
Both filters also match the module README and the workflow file itself, since a
change there can affect either runtime and neither job can be assumed
unaffected. `file-transfer` (Docker-only) exposes a single `file-transfer`
filter. `validate-monitoring-docker` mirrors `monitoring.yml`'s `docker-validate`
checks (without image pulls), and `validate-monitoring-helm` runs the same chart
lint, prod Deployment, rendered `promtool check config --syntax-only`,
`blackbox_exporter --config.check`, dashboard JSON, and datasource UID checks as
`monitoring.yml`'s `helm-validate` job.

**Full-stack validation is path-scoped per runtime in pull requests.** Four
jobs cover `full-infra`, each behind its own filter:

- `validate-full-infra` (Docker) runs when a pull request changes
  `stacks/full-infra/docker/**`, any `modules/**/docker/**` path, or
  `.github/workflows/full-infra.yml`, passing a placeholder
  `GRAFANA_ADMIN_PASSWORD` for Compose interpolation and running Compose config,
  the inline Prometheus target-host and bind-mount checks (preserving the
  `*/configs/ssh/*`, `*/configs/keys/*`, and `*/traefik/certs*` exemption), and
  Compose build.
- `validate-full-infra-terraform` (Docker host Terraform) runs when a pull
  request changes `stacks/full-infra/docker/automation/terraform/**` or
  `.github/workflows/full-infra.yml`; it copies `main.tf.example` and
  `outputs.tf.example` to `main.tf` and `outputs.tf`, checks `user_data.sh`
  with `bash -n` and `shellcheck --severity=warning`, and runs
  `terraform fmt -check`, `terraform init -backend=false`, and
  `terraform validate`.
- `validate-full-infra-helm` runs when it changes
  `stacks/full-infra/kubernetes/helm/**`, any `modules/**/kubernetes/helm/**`
  path, or the workflow file. It builds the chart dependencies bottom-up, lints
  and renders the umbrella for dev and prod, checks for stale module Service
  names (`web-server-web-server`, `dns-dns`, `reverse-proxy-traefik`), and
  confirms both renders include `full-infra-prometheus`, `full-infra-blackbox`,
  and `full-infra-grafana` Deployments, the same checks as the `helm` job of
  `full-infra.yml`.
- `validate-full-infra-terraform-kubernetes` runs when it changes
  `stacks/full-infra/kubernetes/automation/terraform/**` or the workflow file,
  materializing any existing ignored `.tf.example` files (`main.tf`,
  `outputs.tf`) before `terraform fmt -check`, `init -backend=false`, and
  `validate` with `cluster` and `registry` as independent matrix entries.

Documentation-only changes do not build or render anything. Module-specific
checks run only when their corresponding runtime paths, module README, or
workflow definition change.

**Results are surfaced directly in the pull request, not only in the Actions
tab.** A per-module pass/fail summary is written into the pull request via
`github-script`. This is deliberate for portfolio visibility: a reviewer
opening the pull request sees the validation breakdown without navigating to a
separate tab.

---

## Actions used — Pull Request workflow

| Action | Purpose |
|---|---|
| `actions/checkout@v7` | Checks out the repository in jobs that need source code or the diff |
| `dorny/paths-filter@v4` | Detects which module and stack paths changed in the pull request |
| `docker/setup-buildx-action@v4` | Enables BuildKit for the web-server and dns build jobs |
| `docker/build-push-action@v7` | Builds the custom web-server and dns images with `push: false` |
| `hashicorp/setup-terraform@v4` | Installs Terraform for the Docker/EC2, EKS, and registry format and validation checks |
| `azure/setup-helm@v5` | Installs Helm for the module chart and umbrella chart lint and template jobs |
| `actions/github-script@v9` | Writes the per-module validation summary into the pull request |