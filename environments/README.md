# Environments

This directory contains environment-specific Compose configurations for the lab.

Each module ships its own `docker-compose.yml` for development and a
`docker-compose.prod.yml` for production. The files in this directory
aggregate all modules into a single deployable unit per environment.

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
- **prod** → [`prod/setup.md`](prod/setup.md) · [`prod/docker-compose.prod.yml`](prod/docker-compose.prod.yml)