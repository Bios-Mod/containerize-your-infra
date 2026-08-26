# Continuous Integration

**GitHub Actions · Per-module Docker workflows · containerize-your-infra**

---

## Introduction

This document covers the CI layer of the repository: automated validation
triggered on every push and pull request, implemented with GitHub Actions.

CI does not deploy anything. It validates Docker Compose files, the custom
Dockerfile, image references, and Docker/EC2 Terraform syntax before a human
merges changes to `main`.

CI complements the automation layer documented in
[`stacks/full-infra/docker/automation.md`](stacks/full-infra/docker/automation.md).
Terraform provisions the Docker/EC2 infrastructure layer; Docker Compose runs
services; GitHub Actions verifies the repository artefacts that define both.

---

## Runtime scope

CI currently validates the Docker runtime only.

Docker workflows validate Compose configuration, Docker image builds, image
references, and Docker/EC2 Terraform syntax. Kubernetes validation will be
added incrementally when Helm charts and EKS Terraform exist and have a
functional implementation to validate.

Kubernetes CI will not replace Docker CI. Each runtime will keep independent
path filters and validation jobs so that Docker changes do not trigger Helm
validation, and Kubernetes changes do not trigger Compose builds.

---

## Design decisions

**Per-module Docker workflows, not a monolithic pipeline.** Each Docker module
triggers its own workflow using a runtime-specific `paths` filter. A change to
`modules/dns/docker/**` runs the DNS Docker workflow; it does not trigger
file-transfer, reverse-proxy, web-server, or future Kubernetes checks. This
avoids unnecessary compute and keeps CI responsibility scoped to the runtime
and module that changed, the same way each module is independently deployable
in this repository.

**`paths` is an event-level gate, not a job conditional.** GitHub evaluates the
`paths` filter against the diff of a push or pull request before deciding
whether to run the workflow at all. If there is no match, the workflow does not
start — it is not skipped, it never triggers. This is different from an `if:`
condition inside a job, which runs after the workflow has already started.

**Official-image modules validate configuration, not builds.**
`file-transfer`, `dns`, and `reverse-proxy` use published images — there is no
Dockerfile in those modules to build. Their workflows run `docker compose
config` for syntax and variable resolution, and `docker compose pull` to
confirm that image references are valid. This is appropriate for the current
lab scope; a production pipeline could add integration tests against running
containers.

**`web-server` builds its custom image.** This is the only module with a
Dockerfile, justified as a portfolio decision in `decisions-log.md`. Its
workflow runs an actual Docker build because a broken Dockerfile is a failure
mode that Compose configuration validation alone cannot detect.

**`full-infra.yml` validates the integrated Docker runtime.** The workflow has
two independent jobs: full-stack Docker Compose validation and Docker/EC2
Terraform validation. It triggers on changes under
`stacks/full-infra/docker/**`, any `modules/**/docker/**` path, or its own
workflow file.

- **Compose job:** validates `docker compose config` against the full stack and
  runs `docker compose build` in the stack integration context. The
  web-server Dockerfile is already validated in isolation by `web-server.yml`,
  but build behaviour can differ when it is invoked through the full-stack
  Compose file. Re-running the build here confirms that the integrated Docker
  stack remains valid.
- **Terraform job:** runs `terraform fmt -check`, `terraform init
  -backend=false`, and `terraform validate` against
  `stacks/full-infra/docker/automation/terraform/`. These checks validate
  formatting, provider/module initialization without a remote backend, and
  internal Terraform configuration syntax. They do not create, modify, or
  inspect AWS resources.

**`terraform plan` is explicitly excluded from CI.** Running `plan` requires
AWS credentials and may require access to the configured state backend. That
would add secrets and cloud access to CI for a check that is not required to
validate the Terraform configuration itself. `terraform plan` remains a manual
step before `apply`, as documented in `automation.md`. This follows the same
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
├── web-server.yml       # Builds the custom Docker image
├── file-transfer.yml    # Validates Docker Compose configuration and image references
├── dns.yml              # Validates Docker Compose configuration and image references
├── reverse-proxy.yml    # Validates Docker Compose configuration and image references
├── full-infra.yml       # Validates integrated Compose and Docker/EC2 Terraform
└── pull-request.yml     # Detects affected Docker paths and publishes a PR summary
```

Each module workflow triggers on pushes to its corresponding
`modules/<name>/docker/**` path, its module README, or its own workflow file.

`full-infra.yml` triggers on Docker stack paths, Docker artefacts from modules,
or changes to its workflow definition.

`pull-request.yml` triggers on pull requests targeting `main`. It detects the
Docker module and stack paths affected by the diff and runs only the
corresponding technical validation jobs.

---

## Actions used

| Action | Used in | Purpose |
|---|---|---|
| `actions/checkout@v7` | All workflows | Checks out the repository into the runner |
| `docker/setup-buildx-action@v4` | `web-server.yml`, `full-infra.yml`, `pull-request.yml` | Enables BuildKit for Docker image builds |
| `docker/build-push-action@v7` | `web-server.yml`, `pull-request.yml` | Builds the custom web-server image with `push: false` |
| `hashicorp/setup-terraform@v4` | `full-infra.yml` | Installs Terraform for format and validation checks |

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

**Full-stack Docker validation is path-scoped in pull requests.** The
`validate-full-infra` job runs when a pull request changes
`stacks/full-infra/docker/**`, any `modules/**/docker/**` path, or
`.github/workflows/full-infra.yml`. Documentation-only changes do not build the
full Docker stack. Module-specific checks run only when their corresponding
Docker runtime paths, module README, or workflow definition change.

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
| `dorny/paths-filter@v4` | Detects which Docker module and stack paths changed in the pull request |
| `docker/setup-buildx-action@v4` | Enables BuildKit for the web-server build job |
| `docker/build-push-action@v7` | Builds the custom web-server image with `push: false` |
| `actions/github-script@v9` | Writes the per-module validation summary into the pull request |

Each `validate-*` job depends on `detect-changes` and runs only when its
corresponding path filter matches the pull request diff. The full-stack Docker
job is also path-scoped and runs when Docker stack or module Docker artefacts
change.