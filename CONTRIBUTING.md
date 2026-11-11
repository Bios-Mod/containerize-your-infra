# Contributing to containerize-your-infra

This lab is designed as a modular, community-usable reference for Docker and Kubernetes deployments.
Contributions that improve clarity, correctness, or coverage are welcome.

---

## How to contribute

**Reporting issues**
Open a GitHub Issue describing:

- Which module, environment, stack, workflow, or config file is affected
- What the current behaviour is and what you expected
- Your deployment context (`docker/dev`, `docker/prod`, `kubernetes/dev`, or `kubernetes/prod`) and architecture (ARM64 or x86_64)

**Suggesting improvements**
Open a GitHub Issue before submitting a PR for significant changes — a brief
discussion avoids duplicated effort and keeps the lab coherent.

**Submitting a pull request**

1. Fork the repository and create a branch from `main`
2. Keep changes focused — one fix or addition per PR
3. Follow the existing conventions:
   - Config, Compose, Helm, and Terraform files include a standard header block:
     ```text
     # Deploy to:   <target environment, path, or platform>
     # Apply:       <docker compose up / docker build / helm install / terraform apply / cp>
     # Module:      <module name>
     # Requires:    <prior module or prerequisite if applicable> / none
     #
     # <one-line description>
     # Parameters modified from baseline:  <param → new value> / none
     ```
   - Doc sections follow the `What was done / Why / Verification` structure
   - Commands are copy-pasteable and tested
   - Inline comments explain *why*, not just *what*
4. If adding a new service module, open an Issue first to align on scope

Pull requests targeting `main` run the [`pull-request.yml`](.github/workflows/pull-request.yml) CI workflow and post a per-module validation summary on the PR.

---

## What is in scope

- Corrections to existing steps (commands, paths, parameter values)
- Clarifications to existing documentation
- Additional verification commands for existing steps
- Architecture-specific notes (ARM64 / x86_64 differences)
- Alternative image choices with documented tradeoffs
- Corrections to Docker Compose, Helm, Terraform, CI, and documentation paths or references

## What is out of scope

- New service modules without prior Issue alignment
- New automation tools or implementations without prior Issue alignment
- GUI-based or non-CLI approaches

---

## Code of conduct

Be direct and technical. Criticism of the work is welcome; criticism of the person is not.