# Environments

This directory contains environment-specific setup documentation for the lab.

Each module ships its own `docker-compose.yml` for development and a
`docker-compose.prod.yml` for standalone production deployment. The full-stack
production compose that aggregates all modules into a single deployable unit
lives in [`stacks/full-infra/`](../stacks/full-infra/README.md).

---

## Environment matrix

| Parameter | dev | prod |
|---|---|---|
| Config mounts | Bind mounts | Bind mounts (read-only) |
| Data volumes | Bind mounts | Named volumes |
| Restart policy | `"no"` | `unless-stopped` |
| Healthchecks | None | Defined per service |
| Debug ports | Exposed | Not exposed |
| TLS | Self-signed | Let's Encrypt (Traefik ACME) |

---

- **dev** → [`dev/setup.md`](dev/setup.md)
- **prod** → [`prod/setup.md`](prod/setup.md)