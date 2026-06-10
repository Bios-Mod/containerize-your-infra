# Web Server — containerize-your-infra

**Ubuntu 24.04 LTS · Docker Engine · Nginx official image**

---

## Introduction

This document covers the deployment of Nginx as a static web server inside a
Docker container. The service exposes port 80 and serves a static HTML page —
the lab index. TLS termination and HTTPS are out of scope for this environment;
they are addressed in the production overlay (`environments/prod/`).

This module establishes the first running container in the lab. Its purpose is
to validate the Docker Engine setup, practice Compose fundamentals, and apply
container hardening patterns that carry forward to every subsequent module.

> **No reverse proxy in this module.** Nginx here serves static content only.
> Upstream routing and TLS termination are handled by Traefik in the
> `reverse-proxy` module.

> **Config files in `configs/`** contain only the blocks or full files added
> by this module. The path inside the module folder is referenced after each
> deploy block.

---

## Environment

| Parameter      | Value                                      |
|----------------|--------------------------------------------|
| Image          | `nginx:stable-alpine`                      |
| Port           | 80 (HTTP)                                  |
| TLS            | None — dev environment                     |
| Content        | Static HTML (lab index page)               |
| Config mount   | Bind mount (dev) — `configs/nginx/`        |
| Hardening      | Non-root user, `cap_drop: ALL`, read-only filesystem |

---

## Step 1 — Compose File and Container Hardening

### What was done

The `docker-compose.yml` file defines the Nginx service using the official
`nginx:stable-alpine` image. The configuration and HTML content are mounted
from the module's `configs/` folder using bind mounts — the dev pattern for
fast iteration without rebuilding the image.

Container hardening is applied inline: the process runs as a non-root user,
all Linux capabilities are dropped, and the container filesystem is set to
read-only. A single `tmpfs` mount covers the paths Nginx requires to write
at runtime (`/var/cache/nginx`, `/var/run`).

```yaml
# docker-compose.yml
```

📄 [`docker-compose.yml`](docker-compose.yml) — `docker compose up -d` from this directory

### Why

`nginx:stable-alpine` is the official image on Alpine Linux — smaller attack
surface than the Debian variant, no package manager in the final layer, and
the `stable` tag avoids breaking changes from mainline releases.

Bind mounts replace the `COPY` step you would use in a Dockerfile. In a VM
you would `cp` the config to `/etc/nginx/` — in a container the equivalent is
mounting the file directly from the host at the path Nginx expects. The result
is the same: Nginx reads the config from a known path. The difference is that
changes to the source file on the host are reflected inside the container
without a restart.

`cap_drop: ALL` removes every Linux capability from the container process. An
unprivileged Nginx serving on port 80 (remapped from host 8080 in dev) does
not need any capability. This is the container equivalent of running a service
as a dedicated low-privilege user in build-your-infra — except the isolation
boundary here is the kernel capability set, not just the Unix UID.

`read_only: true` mounts the container root filesystem as read-only. Combined
with `tmpfs` on the two paths Nginx writes to at runtime, this means any
process that escapes the application layer cannot persist changes to the image
filesystem.

### Verification

```bash
# Start the service
docker compose up -d

# Container is running
docker compose ps
# → NAME          IMAGE                  STATUS
# → web-server    nginx:stable-alpine    Up X seconds

# Confirm process is running as non-root
docker compose exec web-server whoami
# → nginx

# HTTP response on mapped port
curl -I http://localhost:8080
# → HTTP/1.1 200 OK
# → Server: nginx/1.x.x

# No writable layer — write attempt must fail
docker compose exec web-server touch /test
# → touch: /test: Read-only file system
```

---

## Step 2 — Nginx Configuration

### What was done

The default Nginx configuration is replaced with a minimal custom config
scoped to this module. The file is mounted into the container at
`/etc/nginx/nginx.conf` via the bind mount declared in Step 1.

The config defines a single `server` block listening on port 80, serving
static files from `/usr/share/nginx/html`, with access and error logs
directed to stdout/stderr so Docker captures them natively.

📄 [`configs/nginx/nginx.conf`](configs/nginx/nginx.conf) — mounted at `/etc/nginx/nginx.conf`

### Why

The default `nginx.conf` bundled in the official image includes directives
that make sense for a general-purpose installation but add noise in a
single-service container: `user nginx` (overridden by the non-root USER),
`pid /var/run/nginx.pid` at a path that conflicts with read-only fs, and
`access_log` writing to a file path instead of stdout. A minimal custom
config eliminates this friction and makes the container's behaviour explicit.

Redirecting logs to `stdout`/`stderr` is the Docker-native logging pattern.
It allows `docker compose logs` to capture Nginx output without mounting an
additional log volume, and it integrates cleanly with any log aggregator that
reads from the container log driver.

### Verification

```bash
# Config is readable inside the container
docker compose exec web-server cat /etc/nginx/nginx.conf
# → (contents of configs/nginx/nginx.conf)

# Nginx loaded the config without errors
docker compose exec web-server nginx -t
# → nginx: configuration file /etc/nginx/nginx.conf test is successful

# Logs appear in compose output
docker compose logs web-server
# → web-server  | <timestamp> "GET / HTTP/1.1" 200 ...
```

---

## Step 3 — Lab Index Page

### What was done

The lab index HTML file is mounted into the container at
`/usr/share/nginx/html/index.html`, replacing the default Nginx welcome page.
The file is served directly from the bind mount — no image rebuild required.

```bash
mkdir -p configs/html
```

📄 [`configs/html/index.html`](configs/html/index.html) — mounted at `/usr/share/nginx/html/index.html`

### Why

Replacing the default page removes the Nginx version disclosure embedded in
the welcome page HTML and makes the running service identifiable as part of
this lab. In build-your-infra the equivalent was `cp` to `/var/www/html/` —
here the bind mount achieves the same result without touching the image layer.

### Verification

```bash
# Page is served correctly
curl http://localhost:8080
# → (contents of configs/html/index.html)

# Default Nginx page is not reachable
curl http://localhost:8080 | grep -i "Welcome to nginx"
# → (no output — default page is replaced)
```

---

## Step 4 — Smoke Test and Container Lifecycle

### What was done

Full lifecycle test of the container: stop, remove, and bring back up from
the Compose file. This validates that the service is fully reproducible from
config and has no state dependency on the container layer.

> This step has no new config or deploy action. It is a verification-only
> step to confirm the module is production-ready at the dev level before
> moving to the next module.

### Why

A container that survives a stop/rm/up cycle without manual intervention is
the baseline requirement for any service managed by Compose. In build-your-infra
the equivalent check was `systemctl restart nginx` — here the unit of restart
is the container itself, not the process. If the service requires manual steps
to recover after `docker compose down`, the module is not complete.

### Verification

```bash
# Stop and remove the container
docker compose down

# Confirm no container is running
docker compose ps
# → (empty)

# Bring the service back up
docker compose up -d

# Service is healthy — same response as Step 1
curl -I http://localhost:8080
# → HTTP/1.1 200 OK

# Inspect applied security constraints
docker inspect web-server --format '{{ .HostConfig.CapDrop }}'
# → [ALL]

docker inspect web-server --format '{{ .HostConfig.ReadonlyRootfs }}'
# → true
```

---