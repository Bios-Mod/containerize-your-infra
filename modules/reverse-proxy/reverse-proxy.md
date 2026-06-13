# Reverse Proxy — containerize-your-infra

**Docker Engine · traefik:v3.7**

---

## Introduction

This module deploys Traefik as a standalone reverse proxy. Traefik reads
routing rules from Docker labels attached to each service and dynamically
builds its routing table — no static upstream config blocks to maintain.

In build-your-infra, the reverse proxy was a `location` block inside the
Nginx server config. Here the proxy has its own lifecycle, its own container,
and its own config. Backend services declare their own routing rules via
labels — the proxy never needs to be restarted when a new backend joins.

This module is self-contained: it defines its own `web-server` backend for
verification. Integration with the shared `lab-net` network and the other
modules happens in `stacks/full-infra`.

> **Traefik concepts used in this module:**
> - **Entrypoint** — a port Traefik listens on (`:80`, `:443`, `:8080`)
> - **Router** — a rule that matches incoming requests (by host, path, etc.)
> - **Middleware** — a transformation applied to a request before it hits the backend (BasicAuth, redirects, headers)
> - **Service** — the upstream target (a container, resolved via Docker provider)
> - **Provider** — the source Traefik reads config from (here: Docker socket)

> **Config files in `configs/traefik/`** contain only the files added by
> this module. The path inside the module folder is referenced after each
> deploy block.

---

## Environment

| Parameter        | Value                                              |
|------------------|----------------------------------------------------|
| Image            | `traefik:v3.7`                                     |
| Entrypoints      | `web` → 80, `websecure` → 443, `dashboard` → 8080 |
| TLS              | Self-signed cert (dev) — Let's Encrypt ready (prod)|
| Dashboard        | Enabled — BasicAuth protected                      |
| Backend          | `nginxinc/nginx-unprivileged:stable-alpine`        |
| Network          | `proxy-net` — `172.21.0.0/24`                      |
| Config mount     | Bind mount (dev) — `configs/traefik/`              |

---

## Before You Start — Image Exploration (optional)

```bash
# Pull the image and check the default entrypoint
docker run --rm traefik:v3.7 --help
# → Traefik CLI help — lists all flags and their defaults

# Check the default user (traefik runs as root by default — noted in Step 1)
docker run --rm traefik:v3.7 id
# → uid=0(root) gid=0(root)
```

Traefik runs as root because it needs to read the Docker socket. This is the
standard posture for Traefik and is addressed in the hardening section of
Step 1.

---

## Step 1 — Network, Certificates and Static Configuration

### What was done

A dedicated Docker bridge network `proxy-net` is created with subnet `172.21.0.0/24`. Before the first deploy, a self-signed TLS certificate is generated — Traefik loads `dynamic.yml` at startup and the `tls.certificates` block is evaluated immediately, so the cert files must exist before `docker compose up` is called.

The Traefik static config is defined in `configs/traefik/traefik.yml` — it declares the entrypoints, enables the Docker provider, and exposes the dashboard exclusively via the authenticated router defined in `dynamic.yml`.

```bash
# Generate cert before first deploy — required by dynamic.yml at startup
mkdir -p configs/traefik/certs

openssl req -x509 -newkey rsa:4096 -nodes \
  -keyout configs/traefik/certs/lab.key \
  -out configs/traefik/certs/lab.crt \
  -days 365 \
  -subj "/CN=*.localhost" \
  -addext "subjectAltName=DNS:web.localhost,DNS:traefik.localhost"

# Verify cert is valid PEM before deploying
openssl x509 -noout -subject -in configs/traefik/certs/lab.crt
# → subject=CN=*.localhost
```

> **Do not commit the private key to a public repository.**
> Add `configs/traefik/certs/lab.key` to `.gitignore`.

```bash
docker compose up -d
```

📄 [`configs/traefik/traefik.yml`](configs/traefik/traefik.yml) — mounted at `/etc/traefik/traefik.yml`
📄 [`docker-compose.yml`](docker-compose.yml) — `docker compose up -d` from this directory
📄 `configs/traefik/certs/lab.crt` — mounted at `/etc/traefik/certs/lab.crt`
📄 `configs/traefik/certs/lab.key` — mounted at `/etc/traefik/certs/lab.key`

### Why

* **Static vs. Dynamic Config:** Traefik splits configuration into static (`traefik.yml` — entrypoints and providers, loaded once at startup) and dynamic (`dynamic.yml` and Docker labels — routes, middlewares and TLS, hot-reloaded). This mirrors Nginx's `nginx.conf` vs. `sites-enabled/` architecture.
* **Cert as deploy prerequisite:** The `tls.certificates` block in `dynamic.yml` is parsed on first load. If the cert files are missing, Traefik logs a fatal TLS store error and no HTTPS router comes up. Generating the cert before `docker compose up` is the correct posture — it is infrastructure state that must exist before the service starts, not a feature configured later.
* **Docker Provider Security:** Mounting `/var/run/docker.sock:ro` allows dynamic service discovery without giving Traefik write access to the daemon. The dedicated `proxy-net` bridges the proxy and backends, isolating them from other containers.

### Verification

```bash
docker compose ps
# → NAME      IMAGE           STATUS
# → traefik   traefik:v3.7    Up X seconds

docker compose logs traefik | grep -E "Starting provider|file.Provider"
# → Starting provider *file.Provider
# → Starting provider *docker.Provider

docker compose logs traefik | grep -i error
# → (no output — zero errors on clean start)
```

---

## Step 2 — Dashboard with BasicAuth

### What was done

The Traefik dashboard is protected with a BasicAuth middleware defined in
the dynamic config file `configs/traefik/dynamic.yml`. The middleware is
applied to the dashboard router via labels on the Traefik container itself.

Generate the hashed password before deploying:

```bash
# htpasswd is in apache2-utils (Ubuntu) or httpd-tools (RHEL)
# The -n flag prints to stdout instead of writing to a file
htpasswd -nB admin
# → enter password at prompt
# → admin:$2y$05$...  ← copy this full string into dynamic.yml
```

> **The bcrypt hash goes into `configs/traefik/dynamic.yml`**, not into
> `docker-compose.yml`. Never put credentials in the Compose file.

📄 [`configs/traefik/dynamic.yml`](configs/traefik/dynamic.yml) — mounted at `/etc/traefik/dynamic.yml`

### Why

BasicAuth is implemented as a **middleware** — a unit of logic that sits
between the router and the backend. The router matches the request (host: traefik.localhost) on the websecure entrypoint (:443), the middleware challenges for credentials, and only on success does the request reach the Traefik API/dashboard.

The `dashboard` entrypoint (`:8080`) exposes the raw Traefik API for internal
verification only (used in Step 1). It must not be exposed publicly — in prod,
set `api.insecure: false` in `traefik.yml` and rely exclusively on the
label-based router for dashboard access.

Defining the middleware in `dynamic.yml` rather than as labels keeps
the Compose file clean and makes the middleware reusable across routers —
the same `auth-dashboard` middleware can be referenced by any router by
name, without duplicating the hash.

Bcrypt (`-B` flag) is used because Traefik's BasicAuth middleware supports
MD5, SHA1, and bcrypt — and bcrypt is the only one that is not trivially
reversible with a rainbow table. This is the production-correct choice
regardless of environment.

### Verification

```bash
# HTTP redirects to HTTPS before BasicAuth can evaluate — 301 is correct here
curl -s -o /dev/null -w "%{http_code}" http://traefik.localhost/dashboard/
# → 301

# Dashboard is unreachable without credentials
curl -sk -o /dev/null -w "%{http_code}" https://traefik.localhost/dashboard/
# → 401

# Dashboard is reachable with correct credentials
curl -sk -o /dev/null -w "%{http_code}" -u admin:<your-password> https://traefik.localhost/dashboard/
# → 200

# Wrong password is rejected
curl -sk -o /dev/null -w "%{http_code}" -u admin:wrongpassword https://traefik.localhost/dashboard/
# → 401
```

---

## Step 3 — Backend Routing and TLS Verification

### What was done

The `web-server` service is already declared in `docker-compose.yml` and running since Step 1. This step verifies that Traefik has discovered it via the Docker provider, that the routing labels are correctly applied, and that TLS is active end-to-end.

No new deploy action is needed.

📄 [`docker-compose.yml`](docker-compose.yml) — `web-server` labels define the router, service and TLS

### Why

Labels are the Docker provider's dynamic config. When Traefik sees a container with `traefik.enable=true`, it reads its labels and builds the router and service entry automatically — no restart required, no static upstream block to edit. The `tls=true` label on the router tells Traefik to serve this route over HTTPS using the certificate loaded centrally in `dynamic.yml`.

This is the key difference from build-your-infra: in Nginx, TLS and upstream were configured in the same server block. In Traefik, TLS is managed at the entrypoint and cert store level — the backend never sees HTTPS, and any new router inherits TLS by declaring a single label.

`nginxinc/nginx-unprivileged` runs as a non-root user by default and serves HTTP on port `8080` internally. Traefik handles the public-facing TLS termination — the backend only receives plain HTTP.

### Verification

```bash
# Both containers are running since Step 1
docker compose ps
# → NAME         IMAGE                                        STATUS
# → traefik      traefik:v3.7                                 Up X seconds
# → web-server   nginxinc/nginx-unprivileged:stable-alpine    Up X seconds

# Traefik has discovered the backend via Docker labels
curl -sk -u admin:<your-password> https://traefik.localhost/api/http/routers | python3 -m json.tool | grep "web-server"
# → "web-server@docker"

# HTTPS request is proxied to the backend
curl -sk -o /dev/null -w "%{http_code}" -H "Host: web.localhost" https://localhost:443
# → 200

# HTTP is redirected to HTTPS — entrypoint-level redirect, not per-router
curl -s -o /dev/null -w "%{http_code}" -H "Host: web.localhost" http://localhost:80
# → 301

# Certificate subject matches
openssl s_client -connect localhost:443 -servername web.localhost </dev/null 2>/dev/null \
  | openssl x509 -noout -subject

# → subject=CN=*.localhost
```

---

## Step 4 — Smoke Test and Container Lifecycle

### What was done

Full lifecycle test: stop, remove, and bring back up. Validates that Traefik
re-discovers the backend, reloads TLS, and the dashboard auth middleware is
restored — all without manual intervention.

> This step has no new config or deploy action. It is a verification-only
> step to confirm the module is complete before moving to environments/.

### Why

In build-your-infra the equivalent was `systemctl restart nginx` followed by
a curl check. Here the unit of restart is the Compose stack. The critical
check is that Traefik's dynamic config (loaded from the mounted file and from
Docker labels) is fully re-applied on cold start — no state is held in memory
that would be lost.

### Verification

```bash
docker compose down
docker compose up -d

# Both containers running
docker compose ps
# → traefik      Up X seconds
# → web-server   Up X seconds

# Backend re-discovered
curl -sk -u admin:<your-password> https://traefik.localhost/api/http/routers | python3 -m json.tool | grep "web-server"
# → "web-server@docker"

# HTTPS proxy works
curl -sk -o /dev/null -w "%{http_code}" -H "Host: web.localhost" https://localhost:443
# → 200

# Dashboard auth still active
curl -sk -o /dev/null -w "%{http_code}" https://traefik.localhost/dashboard/
# → 401
```

---

**Next:** [`environments/`](../../environments/README.md)