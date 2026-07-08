# Web Server — containerize-your-infra

**Docker Engine · custom image (Dockerfile) on nginxinc/nginx-unprivileged:stable-alpine**

---

## Introduction

This document covers the deployment of Nginx as a static web server inside a
Docker container. The service exposes port 8080 and serves a static HTML page —
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

| Parameter    | Value                                                        |
|--------------|--------------------------------------------------------------|
| Base image   | `nginxinc/nginx-unprivileged:stable-alpine`                  |
| Built image  | `web-server:local` (built from `Dockerfile`)                 |
| Port         | 8080 → 8080 (HTTP)                                             |
| TLS          | None — dev environment                                       |
| Content      | Static HTML (lab index page), baked into the image           |
| Config       | Copied at build time — `configs/nginx/`, `configs/html/`     |
| Hardening    | Non-root user, `cap_drop: ALL`, read-only filesystem, tmpfs  |

---

## Before You Start — Image Exploration (optional)

These commands inspect the image before any Compose deployment. Nothing here
affects the module state — no files are created, no config is applied.

**1. Pull and run the image as-is**

```bash
docker run --rm -p 8080:8080 nginxinc/nginx-unprivileged:stable-alpine
```

Open `http://localhost:8080` in a browser. This is the default Nginx welcome
page — the baseline you are about to replace. `--rm` removes the container
automatically when you stop it with `Ctrl+C`.

**2. Explore the image filesystem**

```bash
docker run --rm -it nginxinc/nginx-unprivileged:stable-alpine
```

You are now inside the container. Confirm the paths the Compose file will mount:

```sh
cat /etc/nginx/nginx.conf
# → default config — note the pid, access_log, and user directives
ls /usr/share/nginx/html/
# → index.html  50x.html  (default welcome page)
exit
```

**3. Verify that read-only breaks without tmpfs**

```bash
docker run --rm -p 8080:8080 --read-only nginxinc/nginx-unprivileged:stable-alpine
```

The container exits immediately. Nginx cannot write `/var/run/nginx.pid`.
Now add the two tmpfs mounts — the same ones declared in `docker-compose.yml`:

```bash
docker run --rm -p 8080:8080 --read-only \
  --tmpfs /var/cache/nginx \
  --tmpfs /var/run \
  --tmpfs /tmp \
  nginxinc/nginx-unprivileged:stable-alpine
```

Nginx starts cleanly. `http://localhost:8080` responds. This confirms that
`read_only: true` + `tmpfs` in the Compose file is not boilerplate — it is
the minimum viable write surface for this process.

---

## Step 1 — Dockerfile and Container Hardening

### What was done

The Nginx service is now built from a custom `Dockerfile` instead of running
the official image with runtime bind mounts. The Dockerfile uses
`nginxinc/nginx-unprivileged:stable-alpine` as its base and copies the Nginx
configuration and static HTML into the image at build time.

`docker-compose.yml` replaces the `image:` key with a `build:` block pointing
to this directory. Container hardening remains identical to the previous
approach: non-root execution, all capabilities dropped, read-only filesystem
with `tmpfs` on the three paths Nginx writes to at runtime.

```bash
docker compose build
# → web-server  Built

docker compose up -d
```

📄 [`Dockerfile`](Dockerfile) — image build definition
📄 [`docker-compose.yml`](docker-compose.yml) — `docker compose up -d --build` from this directory

### Why

Building a custom image instead of consuming the official one as-is is a
deliberate portfolio decision, not a functional requirement — the official
image already covered this module's needs. Owning the build layer
(`Dockerfile`, `docker build`) is a core Docker skill that bind mounts don't
exercise, and it's more visible to anyone reviewing this repo.

The base image stays `nginxinc/nginx-unprivileged` — switching to plain
`nginx:stable-alpine` would mean re-adding capabilities (`CHOWN`, `SETUID`,
`SETGID`) just to reach the same non-root posture already solved upstream.
Keeping the rootless base preserves every hardening argument made in the
previous version of this doc: no capabilities to drop back, `read_only: true`
+ `tmpfs` still cover the full write surface.

### Verification

```bash
# Container is running
docker compose ps
# → NAME          IMAGE               STATUS
# → web-server    web-server:local    Up X seconds

# Confirm all processes run as non-root
docker compose exec --user nginx web-server whoami
# → nginx

# HTTP response on mapped port
curl -I http://localhost:8080
# → HTTP/1.1 200 OK

# No writable layer — write attempt must fail
docker compose exec web-server touch /test
# → touch: /test: Read-only file system
```

---

## Step 2 — Nginx Configuration

### What was done

The default Nginx configuration is replaced with a minimal custom config
scoped to this module. Instead of a bind mount, the file is copied into the
image at `/etc/nginx/nginx.conf` by the `Dockerfile` — any change to this
file requires `docker compose up -d --build` to take effect.

The config defines a single `server` block listening on port 8080, serving
static files from `/usr/share/nginx/html`, with access and error logs
directed to stdout/stderr so Docker captures them natively.

`nginx-unprivileged` runs as a non-root user without `CAP_NET_BIND_SERVICE`,
so it cannot bind to ports below 1024. Port 8080 is the correct internal
listen port for this image — the host-side mapping (`8080:8080`) is adjusted
accordingly in the Compose file.

📄 [`configs/nginx/nginx.conf`](configs/nginx/nginx.conf) — `COPY`'d into the image at build time

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

The lab index HTML file is copied into the image at
`/usr/share/nginx/html/index.html` by the `Dockerfile`, replacing the default
Nginx welcome page. Unlike the bind mount approach, changes to this file
require rebuilding the image.

📄 [`configs/html/index.html`](configs/html/index.html) — `COPY`'d into the image at build time

### Why

Replacing the default page removes the Nginx version disclosure embedded in
the welcome page HTML and makes the running service identifiable as part of
this lab. In build-your-infra the equivalent was `cp` to `/var/www/html/` —
here the Dockerfile `COPY` achieves the same result, baked into the image
instead of copied onto a running filesystem.

### Verification
/
```bash
# Page is served correctly
curl http://localhost:8080
# → (contents of configs/html/index.html)

# Default Nginx page is not reachable
curl -s http://localhost:8080 | grep -i "Welcome to nginx"
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
docker compose down -v

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

## Production deployment

In production the module runs from `docker-compose.prod.yml` instead of
`docker-compose.yml`. Both files now build from the same `Dockerfile` — the
image, hardening, and Nginx config are identical between dev and prod.
What changes is the operational layer.

`docker-compose.prod.yml` replaces the `image:` key with the same `build:`
block used in dev. Config files are no longer mounted at runtime in either
environment — they are baked into the image at build time.

| Parameter | dev | prod |
|---|---|---|
| Image source | `build:` — local `docker compose build` | `build:` — local `docker compose build` |
| Config (`nginx.conf`, `index.html`) | Baked into image at build time | Baked into image at build time |
| Restart policy | `"no"` (default) | `unless-stopped` |
| Healthcheck | None | `wget` on port 8080 |

```bash
docker compose -f docker-compose.prod.yml up -d --build
```

📄 [`docker-compose.prod.yml`](docker-compose.prod.yml)

### Verification

```bash
# -v removes named volumes — correct for lab testing, destructive with real data
docker compose -f docker-compose.prod.yml down -v
docker compose -f docker-compose.prod.yml up -d --build

docker compose -f docker-compose.prod.yml ps
# → NAME         IMAGE               STATUS
# → web-server   web-server:local    Up X seconds (healthy)

# Confirm healthcheck is passing — wait ~10s after start_period
docker inspect web-server --format '{{ .State.Health.Status }}'
# → healthy

# Confirm restart policy survives daemon restart
# dev (macOS/OrbStack):
orb restart -a
# prod (Linux):
sudo systemctl restart docker

sleep 5
docker ps
# → web-server   Up X seconds

curl -I http://localhost:8080
# → HTTP/1.1 200 OK

# Remove everything
docker compose -f docker-compose.prod.yml down -v
```

---

**Next:** [`modules/file-transfer/file-transfer.md`](../file-transfer/file-transfer.md)