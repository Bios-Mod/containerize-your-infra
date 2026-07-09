# Continuous Integration

**GitHub Actions · Per-module workflows · containerize-your-infra**

---

## Introduction

This document covers the CI layer of the repository: automated validation
triggered on every push and pull request, implemented with GitHub Actions.
CI does not deploy anything — it validates that Docker Compose files, the
custom Dockerfile, and the Terraform plan are all correct before a human
merges to `main`.

CI complements the automation layer documented in
[`stacks/full-infra/automation.md`](stacks/full-infra/automation.md).
Terraform provisions infrastructure; Docker Compose runs services; GitHub
Actions verifies that both are correct on every change.

---

## Design decisions

**Per-module workflows, not a monolithic pipeline.** Each module in
`modules/` triggers its own workflow using a `paths` filter. A change to
`modules/dns/**` only runs the DNS workflow — it does not trigger file-transfer,
reverse-proxy, or web-server checks. This avoids unnecessary compute and keeps
CI responsibility scoped to the module that changed, the same way each module
is independently deployable in this repo.

**`paths` is an event-level gate, not a job conditional.** GitHub evaluates the
`paths` filter against the diff of a push or PR before deciding whether to run
the workflow at all. If there is no match, the workflow does not start — it is
not skipped, it never triggers. This is different from an `if:` condition
inside a job, which runs after the workflow has already started.

**Official-image modules validate config, not build.** `file-transfer`, `dns`,
and `reverse-proxy` use official images — there is nothing to build. Their
workflows run `docker compose config` (syntax and variable resolution) and
`docker compose pull` (confirms the image reference is valid). This is
appropriate for a lab; a production pipeline would add integration tests
against a running container.

**`web-server` builds its custom image.** This is the only module with a
Dockerfile (see `decisions-log.md` — portfolio decision). Its workflow runs an
actual `docker build`, because a broken Dockerfile is a real failure mode that
config validation alone would not catch.

**`full-infra.yml` is one workflow with multiple jobs, not multiple files.**
The full stack has two independent things to validate — the Compose layer and
the Terraform layer — but they belong to the same stack and the same trigger
scope (`stacks/full-infra/**`). Splitting them into separate files would be
fragmentation without benefit. Both jobs run in the same workflow.

- **Compose job:** validates `docker compose config` against the full stack
  and re-runs `docker compose build` in the stack's own context. This is
  deliberate: web-server's Dockerfile is already validated in isolation by
  `web-server.yml`, but build behavior can differ when invoked from a
  different working directory or build context. Re-running it here confirms
  the build succeeds in the actual context the stack uses.
- **Terraform job:** runs `terraform fmt -check` and `terraform validate`
  against `stacks/full-infra/automation/terraform/`. Both commands require no
  AWS credentials and no state access — they check formatting and internal
  syntax only.

**`terraform plan` is explicitly excluded from CI.** Running `plan` requires
AWS credentials as a GitHub Secret, which raises the exposure surface of the
repository for a check that is not required to validate correctness of the
`.tf` files themselves. `plan` remains a manual step, run locally before
`apply`, as documented in `automation.md`. This mirrors the same discipline
already applied to `terraform.tfvars` — no credentials committed, no
credentials in CI, unless explicitly justified.

**No Docker Hub authentication by default.** GitHub-hosted runners can hit
Docker Hub's anonymous pull rate limit since runner IPs are shared across 
many concurrent jobs. This repo does not pre-configure
a `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` secret pair. If workflows start
failing with `429 Too Many Requests`, authentication is added reactively —
not as a preventive default that manages a secret with no proven need.

---

## Workflow structure

```bash
.github/workflows/
├── web-server.yml       # build custom image
├── file-transfer.yml    # compose config validation
├── dns.yml               # compose config validation
├── reverse-proxy.yml    # compose config validation
├── full-infra.yml        # compose build + terraform fmt/validate (2 jobs)
└── pull-request.yml      # multi-module diff validation + PR summary (6 jobs)
```

Each module workflow triggers on push to its own `modules/<name>/**` path.
`full-infra.yml` triggers on push to `stacks/full-infra/**`. `pull-request.yml`
triggers on `pull_request` events targeting `main`, and validates only the
modules affected by the diff — plus the full stack unconditionally.

---

## Actions used

| Action | Used in | Purpose |
|---|---|---|
| `actions/checkout@v4` | all workflows | clones the repo into the runner |
| `docker/setup-buildx-action@v3` | `web-server.yml`, `full-infra.yml` (compose job) | enables BuildKit for `docker build` |
| `docker/build-push-action@v6` | `web-server.yml` | runs the build, `push: false` |

No Terraform-specific action is required — `terraform fmt` and
`terraform validate` run directly via the CLI, installed with
`hashicorp/setup-terraform@v3` if the runner does not ship it by default.

---

## Design decisions — Pull Request workflow

**A dedicated `pull-request.yml`, not reused module workflows.** A PR can touch
several modules at once — the module workflows are scoped to a single path and
would require duplicating trigger logic across five files to cover that case
correctly. A single PR-scoped workflow detects every changed path in one diff
and runs the relevant checks conditionally, which the per-module workflows are
not designed to do.

**Diff detection with `dorny/paths-filter@v3`, not shell scripting.** GitHub
Actions has no native way to expose "which paths changed in this diff" as a
reusable output between steps. `paths-filter` solves this cleanly: it outputs
a boolean per defined path pattern, consumed by `if:` conditions on later
steps. Without it, the same logic would require manual `git diff` parsing —
more code, more failure surface, for less clarity.

**Full-stack validation always runs, module checks are conditional.** Any PR
merged to `main` eventually affects the full stack, so `full-infra` validation
is not gated behind a path match — it always runs on every PR. Module-specific
checks (`compose config`, or `docker build` for web-server) only run for the
modules actually touched in the diff, avoiding redundant checks on unrelated
modules.

**Results are surfaced directly in the PR, not only in the Actions tab.** A
per-module pass/fail summary is written into the PR via `github-script`. This
is deliberate for portfolio visibility: a reviewer opening the PR sees the
validation breakdown without navigating to a separate tab — the same UX a
recruiter or teammate would expect from a mature CI setup.

---

## Actions used — Pull Request workflow

| Action | Purpose |
|---|---|
| `actions/checkout@v4` | clones the repo in every job that needs the diff or the code |
| `dorny/paths-filter@v3` | detects which module paths changed in the PR diff |
| `docker/setup-buildx-action@v3` | enables BuildKit for the web-server build job |
| `actions/github-script@v7` | writes the per-module validation summary into the PR |

Each `validate-*` job depends on `detect-changes` and runs only if its
corresponding path changed, except `validate-full-infra`, which always runs
regardless of which modules were touched.

---