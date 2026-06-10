# Environments

This lab runs across two environments. Both deploy the same modules —
`dev` for local iteration, `prod` for deployment on a real server.

---

## Overview

| Environment | Infrastructure | When to use |
|---|---|---|
| `dev` | macOS · OrbStack | Local iteration — develop and test each module before prod deployment |
| `prod` | Ubuntu 24.04 LTS · EC2 t4g.micro / local VM | Server deployment — same modules, production-grade configuration |

`dev` and `prod` run the same services. The difference is operational:
bind mounts vs named volumes, relaxed vs enforced restart policies,
debug ports vs minimal exposure.

`prod` setup and override files are applied at the close of Phase 1,
once all modules are running in `dev`.

---

## Setup guides

| Environment | Guide |
|---|---|
| `dev` | [`dev/setup.md`](dev/setup.md) |
| `prod` | [`prod/setup.md`](prod/setup.md) |

Complete the `dev` setup guide before applying any module.
`prod/setup.md` is a prerequisite for production deployments — applied after all modules are running in `dev`.