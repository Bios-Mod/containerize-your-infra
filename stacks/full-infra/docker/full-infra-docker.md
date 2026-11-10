# Full Infrastructure Stack — containerize-your-infra

**Docker Engine · web-server · file-transfer · dns · reverse-proxy · monitoring**

---

## Introduction

This document covers the deployment of all five lab modules as a unified stack
from a single `docker compose` command. Each module retains its own
`docker-compose.prod.yml` for standalone deployment — this stack is the
integration layer that connects them.

All services share a single bridge network (`proxy-net`). Traefik is the sole
HTTP/S ingress: it terminates TLS and routes traffic to `web-server` and
`grafana` by label. DNS runs with a fixed IP on the same network so any
container can resolve `lab.local` names by pointing its resolver to
`172.21.0.10`. File transfer is exposed directly on port `2222` — it has no
HTTP frontend and does not go through Traefik. Prometheus and the monitoring
exporters remain internal to `proxy-net` with no published host ports.

> **Config files stay in each module's `configs/` directory.** This compose
> references them with relative paths (`../../../modules/*/docker/configs/`). No
> duplication — a change to a module's config is reflected in the stack
> on the next `docker compose up`.

> **Prerequisites:** each module must have been deployed and verified
> individually before running this stack. The configs, host keys, and TLS
> certificates must already exist in their respective `modules/*/docker/configs/`
> directories.

---

## Stack topology

| Service | Image | Ports (host) | Network role |
|---|---|---|---|
| `traefik` | `traefik:v3.7` | `80`, `443` | HTTP/S ingress, TLS termination, `/metrics` (`:8080` internal) |
| `web-server` | Custom build (`web-server:local`) on `nginxinc/nginx-unprivileged` | none | Backend, internal only |
| `file-transfer` | `atmoz/sftp:alpine` | `2222` | SFTP, direct access |
| `dns` | `internetsystemsconsortium/bind9:9.20` | `53 TCP/UDP` | Resolver + authoritative zone |
| `node-exporter` | `prom/node-exporter:v1.12.1` | none | Host telemetry (`:9100`, internal only) |
| `cadvisor` | `ghcr.io/google/cadvisor:v0.60.6` | none | Container telemetry (`:8080`, internal only) |
| `prometheus` | `prom/prometheus:v3.16.0` | none | Scraper & TSDB (`:9090`, internal only) |
| `blackbox-exporter` | `prom/blackbox-exporter:v0.29.1` | none | Synthetic HTTPS & DNS probes (`:9115`, internal only) |
| `grafana` | `grafana/grafana:13.3.0` | none | Dashboards (`:3000`, Traefik HTTPS `grafana.localhost`) |

**Network:** `proxy-net` — `172.21.0.0/24`
**DNS fixed IP:** `172.21.0.10`

---

## Before You Start

Confirm that each module's configs are in place:

```bash
cd containerize-your-infra/

# TLS certificates (required by Traefik at startup)
ls modules/reverse-proxy/docker/configs/traefik/certs/
# → lab.crt  lab.key

# BasicAuth hash (required for dashboard access)
grep -c "users:" modules/reverse-proxy/docker/configs/traefik/dynamic.yml
# → 1  (confirms the basicAuth block exists)

# SSH host keys (required by file-transfer at startup)
ls modules/file-transfer/docker/configs/ssh/
# → ssh_host_ed25519_key  ssh_host_rsa_key

# SSH host keys — permissions must be 600 (sshd rejects keys readable by others)
# macOS/BSD:
stat -f "%OLp %N" modules/file-transfer/docker/configs/ssh/ssh_host_ed25519_key modules/file-transfer/docker/configs/ssh/ssh_host_rsa_key
# Linux (prod/EC2):
stat -c "%a %n" modules/file-transfer/docker/configs/ssh/ssh_host_ed25519_key modules/file-transfer/docker/configs/ssh/ssh_host_rsa_key
# → 600 modules/file-transfer/docker/configs/ssh/ssh_host_ed25519_key
# → 600 modules/file-transfer/docker/configs/ssh/ssh_host_rsa_key
```

> **SSH host key permissions:** the host keys must be owned by root and have
> permissions `600` before deploying. If they are `644`, `sshd` inside the
> container will ignore them, generate its own keys, and reject client
> connections silently.

> ```bash
> sudo chmod 600 modules/file-transfer/docker/configs/ssh/ssh_host_ed25519_key
> sudo chmod 600 modules/file-transfer/docker/configs/ssh/ssh_host_rsa_key
> ```

```bash
# BIND9 zone files
ls modules/dns/docker/configs/bind/
# → named.conf  named.conf.options  named.conf.local  db.lab.local  db.172.21.0

# Nginx config and HTML — required at build time (Dockerfile COPY), not runtime mount
ls modules/web-server/docker/configs/nginx/ modules/web-server/docker/configs/html/
# → nginx.conf
# → index.html

# Monitoring configs and Traefik Prometheus metrics endpoint
ls modules/monitoring/docker/configs/prometheus/ modules/monitoring/docker/configs/blackbox/ modules/monitoring/docker/configs/grafana/dashboards/
# → prometheus.yml
# → blackbox.yml
# → lab-overview.json

grep -c "prometheus:" modules/reverse-proxy/docker/configs/traefik/traefik.yml
# → 1
```

> **Traefik BasicAuth password:** the bcrypt hash in
> `modules/reverse-proxy/docker/configs/traefik/dynamic.yml` was generated during
> the reverse-proxy module. If you need to reset it:
> ```bash
> # On any host with apache2-utils installed (sudo apt-get install -y apache2-utils)
> htpasswd -nB admin
> # → admin:$2y$...  ← replace the existing line in dynamic.yml under basicAuth.users
> ```
> Traefik reloads the dynamic config without restart (`watch: true`).

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

The full stack is deployed from `stacks/full-infra/docker/` using the unified
`docker-compose.prod.yml`. All nine services start on the shared `proxy-net` network.
Named volumes for persistent data (`file-transfer-data`, `dns-cache`,
`prometheus-data`, `grafana-data`) are created automatically on first run.

Before running locally, copy `.env.example` to `.env` and set a strong
`GRAFANA_ADMIN_PASSWORD`. On EC2 hosts provisioned with Terraform, `user_data.sh`
generates `stacks/full-infra/docker/.env` automatically on first boot (`chmod 600`,
owned by `ubuntu`). Inspect it via SSH with
`cat ~/containerize-your-infra/stacks/full-infra/docker/.env` (or
`sudo cat stacks/full-infra/docker/.env` from `~/containerize-your-infra/` if created
with `root` ownership).

`web-server` is built from its `Dockerfile` on first `up` — Docker Compose
builds the image automatically if it doesn't exist locally, or you can force
a rebuild with `--build`.

> **`sudo docker` on Linux/EC2 hosts:** `user_data.sh` adds `ubuntu` to the
> `docker` group (`usermod -aG docker ubuntu`), taking effect on a new SSH
> session. Host commands below use `sudo docker ...` so they also work before
> re-logging in or on existing hosts (omit `sudo` on macOS or once the `docker`
> group is active).

```bash
cd stacks/full-infra/docker/
cp .env.example .env
# Edit .env → GRAFANA_ADMIN_PASSWORD=<strong-password>

sudo docker compose -f docker-compose.prod.yml up -d --build
```

📄 [`docker-compose.prod.yml`](docker-compose.prod.yml)
📄 [`.env.example`](.env.example)

### Why

Running the stack from a single compose file gives Docker a complete picture
of all service dependencies, networks, and volumes in one operation. Docker 
creates the `proxy-net` network and all four named volumes before starting any
container — there is no manual pre-provisioning step.

The config files stay in `modules/*/docker/configs/` and are referenced with relative
paths. This avoids duplication: a module's config is the single source of
truth regardless of whether the module is deployed standalone or as part of
this stack.

Keeping `.env` gitignored and validating `${GRAFANA_ADMIN_PASSWORD:?set GRAFANA_ADMIN_PASSWORD in .env}`
prevents Grafana from booting with a default credential while separating
runtime secrets from version control.

DNS gets a fixed IP (`172.21.0.10`) because it is the resolver for the
network. Every other service is assigned a dynamic IP from the `proxy-net`
pool — they do not need stable addresses because they are reached by name
or through Traefik's label-based routing.

The `TRAEFIK_PROVIDERS_DOCKER_NETWORK` environment variable overrides the
`network` setting of the Docker provider at runtime. This ensures Traefik
contacts backends through `proxy-net` regardless of what the static
`traefik.yml` specifies — necessary when the same `traefik.yml` is shared
between the standalone module and this full-stack compose.

`web-server`'s `build.context` points to `../../../modules/web-server/docker/` — the
Dockerfile and its `COPY` paths resolve relative to that directory, not to
`stacks/full-infra/docker/` where this compose file lives.

### Verification

```bash
# All nine containers are running
sudo docker compose -f docker-compose.prod.yml ps
# → NAME                STATUS
# → blackbox-exporter   Up X seconds (healthy)
# → cadvisor            Up X seconds (healthy)
# → dns                 Up X seconds (healthy)
# → file-transfer       Up X seconds (healthy)
# → grafana             Up X seconds (healthy)
# → node-exporter       Up X seconds (healthy)
# → prometheus          Up X seconds (healthy)
# → traefik             Up X seconds (healthy)
# → web-server          Up X seconds (healthy)

# All containers are on proxy-net
sudo docker network inspect proxy-net --format '{{ range .Containers }}{{ .Name }} {{ .IPv4Address }}{{ "\n" }}{{ end }}'
# → blackbox-exporter 172.21.0.X/24
# → cadvisor          172.21.0.X/24
# → dns               172.21.0.10/24
# → file-transfer     172.21.0.X/24
# → grafana           172.21.0.X/24
# → node-exporter     172.21.0.X/24
# → prometheus        172.21.0.X/24
# → traefik           172.21.0.X/24
# → web-server        172.21.0.X/24

# Named volumes were created
sudo docker volume ls | grep -E "file-transfer-data|dns-cache|prometheus-data|grafana-data"
# → local   dns-cache
# → local   file-transfer-data
# → local   grafana-data
# → local   prometheus-data
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
confirms they work together: Traefik discovers `web-server` and `grafana` on
`proxy-net`, DNS resolves names across the shared network, file transfer is
reachable on its dedicated port, and Prometheus scrapes all exporters and
synthetic probes. A passing stack is not nine healthy containers — it is nine
healthy containers that interact correctly.

### Verification

Wait ~15–20 seconds after startup so the first Prometheus scrape cycle completes.

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
# → 172.21.0.10

# External resolution through forwarders
dig @127.0.0.1 google.com +short
# → (external IP)

# ── File Transfer ─────────────────────────────────────────────────────────

# SFTP port is open (container listens on 2222, mapped to host 2222)
ssh -p 2222 -o StrictHostKeyChecking=no labuser@127.0.0.1 \
  -i ../../../modules/file-transfer/docker/configs/keys/labuser_ed25519 exit

# Warning: Permanently added '[127.0.0.1]:2222' (ED25519) to the list of known hosts.
# (connection closes cleanly — exit code 0)

# ── Monitoring ────────────────────────────────────────────────────────────

# All 6 Prometheus targets are up
sudo docker compose -f docker-compose.prod.yml exec -T prometheus wget -qO- http://localhost:9090/api/v1/targets \
  | python3 -c "import sys,json; [print(t['labels']['job'], t['health']) for t in json.load(sys.stdin)['data']['activeTargets']]"
# → blackbox-dns up
# → blackbox-http up
# → cadvisor up
# → node up
# → prometheus up
# → traefik up

# Synthetic HTTPS and DNS probes succeed
sudo docker compose -f docker-compose.prod.yml exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=probe_success' \
  | python3 -c "import sys,json; [print(r['metric']['job'], r['metric']['instance'], r['value'][1]) for r in json.load(sys.stdin)['data']['result']]"
# → blackbox-dns dns:53 1
# → blackbox-http https://traefik 1

# Load GRAFANA_ADMIN_PASSWORD from .env and check Grafana + provisioned dashboard via Traefik HTTPS
set -a && source .env && set +a

curl -sk --resolve grafana.localhost:443:127.0.0.1 -u "admin:${GRAFANA_ADMIN_PASSWORD}" https://grafana.localhost/api/health
# → {"database":"ok","version":"13.3.0"}

curl -sk --resolve grafana.localhost:443:127.0.0.1 -u "admin:${GRAFANA_ADMIN_PASSWORD}" 'https://grafana.localhost/api/search?query=Lab' \
  | python3 -c "import sys,json; print([(d['uid'], d['title'], d['folderTitle']) for d in json.load(sys.stdin)])"
# → [('lab-overview', 'Lab Overview', 'Lab')]
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
stack and the Docker daemon. Named volumes ensure that uploaded files, DNS
cache, Prometheus TSDB series, and Grafana state survive a full `docker compose down` /
`up` cycle — they are not deleted unless `down -v` is explicitly passed.

### Verification

```bash
# Bring the stack down (named volumes are preserved without -v , if you want to destroy everything use -v flag)
sudo docker compose -f docker-compose.prod.yml down

# Confirm volumes survived
sudo docker volume ls | grep -E "file-transfer-data|dns-cache|prometheus-data|grafana-data"
# → local   dns-cache
# → local   file-transfer-data
# → local   grafana-data
# → local   prometheus-data

# Bring the stack back up
sudo docker compose -f docker-compose.prod.yml up -d

# All services healthy after cold start
sudo docker compose -f docker-compose.prod.yml ps
# → blackbox-exporter   Up X seconds (healthy)
# → cadvisor            Up X seconds (healthy)
# → dns                 Up X seconds (healthy)
# → file-transfer       Up X seconds (healthy)
# → grafana             Up X seconds (healthy)
# → node-exporter       Up X seconds (healthy)
# → prometheus          Up X seconds (healthy)
# → traefik             Up X seconds (healthy)
# → web-server          Up X seconds (healthy)

# Restart policy survives daemon restart
sudo systemctl restart docker
sleep 5
sudo docker ps --format "table {{.Names}}\t{{.Status}}"
# → blackbox-exporter   Up X seconds
# → cadvisor            Up X seconds
# → dns                 Up X seconds
# → file-transfer       Up X seconds
# → grafana             Up X seconds
# → node-exporter       Up X seconds
# → prometheus          Up X seconds
# → traefik             Up X seconds
# → web-server          Up X seconds
```