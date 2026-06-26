# Contributing to containerize-your-infra

This lab is designed as a modular, community-usable reference for Docker deployments.
Contributions that improve clarity, correctness, or coverage are welcome.

---

## How to contribute

**Reporting issues**
Open a GitHub Issue describing:

- Which module, environment, or config file is affected
- What the current behaviour is and what you expected
- Your deployment context (`dev` or `prod`) and architecture (ARM64 or x86_64)

**Suggesting improvements**
Open a GitHub Issue before submitting a PR for significant changes — a brief
discussion avoids duplicated effort and keeps the lab coherent.

**Submitting a pull request**

1. Fork the repository and create a branch from `main`
2. Keep changes focused — one fix or addition per PR
3. Follow the existing conventions:
   - Config files in `modules/<module>/configs/` include a standard header block:
     ```
     # Deploy to:   <target path inside the container or on the host>
     # Apply:       <docker compose up / docker build / cp>
     # Module:      <module name>
     # Requires:    <prior module if applicable> / none
     #
     # Parameters modified from baseline:  <param → new value> / none
     # <one-line description>
   - Doc sections follow the `What was done / Why / Verification` structure
     ```
   - Commands are copy-pasteable and tested
4. If adding a new service module, open an Issue first to align on scope
   - Inline comments explain *why*, not just *what*

---

## What is in scope

- Corrections to existing steps (commands, paths, parameter values)
- Clarifications to existing documentation
- Additional verification commands for existing steps
- Architecture-specific notes (ARM64 / x86_64 differences)
- Alternative image choices with documented tradeoffs

## What is out of scope

- New service modules without prior Issue alignment
- Automation content under `automation/` (Phase 3 — not yet open)
- GUI-based or non-CLI approaches
- Kubernetes or Docker Swarm content (separate scope)

---

## Code of conduct

Be direct and technical. Criticism of the work is welcome; criticism of the person is not.