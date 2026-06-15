# Full Infrastructure Stack — containerize-your-infra

**Docker Engine · web-server · file-transfer · dns · reverse-proxy**

---

## Introduction

This document covers the deployment of all four lab modules as a unified stack
from a single `docker compose` command. Each module retains its own
`docker-compose.prod.yml` for standalone deployment — this stack is the
integration layer that connects them.

All services share a single bridge network (`infra-net`). Traefik is the sole
HTTP/S ingress: it terminates TLS and routes traffic to the web server by
label. DNS runs with a fixed IP on the same network so any container can
resolve `lab.local` names by pointing its resolver to `172.20.0.10`.
File transfer is exposed directly on port `2222` — it has no HTTP frontend
and does not go through Traefik.

> **Config files stay in each module's `configs/` directory.** This compose
> references them with relative paths (`../../modules/*/configs/`). No
> duplication — a change to a module's config is reflected in the stack
> on the next `docker compose up`.

> **Prerequisites:** each module must have been deployed and verified
> individually before running this stack. The configs, host keys, and TLS
> certificates must already exist in their respective `modules/*/configs/`
> directories.

---

## Stack topology

| Service | Image | Ports (host) | Network role |
|---|---|---|---|
| `traefik` | `traefik:v3.7` | `80`, `443` | HTTP/S ingress, TLS termination |
| `web-server` | `nginxinc/nginx-unprivileged:stable-alpine` | none | Backend, internal only |
| `file-transfer` | `lscr.io/linuxserver/openssh-server:latest` | `2222` | SFTP, direct access |
| `dns` | `ubuntu/bind9:latest` | `53 TCP/UDP` | Resolver + authoritative zone |

**Network:** `infra-net` — `172.20.0.0/24`
**DNS fixed IP:** `172.20.0.10`

---

## Before You Start

Confirm that each module's configs are in place:

```bash
# TLS certificates (required by Traefik at startup)
ls modules/reverse-proxy/configs/traefik/certs/
# → lab.crt  lab.key

# SSH host keys (required by file-transfer at startup)
ls modules/file-transfer/configs/ssh/
# → ssh_host_ed25519_key  ssh_host_rsa_key

# BIND9 zone files
ls modules/dns/configs/bind/
# → named.conf  named.conf.options  named.conf.local  db.lab.local  db.172.20.0

# Nginx config and HTML
ls modules/web-server/configs/nginx/ modules/web-server/configs/html/
# → nginx.conf
# → index.html
```

> **EC2 Ubuntu 24.04 — port 53 conflict:** `systemd-resolved` occupies port 53
> on the host by default. Free it before deploying:
>
> ```bash
> sudo mkdir -p /etc/systemd/resolved.conf.d/
> sudo tee /etc/systemd/resolved.conf.d/no-stub.conf << 'EOF'
> [Resolve]
> DNSStubListener=no
> EOF
> sudo systemctl restart systemd-resolved
> ```

---

## Step 1 — Deploy the Full Stack

### What was done

The full stack is deployed from `stacks/full-infra/` using the unified
`docker-compose.prod.yml`. All four services start on the shared `infra-net`
network. Named volumes for persistent data (`file-transfer-data`, `dns-cache`)
are created automatically on first run.

```bash
cd stacks/full-infra
docker compose -f docker-compose.prod.yml up -d
```

📄 [`docker-compose.prod.yml`](docker-compose.prod.yml)

### Why

Running the stack from a single compose file gives Docker a complete picture
of all service dependencies, networks, and volumes in one operation. Docker
creates the `infra-net` network and both named volumes before starting any
container — there is no manual pre-provisioning step.

The config files stay in `modules/*/configs/` and are referenced with relative
paths. This avoids duplication: a module's config is the single source of
truth regardless of whether the module is deployed standalone or as part of
this stack.

DNS gets a fixed IP (`172.20.0.10`) because it is the resolver for the
network. Every other service is assigned a dynamic IP from the `infra-net`
pool — they do not need stable addresses because they are reached by name
or through Traefik's label-based routing.

### Verification

```bash
# All four containers are running
docker compose -f docker-compose.prod.yml ps
# → NAME            STATUS
# → traefik         Up X seconds (healthy)
# → web-server      Up X seconds (healthy)
# → file-transfer   Up X seconds (healthy)
# → dns             Up X seconds (healthy)

# All containers are on infra-net
docker network inspect infra-net --format '{{ range .Containers }}{{ .Name }} {{ .IPv4Address }}{{ "\n" }}{{ end }}'
# → traefik         172.20.0.X/24
# → web-server      172.20.0.X/24
# → file-transfer   172.20.0.X/24
# → dns             172.20.0.10/24

# Named volumes were created
docker volume ls | grep -E "file-transfer-data|dns-cache"
# → local   dns-cache
# → local   file-transfer-data
```

---

## Step 2 — Service Verification

### What was done

Each service is verified end-to-end from the host. This step confirms that
the stack is not just running but functional: Traefik is routing, DNS is
resolving, file transfer is accepting connections.

No new config or deploy action — verification only.

### Why

Individual module verification confirmed each service in isolation. This step
confirms they work together: Traefik discovers `web-server` on `infra-net`,
DNS resolves names across the shared network, and file transfer is reachable
on its dedicated port. A passing stack is not four healthy containers — it is
four healthy containers that interact correctly.

### Verification

```bash
# ── Traefik ──────────────────────────────────────────────────────────────

# Dashboard responds with auth challenge
curl -sk -o /dev/null -w "%{http_code}\n" --resolve traefik.localhost:443:127.0.0.1 https://traefik.localhost/dashboard/
# → 401

# ── Web Server ────────────────────────────────────────────────────────────

# HTTPS request proxied through Traefik to Nginx
curl -sk -o /dev/null -w "%{http_code}\n" --resolve web.localhost:443:127.0.0.1 https://web.localhost
# → 200

# HTTP redirects to HTTPS
curl -s -o /dev/null -w "%{http_code}\n" --resolve web.localhost:80:127.0.0.1 http://web.localhost
# → 301

# ── DNS ───────────────────────────────────────────────────────────────────

# Authoritative zone responds
dig @127.0.0.1 dns.lab.local +short
# → 172.20.0.10

# External resolution through forwarders
dig @127.0.0.1 google.com +short
# → (external IP)

# ── File Transfer ─────────────────────────────────────────────────────────

# SFTP port is open
ssh -p 2222 -o StrictHostKeyChecking=no labuser@127.0.0.1 -i modules/file-transfer/configs/keys/labuser_ed25519 exit
# → (connection closes cleanly — exit code 0)
```

---

## Step 3 — Resilience Test

### What was done

Full lifecycle test of the stack: bring it down and back up from a cold start.
Validates that named volumes survive, all healthchecks pass, and the restart
policy keeps services running after a Docker daemon restart.

### Why

In build-your-infra the equivalent was rebooting the VM and confirming that
all services came back via systemd. Here the unit of restart is the Compose
stack and the Docker daemon. Named volumes ensure that uploaded files and DNS
cache survive a full `docker compose down` / `up` cycle — they are not
deleted unless `down -v` is explicitly passed.

### Verification

```bash
# Bring the stack down (preserves named volumes)
docker compose -f docker-compose.prod.yml down

# Confirm volumes survived
docker volume ls | grep -E "file-transfer-data|dns-cache"
# → local   dns-cache
# → local   file-transfer-data

# Bring the stack back up
docker compose -f docker-compose.prod.yml up -d

# All services healthy after cold start
docker compose -f docker-compose.prod.yml ps
# → traefik         Up X seconds (healthy)
# → web-server      Up X seconds (healthy)
# → file-transfer   Up X seconds (healthy)
# → dns             Up X seconds (healthy)

# Restart policy survives daemon restart
sudo systemctl restart docker
sleep 5
docker ps --format "table {{.Names}}\t{{.Status}}"
# → traefik         Up X seconds
# → web-server      Up X seconds
# → file-transfer   Up X seconds
# → dns             Up X seconds
```