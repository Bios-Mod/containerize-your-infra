# Environments

This directory contains environment-specific setup documentation for the Docker
and Kubernetes implementations of the lab.

Each runtime keeps its own environment procedures. Docker covers local
development and EC2 production, while Kubernetes covers logical `dev` and `prod`
environments on a shared Amazon EKS cluster.

---

## Runtime structure

| Runtime | dev | prod | Status |
|---|---|---|---|
| Docker | [`docker/dev/setup.md`](docker/dev/setup.md) | [`docker/prod/setup.md`](docker/prod/setup.md) | Implemented |
| Kubernetes | [`kubernetes/dev/setup.md`](kubernetes/dev/setup.md) | [`kubernetes/prod/setup.md`](kubernetes/prod/setup.md) | Implemented |

---

## Docker environment matrix

| Parameter | dev | prod |
|---|---|---|
| Config mounts | Bind mounts | Bind mounts (read-only) |
| Data volumes | Bind mounts | Named volumes |
| Restart policy | `"no"` | `unless-stopped` |
| Healthchecks | None | Defined per service |
| Debug ports | Exposed | Not exposed |
| TLS | Self-signed | Self-signed (generated per host) |

The Docker implementation includes a standalone development Compose file and a
standalone production Compose file per module. Full-stack deployments live in
[`stacks/full-infra/docker/`](../stacks/full-infra/docker/full-infra-docker.md)
for Docker Compose and
[`stacks/full-infra/kubernetes/`](../stacks/full-infra/kubernetes/full-infra-kubernetes.md)
for the Kubernetes Helm umbrella chart.
