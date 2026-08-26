# Environments

This directory contains environment-specific setup documentation for the Docker
and Kubernetes implementations of the lab.

Each runtime keeps its own environment procedures. Docker is the current
functional implementation for local development and EC2 production. Kubernetes
procedures will be added when the EKS implementation is introduced.

---

## Runtime structure

| Runtime | dev | prod | Status |
|---|---|---|---|
| Docker | [`docker/dev/setup.md`](docker/dev/setup.md) | [`docker/prod/setup.md`](docker/prod/setup.md) | Implemented |
| Kubernetes | Planned | Planned | Not implemented |

---

## Docker environment matrix

| Parameter | dev | prod |
|---|---|---|
| Config mounts | Bind mounts | Bind mounts (read-only) |
| Data volumes | Bind mounts | Named volumes |
| Restart policy | `"no"` | `unless-stopped` |
| Healthchecks | None | Defined per service |
| Debug ports | Exposed | Not exposed |
| TLS | Self-signed | Let's Encrypt (Traefik ACME) |

The Docker implementation includes a standalone development Compose file and a
standalone production Compose file per module. The full-stack production Compose
that aggregates all modules into one deployable unit lives in
[`stacks/full-infra/docker/`](../stacks/full-infra/docker/full-infra-docker.md).
