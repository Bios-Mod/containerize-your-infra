# Monitoring — containerize-your-infra

**Docker Engine · prom/prometheus:v3.16.0 · grafana/grafana:13.3.0 · prom/node-exporter:v1.12.1 · ghcr.io/google/cadvisor:v0.60.6 · prom/blackbox-exporter:v0.29.1**

---

## Introduction

This document covers the deployment of the pull-based observability stack for
containerized infrastructure monitoring: `node_exporter` for host telemetry,
`cAdvisor` for per-container resource usage, `blackbox_exporter` for synthetic
HTTP/DNS availability probes, Traefik's `/metrics` endpoint for reverse-proxy
telemetry, `Prometheus` as the time-series scraper and query engine, and
`Grafana` (with provisioned datasource and `Lab Overview` dashboard) exposed
exclusively behind Traefik HTTPS at `https://grafana.localhost`.

In `build-your-infra`, host metrics were collected by an OS-level
`prometheus-node-exporter` package over a WireGuard tunnel. Here, all
components run as containers on the shared `proxy-net` Docker bridge network and
communicate via Docker's embedded DNS without publishing any Prometheus,
exporter, or direct Grafana ports to the host.

> **Prerequisite — Reverse Proxy (`proxy-net`):** the `reverse-proxy` module
> must already be running (`modules/reverse-proxy/docker/`) so the external
> Docker network `proxy-net` (`172.21.0.0/24`) exists before running
> `docker compose up -d` in this module.

> **Config files in `configs/`** (`configs/prometheus/`, `configs/blackbox/`, and
> `configs/grafana/`) contain only the configuration added by this module.
> Referenced paths sit relative to `modules/monitoring/docker/`.

---

## Environment

| Parameter | Value |
|---|---|
| Prometheus image | `prom/prometheus:v3.16.0` |
| Grafana image | `grafana/grafana:13.3.0` |
| Node Exporter image | `prom/node-exporter:v1.12.1` |
| cAdvisor image | `ghcr.io/google/cadvisor:v0.60.6` |
| Blackbox Exporter image | `prom/blackbox-exporter:v0.29.1` |
| Network | External `proxy-net` (`172.21.0.0/24`) |
| Published ports | None — internal `proxy-net` endpoints only; Grafana ingress via Traefik (`https://grafana.localhost:443`) |
| Scrape interval | `15s` (`prometheus`, `node`, `cadvisor`, `blackbox-http`, `blackbox-dns`, `traefik`) |
| TSDB retention | `15d` in dev (`--storage.tsdb.retention.time=15d`); `15d` + `1GB` cap in prod (`--storage.tsdb.retention.size=1GB`) |
| Persistence (dev) | Ephemeral — container TSDB storage and Grafana `tmpfs` `/var/lib/grafana` discarded on `down` |
| Persistence (prod) | Named volumes `prometheus-data` (`/prometheus`) and `grafana-data` (`/var/lib/grafana`) |
| Config mounts | Bind mounts `:ro` under `configs/prometheus/`, `configs/blackbox/`, and `configs/grafana/` |
| Credentials | `.env` copied from `.env.example` (gitignored — holds `GRAFANA_ADMIN_PASSWORD`) |
| Restart policy | `"no"` (dev) · `unless-stopped` (prod) |

---

## Step 1 — Directory Structure and Prerequisites

### What was done

Verify that the external `proxy-net` bridge network exists, confirm you are in
`modules/monitoring/docker/`, and validate the Compose file syntax before
starting any containers.

```bash
cd modules/monitoring/docker/

# Confirm the external proxy-net network created by reverse-proxy exists
docker network inspect proxy-net --format '{{.Name}} ({{.Driver}})'
# → proxy-net (bridge)

# Validate Compose syntax statically before deploying
docker compose config --quiet
# → (no output — exit code 0 confirms valid Compose syntax)
```

📄 [`docker-compose.yml`](docker-compose.yml) — service definitions and external `proxy-net` declaration
📄 [`configs/prometheus/prometheus.yml`](configs/prometheus/prometheus.yml) — Prometheus global settings and scrape jobs

### Why

Declaring `proxy-net` as `external: true` decouples the monitoring stack's
lifecycle from the reverse proxy network. Instead of creating an isolated
bridge or publishing `9090`, `9100`, and `8080` on the host, all monitoring
containers attach directly to `proxy-net` and resolve one another by service
name (`node-exporter:9100`, `cadvisor:8080`).

### Verification

```bash
docker network ls | grep proxy-net
# → <network-id>   proxy-net   bridge    local
```

---

## Step 2 — Host Metrics with node_exporter

### What was done

Deploy the `node-exporter` service (`prom/node-exporter:v1.12.1`) to expose
kernel, CPU, memory, load, and filesystem metrics from the Docker host on port
`9100` inside `proxy-net`.

```bash
docker compose up -d node-exporter
```

📄 [`docker-compose.yml`](docker-compose.yml) — `node-exporter` service definition

### Why

* **Host namespace and rootfs visibility:** `pid: host` shares the host PID
  namespace with the container so process and system counters are visible.
  Mounting `/:/host:ro,rslave` with `--path.rootfs=/host` lets `node_exporter`
  inspect host filesystems read-only; `rslave` propagation ensures mount events
  performed on the host propagate into `/host` without allowing writes back to
  the host.
* **Bridge network limitation:** unlike the self-managed setup in
  `build-your-infra` (or running with `network_mode: host`), attaching
  `node-exporter` to the `proxy-net` bridge isolates it from the host network
  namespace. Consequently, `node_network_*` metrics report the container's own
  `eth0` interface rather than the host's physical NICs. Keeping the exporter off
  the host network and avoiding published ports is an intentional isolation
  trade-off for this lab.
* **OrbStack runtime note:** on macOS with OrbStack, containers execute inside
  OrbStack's Linux VM, so "host" metrics reported by `node_exporter` reflect the
  OrbStack VM rather than macOS hardware directly. On a native Linux host (such
  as EC2), they reflect the host instance directly.
* **Hardening:** the official image runs as unprivileged `USER nobody`, drops all
  Linux capabilities (`cap_drop: [ALL]`), enforces `no-new-privileges:true`, and
  locks the container root filesystem (`read_only: true`).

### Verification

```bash
docker compose ps node-exporter
# → NAME            IMAGE                         STATUS
# → node-exporter   prom/node-exporter:v1.12.1    Up X seconds

docker compose exec -T node-exporter wget -qO- http://localhost:9100/metrics | head -n 5
# → # HELP go_gc_duration_seconds A summary of the pause duration of garbage collection cycles.
# → # TYPE go_gc_duration_seconds summary
# → ...
```

---

## Step 3 — Container Metrics with cAdvisor

### What was done

Deploy `cadvisor` (`ghcr.io/google/cadvisor:v0.60.6`) with read-only host mounts,
`/dev/kmsg` device access, and `privileged: true` so it can collect CPU, memory,
network, and disk I/O metrics for every running container on the host.

```bash
docker compose up -d cadvisor
```

📄 [`docker-compose.yml`](docker-compose.yml) — `cadvisor` service definition

### Why

* **Justified `privileged: true` exception:** project policy forbids
  `privileged: true` unless explicitly justified. `cAdvisor` inspects kernel
  cgroups, container namespaces, block device statistics, and Docker metadata
  across all containers on the host, and monitors `/dev/kmsg` for kernel
  out-of-memory (OOM) kills. Running `cAdvisor` unprivileged omits cgroup and
  block I/O metrics depending on host kernel and cgroup v2 layout; therefore
  `privileged: true` is used here alongside `read_only: true`,
  `no-new-privileges:true`, and `:ro` host bind mounts (`/`, `/var/run`, `/sys`,
  `/var/lib/docker`, `/dev/disk`) so the container cannot modify host state.
  Because `privileged: true` grants full Linux capabilities, `cap_drop: [ALL]`
  is incompatible and omitted on this service.
* **OrbStack runtime note:** on macOS OrbStack, cAdvisor may report incomplete
  container labels or metadata compared to a native Linux Docker Engine host;
  core CPU and memory series remain available for inspection.

### Verification

```bash
docker compose ps cadvisor
# → NAME       IMAGE                             STATUS
# → cadvisor   ghcr.io/google/cadvisor:v0.60.6   Up X seconds (healthy)

docker compose exec -T cadvisor wget -qO- http://localhost:8080/healthz
# → ok

docker compose exec -T cadvisor wget -qO- http://localhost:8080/metrics | head -n 5
# → # HELP cadvisor_version_info A metric with a constant '1' value labeled by kernel version, ...
# → # TYPE cadvisor_version_info gauge
# → ...
```

---

## Step 4 — Prometheus Server and Scrape Configuration

### What was done

Validate `configs/prometheus/prometheus.yml` with `promtool`, then start the
`prometheus` service (`prom/prometheus:v3.16.0`) configured with a `15s` scrape
interval, `15d` retention, and three static jobs (`prometheus`, `node`, and
`cadvisor`), each tagged with `host: lab-docker`.

```bash
# Validate Prometheus config syntax before starting the container
docker compose run --rm --no-deps --entrypoint promtool prometheus check config /etc/prometheus/prometheus.yml
# → Checking /etc/prometheus/prometheus.yml
# →  SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax

# Start Prometheus (and ensure dependencies are up)
docker compose up -d prometheus
```

📄 [`configs/prometheus/prometheus.yml`](configs/prometheus/prometheus.yml) — mounted read-only at `/etc/prometheus/prometheus.yml`
📄 [`docker-compose.yml`](docker-compose.yml) — `prometheus` service definition

### Why

* **Configuration and labels:** mounting `prometheus.yml` as `:ro` mirrors the
  pattern used in `reverse-proxy` and `dns` — config lives versioned in the
  repository and the container cannot alter it at runtime. Attaching a fixed
  `host: lab-docker` label to every target prepares consistent label-based
  filtering across Prometheus, host, and container queries.
* **No TSDB persistence in dev:** unlike the production Compose configuration
  (which attaches a named volume to `/prometheus`), the dev environment mounts no
  persistent volume for TSDB data. The image's default `/prometheus` volume is
  container-scoped and discarded when `docker compose down` removes the
  container, allowing clean, repeatable iterations during development. Passing
  `--storage.tsdb.retention.time=15d` bounds time-series storage while the
  stack remains running.
* **Hardening:** `prom/prometheus` runs as `USER nobody` (UID `65534`), drops
  all capabilities (`cap_drop: [ALL]`), enforces `no-new-privileges:true`, sets
  `read_only: true` on the root filesystem (while the image's `/prometheus`
  mount remains writable for TSDB segments), and exposes no ports to the host.

### Verification

```bash
docker compose exec -T prometheus wget -qO- http://localhost:9090/-/ready
# → Prometheus Server is Ready.
```

---

## Step 5 — Verify Scrape Targets and Sample Metrics

### What was done

Confirm all three containers are running, query the Prometheus HTTP API
(`/api/v1/targets`) from inside the container network to verify that all three
jobs report `up`, and execute sample PromQL instant queries for host and
container CPU and memory metrics.

```bash
docker compose ps
# → NAME            IMAGE                             STATUS
# → cadvisor        ghcr.io/google/cadvisor:v0.60.6   Up X seconds (healthy)
# → node-exporter   prom/node-exporter:v1.12.1        Up X seconds
# → prometheus      prom/prometheus:v3.16.0           Up X seconds

# Confirm all configured scrape targets report health "up"
docker compose exec -T prometheus wget -qO- http://localhost:9090/api/v1/targets \
  | python3 -c "import sys,json; [print(t['labels']['job'], t['labels']['host'], t['health']) for t in json.load(sys.stdin)['data']['activeTargets']]"
# → cadvisor lab-docker up
# → node lab-docker up
# → prometheus lab-docker up
```

### Why

Readiness (`/-/ready`) only confirms the Prometheus HTTP server started.
Inspecting `/api/v1/targets` verifies Docker DNS resolution across `proxy-net`
(`node-exporter:9100`, `cadvisor:8080`) and clean metric ingestion, while sample
PromQL queries confirm that both host-level (`node_*`) and container-level
(`container_*`) time series are present in the TSDB — all without exposing
unauthenticated Prometheus endpoints outside `proxy-net`.

### Verification

Wait ~15–20 seconds after startup so at least one scrape cycle completes, then
run sample PromQL instant queries against the Prometheus HTTP API:

```bash
# Host CPU counters (seconds per CPU core and mode)
docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=count(node_cpu_seconds_total{mode="idle"})' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['result'])"
# → [{'metric': {}, 'value': [<timestamp>, '<cpu-count>']}]

# Host available memory (bytes)
docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=node_memory_MemAvailable_bytes' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['result'])"
# → [{'metric': {'__name__': 'node_memory_MemAvailable_bytes', 'host': 'lab-docker', ...}, 'value': [<timestamp>, '<bytes>']}]

# Container CPU usage sample (rate over 1m — wait ~30s for two scrapes)
docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=topk(3,rate(container_cpu_usage_seconds_total[1m]))' \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin)['data']['result']))"
# → 3

# Container memory working set sample (bytes)
docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=topk(3,container_memory_working_set_bytes)' \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin)['data']['result']))"
# → 3
```

---

## Step 6 — Synthetic Probes with blackbox_exporter

### What was done

Deploy `blackbox_exporter` (`prom/blackbox-exporter:v0.29.1`) on `proxy-net`
with no published ports and two probe modules defined in
`configs/blackbox/blackbox.yml`:

- `http_2xx_insecure`: HTTP/HTTPS probe accepting only status `200`, requiring TLS
  (`fail_if_not_ssl: true`), sending `Host: web.localhost`, preferring IPv4, and
  skipping CA trust verification (`insecure_skip_verify: true`) for the lab's
  self-signed certificate.
- `dns_lab_soa`: UDP `SOA` query for `lab.local` over IPv4 expecting `NOERROR`.

> **Prerequisite — Target services running on `proxy-net`:** `reverse-proxy`
> (`traefik` and `web-server`) and `dns` must be running and reachable on
> `proxy-net` before running the probes in Steps 6 and 7. When deploying from
> `stacks/full-infra/docker/`, all three services already share `proxy-net`;
> when testing standalone module setups in dev, ensure `dns` is attached to
> `proxy-net` (`docker network connect proxy-net dns` if it started on `lab-net`
> only).

```bash
# Validate blackbox.yml syntax before starting the container
docker compose run --rm --no-deps blackbox-exporter --config.file=/config/blackbox.yml --config.check
# → ... msg="Config file is ok exiting..."

# Start blackbox-exporter
docker compose up -d blackbox-exporter
```

📄 [`configs/blackbox/blackbox.yml`](configs/blackbox/blackbox.yml) — mounted read-only at `/config/blackbox.yml`
📄 [`docker-compose.yml`](docker-compose.yml) — `blackbox-exporter` service definition

### Why

* **Probing `https://traefik` with `Host: web.localhost` vs `web-server` directly:**
  `web-server` serves plain HTTP on port `8080` inside `proxy-net`, while real
  requests enter through `traefik` on `:443`, where Traefik terminates TLS and
  evaluates the `Host(\`web.localhost\`)` router before proxying upstream.
  Targeting `https://traefik` with `Host: web.localhost` validates TLS
  termination, certificate lifetime, Traefik routing, and the Nginx backend in
  a single probe — hitting `web-server` directly would bypass TLS and reverse
  proxy rules. `fail_if_not_ssl: true` ensures unencrypted HTTP cannot pass
  silently, and `valid_status_codes: [200]` catches upstream proxy failures
  (`502`) or missing routes (`404`).
* **Why `insecure_skip_verify: true` is enabled:** Traefik serves the lab's
  self-signed wildcard certificate (`CN=*.localhost`), which is not issued by a
  CA trusted in `prom/blackbox-exporter`'s default trust store. Skipping CA chain
  verification allows the probe to complete the TLS handshake, verify `200 OK`,
  and export `probe_ssl_earliest_cert_expiry` without injecting a custom CA
  bundle into the official image. In a production environment using a public or
  trusted internal CA, `insecure_skip_verify` must remain `false`.
* **DNS `SOA` probe (`dns_lab_soa`) vs `pidof named`:** the `dns` container's
  `pidof named` healthcheck only proves that the daemon process PID exists —
  BIND9 can stay running while failing to load zone files, bind UDP `:53`, or
  answer queries. Sending a UDP `SOA` query for `lab.local` expecting `NOERROR`
  exercises the network listener and authoritative zone resolution end-to-end.
* **Hardening:** `blackbox-exporter` drops all Linux capabilities
  (`cap_drop: [ALL]`), enforces `no-new-privileges:true`, sets `read_only: true`,
  mounts `blackbox.yml` read-only, and exposes no ports on the host. No ICMP
  probe is configured, so `CAP_NET_RAW` is not needed.

### Verification

```bash
docker compose ps blackbox-exporter
# → NAME                IMAGE                          STATUS
# → blackbox-exporter   prom/blackbox-exporter:v0.29.1 Up X seconds

# Confirm internal exporter endpoint responds inside proxy-net
docker compose exec -T blackbox-exporter wget -qO- http://localhost:9115/metrics | head -n 5
# → # HELP blackbox_exporter_build_info A metric with a constant '1' value labeled by version, revision, branch, goversion from which blackbox_exporter was built, and the goos and goarch for the build.
# → # TYPE blackbox_exporter_build_info gauge
# → ...
```

---

## Step 7 — Probe Jobs and Verification

### What was done

Add the `blackbox-http` (`https://traefik` via `http_2xx_insecure`) and
`blackbox-dns` (`dns:53` via `dns_lab_soa`) scrape jobs tagged with
`host: lab-docker` to `configs/prometheus/prometheus.yml` using the multi-target
`relabel_configs` pattern, validate `prometheus.yml`, and restart `prometheus`
so it loads the updated configuration.

```bash
# Validate updated Prometheus config syntax before reloading
docker compose run --rm --no-deps --entrypoint promtool prometheus check config /etc/prometheus/prometheus.yml
# → Checking /etc/prometheus/prometheus.yml
# →  SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax

# Restart Prometheus to load the updated bind-mounted prometheus.yml
docker compose restart prometheus
```

📄 [`configs/prometheus/prometheus.yml`](configs/prometheus/prometheus.yml) — adds `blackbox-http` and `blackbox-dns` probe jobs

### Why

* **Multi-target exporter pattern (`relabel_configs`):** unlike host or
  container exporters that report metrics about themselves on `/metrics`,
  `blackbox_exporter` probes remote endpoints on demand at
  `/probe?target=<endpoint>&module=<name>`. The `relabel_configs` chain copies
  each static target (`https://traefik`, `dns:53`) from `__address__` into
  `__param_target`, copies `__param_target` into `instance` so probe metrics
  carry the probed service name instead of the exporter's hostname, and
  rewrites `__address__` to `blackbox-exporter:9115` so Prometheus sends the HTTP
  scrape request to the exporter container.
* **Reloading configuration via container restart:** Prometheus is started without
  `--web.enable-lifecycle`, and adding jobs to the bind-mounted
  `prometheus.yml` does not modify the `prometheus` service definition in
  `docker-compose.yml`. Restarting `prometheus` loads the new scrape jobs cleanly
  while preserving the running container's TSDB.

### Verification

Wait ~15–20 seconds after restarting `prometheus` so at least one scrape cycle
completes, then run direct probe checks and Prometheus API queries:

```bash
# Direct probe check — HTTPS via Traefik
docker compose exec -T blackbox-exporter wget -qO- 'http://localhost:9115/probe?target=https://traefik&module=http_2xx_insecure' \
  | grep -E '^probe_(success|duration_seconds|ssl_earliest_cert_expiry)'
# → probe_duration_seconds 0.0...
# → probe_ssl_earliest_cert_expiry 1.7...e+09
# → probe_success 1

# Direct probe check — DNS SOA for lab.local
docker compose exec -T blackbox-exporter wget -qO- 'http://localhost:9115/probe?target=dns:53&module=dns_lab_soa' \
  | grep -E '^probe_(success|duration_seconds)'
# → probe_duration_seconds 0.0...
# → probe_success 1

# Confirm all scrape targets (including blackbox-http and blackbox-dns) report "up"
docker compose exec -T prometheus wget -qO- http://localhost:9090/api/v1/targets \
  | python3 -c "import sys,json; [print(t['labels']['job'], t['labels']['host'], t['health']) for t in json.load(sys.stdin)['data']['activeTargets']]"
# → blackbox-dns lab-docker up
# → blackbox-http lab-docker up
# → cadvisor lab-docker up
# → node lab-docker up
# → prometheus lab-docker up

# Confirm probe_success == 1 for both blackbox jobs via Prometheus HTTP API
docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=probe_success' \
  | python3 -c "import sys,json; [print(r['metric']['job'], r['metric']['instance'], r['value'][1]) for r in json.load(sys.stdin)['data']['result']]"
# → blackbox-dns dns:53 1
# → blackbox-http https://traefik 1

# Inspect TLS leaf certificate expiration timestamp (Unix epoch seconds)
docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=probe_ssl_earliest_cert_expiry' \
  | python3 -c "import sys,json; [print(r['metric']['instance'], r['value'][1]) for r in json.load(sys.stdin)['data']['result']]"
# → https://traefik <unix-timestamp>

# Inspect probe duration (seconds) across both jobs
docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=probe_duration_seconds' \
  | python3 -c "import sys,json; [print(r['metric']['job'], r['metric']['instance'], r['value'][1]) for r in json.load(sys.stdin)['data']['result']]"
# → blackbox-dns dns:53 <seconds>
# → blackbox-http https://traefik <seconds>
```

---

## Step 8 — Traefik Metrics

### What was done

Enable Prometheus metrics exposure on Traefik's internal `dashboard` entrypoint
(`:8080`) in the reverse-proxy static configuration, restart `traefik` so it
loads the updated static file, add the `traefik` scrape job (`traefik:8080/metrics`,
tagged with `host: lab-docker`) to `configs/prometheus/prometheus.yml`, validate
the Prometheus configuration with `promtool`, and reload `prometheus`.

```yaml
# Added to reverse-proxy static config (traefik.yml)
metrics:
  prometheus:
    entryPoint: dashboard
    addEntryPointsLabels: true
    addRoutersLabels: true
    addServicesLabels: true
```

> **Static configuration requires a Traefik restart:** unlike `dynamic.yml` and
> Docker labels, Traefik reads `traefik.yml` only once at container startup.
> Restarting `traefik` causes a brief connection interruption on ports `80` and
> `443` while the proxy reloads its static configuration.

```bash
# 1. Validate reverse-proxy config syntax and restart Traefik from its module directory
docker compose -f ../../reverse-proxy/docker/docker-compose.yml restart traefik

# 2. Validate updated Prometheus config and restart Prometheus from modules/monitoring/docker/
docker compose run --rm --no-deps --entrypoint promtool prometheus check config /etc/prometheus/prometheus.yml
# → Checking /etc/prometheus/prometheus.yml
# →  SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax

docker compose restart prometheus
```

📄 [`../../reverse-proxy/docker/configs/traefik/traefik.yml`](../../reverse-proxy/docker/configs/traefik/traefik.yml) — enables `metrics.prometheus` on `entryPoint: dashboard`
📄 [`configs/prometheus/prometheus.yml`](configs/prometheus/prometheus.yml) — adds the `traefik` scrape job (`traefik:8080/metrics`)

### Why

* **Reusing the internal `dashboard` entrypoint (`:8080`):** in
  `reverse-proxy`, `traefik.yml` already binds `dashboard` to `:8080` without
  publishing port `8080` on the host. Attaching `metrics.prometheus` to
  `dashboard` exposes `/metrics` exclusively inside `proxy-net` — Prometheus
  can scrape `traefik:8080/metrics` directly, while external callers cannot reach
  raw metrics telemetry without tunneling or altering ports.
* **EntryPoint, router, and service labels:** enabling `addEntryPointsLabels`,
  `addRoutersLabels`, and `addServicesLabels` attaches routing context to every
  counter and histogram (`traefik_service_requests_total`,
  `traefik_service_request_duration_seconds_bucket`), allowing dashboards to
  break down traffic, 5xx errors, and p95 latency per backend service (`web-server`,
  `grafana`) rather than only aggregate totals.
* **Plan B — rollback if Traefik fails:** this change is isolated in a single,
  additive commit on `traefik.yml` with no route, TLS, middleware, or Compose
  port changes. If `traefik` fails to start or becomes unhealthy after restart,
  revert the commit (`git revert <commit-hash>`) or remove the `metrics:` block
  from `traefik.yml`, restart `traefik` to restore ingress immediately, remove
  the `traefik` job from `configs/prometheus/prometheus.yml`, and continue with
  synthetic `blackbox_exporter` probes only.

### Verification

Wait ~15–20 seconds after restarting `prometheus`, then verify `/metrics` inside
`proxy-net`, Prometheus target health, and that existing Traefik routers remain
unaffected:

```bash
# Confirm /metrics responds from inside proxy-net (using the prometheus container)
docker compose exec -T prometheus wget -qO- http://traefik:8080/metrics | grep -E '^traefik_' | head -n 5
# → traefik_config_last_reload_success 1
# → ...

# Confirm traefik target reports health "up" alongside the existing jobs
docker compose exec -T prometheus wget -qO- http://localhost:9090/api/v1/targets \
  | python3 -c "import sys,json; [print(t['labels']['job'], t['labels']['host'], t['health']) for t in json.load(sys.stdin)['data']['activeTargets']]"
# → blackbox-dns lab-docker up
# → blackbox-http lab-docker up
# → cadvisor lab-docker up
# → node lab-docker up
# → prometheus lab-docker up
# → traefik lab-docker up

# Confirm existing Traefik routers continue serving normally
curl -sk -o /dev/null -w "%{http_code}\n" --resolve web.localhost:443:127.0.0.1 https://web.localhost/
# → 200

curl -sk -o /dev/null -w "%{http_code}\n" --resolve traefik.localhost:443:127.0.0.1 https://traefik.localhost/dashboard/
# → 401
```

---

## Step 9 — Grafana Service and Provisioning

### What was done

Add the `grafana` service (`grafana/grafana:13.3.0`) with file-based provisioning
for both the Prometheus datasource and the `Lab` dashboard provider, tighten
`blackbox-exporter` with `user: "65534:65534"`, and supply Grafana's admin
password through an untracked `.env` file copied from `.env.example`.

> **Never commit `.env` to version control:** `modules/monitoring/docker/.env` is
> listed in `.gitignore`. Always create `.env` locally from `.env.example` and
> replace the placeholder password (`change-me`) before starting the stack.

```bash
# Create the local .env file and set a strong admin password
cp .env.example .env
# Edit .env → GRAFANA_ADMIN_PASSWORD=<strong-password>

# Validate the dev Compose file once .env exists
docker compose config --quiet
# → (no output — exit code 0 confirms valid Compose syntax and resolved env vars)

# Recreate blackbox-exporter (non-root user) and start Grafana
docker compose up -d blackbox-exporter grafana
```

📄 [`docker-compose.yml`](docker-compose.yml) — adds `grafana` and sets `user: "65534:65534"` on `blackbox-exporter`
📄 [`.env.example`](.env.example) — template for `GRAFANA_ADMIN_PASSWORD`
📄 [`configs/grafana/provisioning/datasources/prometheus.yml`](configs/grafana/provisioning/datasources/prometheus.yml) — registers `Prometheus` (`uid: prometheus`, `http://prometheus:9090`, default datasource)
📄 [`configs/grafana/provisioning/dashboards/lab.yml`](configs/grafana/provisioning/dashboards/lab.yml) — configures the file dashboard provider reading `/etc/grafana/dashboards`

### Why

* **Why `GF_AUTH_BASIC_ENABLED=false` is required behind Traefik BasicAuth:**
  Grafana routes through Traefik's `auth-dashboard@file` middleware before
  requests reach port `3000`. HTTP BasicAuth works by forwarding the
  `Authorization: Basic <base64>` header to the upstream backend. Because
  Grafana enables HTTP BasicAuth by default, it would inspect that forwarded
  Traefik `Authorization` header against Grafana's own user database and reject
  requests with `401 Unauthorized` whenever Traefik credentials differ from
  Grafana credentials. Setting `GF_AUTH_BASIC_ENABLED=false` makes Grafana
  ignore the edge `Authorization` header while keeping its own web session
  login (`/login`) active as a second authentication layer.
* **Read-only root filesystem with `tmpfs` state in dev:** `grafana` runs as
  its image user (`uid=472`) with `read_only: true`, `cap_drop: [ALL]`, and
  `no-new-privileges:true`. Because Grafana writes its SQLite database
  (`grafana.db`), plugin cache, and runtime temp files at startup, `/var/lib/grafana`
  (`uid=472,gid=472`) and `/tmp` are mounted as `tmpfs`. In dev this keeps the
  container stateless across restarts (`docker compose down` clears runtime state),
  while `read_only: true` protects the container rootfs cleanly (no relaxation is
  required — the built-in Prometheus datasource works without executing external
  plugin binaries under `noexec` `tmpfs`).
* **Fail-fast credential interpolation:**
  `GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:?set GRAFANA_ADMIN_PASSWORD in .env}`
  stops Compose immediately if `.env` or the variable is missing, instead of
  silently booting Grafana with a known fallback or empty password.
* **Hardening `blackbox-exporter` to non-root `65534:65534`:** `prom/blackbox-exporter`
  does not specify a default `USER` in its image manifest (`uid=0`), yet it only
  opens unprivileged client sockets for HTTP and DNS probes and listens on
  `:9115`. Running explicitly as `65534:65534` (`nobody`) removes root execution
  without affecting probe functionality.
* **Provisioning as code (`:ro`):** mounting `prometheus.yml` (datasource) and
  `lab.yml` (dashboard provider) read-only ensures the Prometheus datasource UID
  (`prometheus`) and the `Lab Overview` dashboard load automatically on cold
  start without click-ops setup.

### Verification

```bash
docker compose ps blackbox-exporter grafana
# → NAME                IMAGE                             STATUS
# → blackbox-exporter   prom/blackbox-exporter:v0.29.1    Up X seconds
# → grafana             grafana/grafana:13.3.0            Up X seconds

# Confirm Grafana started cleanly and provisioned the Prometheus datasource and Lab folder
docker compose logs grafana | grep -E "HTTP Server Listen|Provisioning|HTTP Server"
# → logger=http.server msg="HTTP Server Listen" address=[::]:3000 ...

# Confirm internal Grafana health endpoint before testing ingress
docker compose exec -T grafana wget -qO- http://localhost:3000/api/health
# → {
# →   "database": "ok",
# →   "version": "13.3.0"
# → }
```

---

## Step 10 — Lab Overview Dashboard

### What was done

Provide the custom Grafana dashboard JSON (`configs/grafana/dashboards/lab-overview.json`,
`uid: lab-overview`, title `Lab Overview`, `30s` auto-refresh, linked to the
provisioned `prometheus` datasource) mounted read-only at
`/etc/grafana/dashboards/lab-overview.json`. Because Step 9 already mounted this
file and started `grafana`, no extra deploy command is needed unless the JSON
was edited afterward (`docker compose restart grafana` reloads on demand, or the
provider polls every `30s`).

📄 [`configs/grafana/dashboards/lab-overview.json`](configs/grafana/dashboards/lab-overview.json) — `Lab Overview` dashboard organized into 5 rows and 14 panels:

| Group | Panel | PromQL Expression |
|---|---|---|
| Status | `Targets Up (%)` | `sum(up) / count(up)` |
| Status | `Blackbox Probes OK` | `min(probe_success)` |
| Host | `Host CPU Usage (%)` | `100 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100` |
| Host | `Host Memory Usage (%)` | `100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)` |
| Host | `Host Root Disk Usage (%)` | `100 * (1 - node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs\|overlay\|squashfs"} / node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs\|overlay\|squashfs"})` |
| Host | `Host Network Traffic (RX / TX)` | `rate(node_network_receive_bytes_total{device!="lo"}[5m])` / `rate(node_network_transmit_bytes_total{device!="lo"}[5m])` |
| Containers | `Container CPU Usage (cores)` | `sum by (name) (rate(container_cpu_usage_seconds_total{name!=""}[5m]))` |
| Containers | `Container Memory Working Set` | `container_memory_working_set_bytes{name!=""}` |
| Traefik | `Traefik Request Rate` | `sum by (service) (rate(traefik_service_requests_total[5m]))` |
| Traefik | `Traefik 5xx Error Rate` | `sum by (service) (rate(traefik_service_requests_total{code=~"5.."}[5m]))` |
| Traefik | `Traefik p95 Latency` | `histogram_quantile(0.95, sum by (le, service) (rate(traefik_service_request_duration_seconds_bucket[5m])))` |
| Synthetic Probes | `Probe Status (probe_success)` | `probe_success` |
| Synthetic Probes | `Probe Duration` | `probe_duration_seconds` |
| Synthetic Probes | `TLS Certificate Expiry (days)` | `(probe_ssl_earliest_cert_expiry - time()) / 86400` |

### Why

* **Versioned dashboard JSON vs community IDs:** maintaining a custom JSON file
  tailored to the exact job labels (`node`, `cadvisor`, `traefik`,
  `blackbox-http`, `blackbox-dns`) avoids drift from external community dashboards,
  works offline with zero external downloads, and binds every panel deterministically
  to `uid: prometheus`.
* **Why `stepAfter` interpolation on `probe_success`:** binary probe health (`1`
  up, `0` down) transitions instantaneously between scrape intervals; step-line
  rendering shows exact outage intervals without diagonal ramps.
* **Why `Traefik` series appear only after routed requests:** Traefik initializes
  service counter and duration bucket time series lazily when a router handles its
  first request (`traefik_service_requests_total`). Generating at least one HTTPS
  request (e.g., to `web.localhost` or `grafana.localhost`) populates all three
  Traefik panels.

### Verification

Confirm that Prometheus holds active series for all panel groups (wait ~1–2
minutes after startup so `rate(...[5m])` and container metrics settle):

```bash
# 1. Validate dashboard JSON syntax locally
python3 -m json.tool configs/grafana/dashboards/lab-overview.json > /dev/null
# → (no output — exit code 0 confirms valid JSON)

# 2. Confirm Grafana did not report provisioning errors
docker compose logs grafana | grep -iE "failed to load|provision.*error"
# → (no output — dashboard provisioned cleanly)

# 3. Verify underlying Prometheus queries return non-empty results
docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=sum(up)/count(up)' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['result'][0]['value'][1])"
# → 1

docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=min(probe_success)' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['result'][0]['value'][1])"
# → 1
```

---

## Step 11 — Exposure Through Traefik

### What was done

Verify HTTPS ingress to Grafana through Traefik (`https://grafana.localhost`),
confirming that HTTP redirects to HTTPS (`301`), unauthenticated HTTPS requests
are blocked by Traefik's `auth-dashboard@file` middleware (`401`), and the
provisioned datasource and `Lab Overview` dashboard are reachable through Grafana
once authenticated.

📄 [`docker-compose.yml`](docker-compose.yml) — Traefik labels on `grafana` (`Host(\`grafana.localhost\`)`, `websecure`, `tls=true`, `auth-dashboard@file`, port `3000`)

### Why

* **Why Grafana publishes no host ports (`ports:` omitted):** publishing port
  `3000` directly on the Docker host would expose plain HTTP Grafana traffic,
  bypassing Traefik's TLS termination and `auth-dashboard@file` BasicAuth
  middleware. Attaching Grafana exclusively to `proxy-net` lets Traefik resolve
  `grafana:3000` internally while exposing only port `443` through the reverse
  proxy.
* **Two-stage authentication in `curl` checks:** because Step 9 disabled
  Grafana HTTP BasicAuth (`GF_AUTH_BASIC_ENABLED=false`), passing `-u admin:...`
  satisfies Traefik's `auth-dashboard@file` middleware (`401` → `200` on public
  or health endpoints like `/api/health`), whereas authenticated Grafana API
  endpoints (`/api/search`) require a Grafana session cookie obtained via
  `POST /login`. Using `-k` skips CA chain verification for Traefik's
  self-signed lab certificate (`CN=*.localhost`), and `--resolve` maps
  `grafana.localhost` to `127.0.0.1` without editing `/etc/hosts`.

### Verification

```bash
# 1. Confirm Traefik discovered the grafana router
curl -sk --resolve traefik.localhost:443:127.0.0.1 \
  -u 'admin:<traefik-password>' \
  https://traefik.localhost/api/http/routers \
  | python3 -m json.tool | grep '"grafana@docker"'
# → "grafana@docker"

# 2. HTTP redirects cleanly to HTTPS
curl -s -o /dev/null -w "%{http_code}\n" --resolve grafana.localhost:80:127.0.0.1 http://grafana.localhost/
# → 301

# 3. HTTPS without Traefik BasicAuth credentials is rejected (401)
curl -sk -o /dev/null -w "%{http_code}\n" --resolve grafana.localhost:443:127.0.0.1 https://grafana.localhost/api/health
# → 401

# 4. HTTPS with Traefik BasicAuth credentials reaches /api/health
curl -sk --resolve grafana.localhost:443:127.0.0.1 \
  -u 'admin:<traefik-password>' \
  https://grafana.localhost/api/health
# → {
# →   "database": "ok",
# →   "version": "13.3.0"
# → }

# 5. Sign in to Grafana via /login (cookie jar) and verify the Lab Overview dashboard and Prometheus datasource
curl -sk --resolve grafana.localhost:443:127.0.0.1 \
  -u 'admin:<traefik-password>' \
  -c /tmp/grafana.cookies \
  -H 'Content-Type: application/json' \
  -d '{"user":"admin","password":"<grafana-password>"}' \
  https://grafana.localhost/login
# → {"message":"Logged in"}

curl -sk --resolve grafana.localhost:443:127.0.0.1 \
  -u 'admin:<traefik-password>' \
  -b /tmp/grafana.cookies \
  'https://grafana.localhost/api/search?query=Lab%20Overview' \
  | python3 -c "import sys,json; print([(d['uid'], d['title'], d['folderTitle']) for d in json.load(sys.stdin)])"
# → [('lab-overview', 'Lab Overview', 'Lab')]

curl -sk --resolve grafana.localhost:443:127.0.0.1 \
  -u 'admin:<traefik-password>' \
  -b /tmp/grafana.cookies \
  https://grafana.localhost/api/datasources/uid/prometheus/health
# → {"status":"OK","message":"Successfully queried the Prometheus API."}

rm -f /tmp/grafana.cookies
```

---

## Step 12 — Production Compose

### What was done

Deploy the monitoring stack using `docker-compose.prod.yml` (`docker compose -f
docker-compose.prod.yml up -d`), which keeps the same five images, Traefik
labels, and container hardening posture as dev while switching to named volumes
(`prometheus-data` and `grafana-data`), `restart: unless-stopped`, native `wget`
healthchecks on all five services, explicit memory limits, and a `1GB` TSDB
storage ceiling alongside `15d` retention.

| Operational Setting | Dev (`docker-compose.yml`) | Prod (`docker-compose.prod.yml`) |
|---|---|---|
| Restart policy | `"no"` | `unless-stopped` |
| Prometheus storage | Ephemeral container volume | Named volume `prometheus-data` (`/prometheus`) |
| Grafana storage | `tmpfs` `/var/lib/grafana` (stateless) | Named volume `grafana-data` (`/var/lib/grafana`) |
| TSDB retention limits | `15d` | `15d` and `--storage.tsdb.retention.size=1GB` |
| Healthchecks | None declared in Compose | `wget` HTTP checks on all 5 containers |
| Memory limits | Unbounded | `prometheus: 256m`, `grafana: 192m`, `cadvisor: 128m`, `node-exporter: 64m`, `blackbox-exporter: 64m` |

> **Prerequisites before running production Compose:**
> 1. Ensure `reverse-proxy` is already running from its production Compose
>    (`modules/reverse-proxy/docker/docker-compose.prod.yml`) with metrics
>    enabled in `traefik.yml`, and `dns` is attached to `proxy-net`.
> 2. Ensure `modules/monitoring/docker/.env` exists with a production
>    `GRAFANA_ADMIN_PASSWORD`.
> 3. Stop the dev stack first (`docker compose down`) if it is running on the
>    same host, because both Compose files use fixed `container_name` values.

```bash
# Validate production Compose syntax and env interpolation
docker compose -f docker-compose.prod.yml config --quiet
# → (no output — exit code 0)

# Stop dev containers if active, then start production containers
docker compose down
docker compose -f docker-compose.prod.yml up -d
```

📄 [`docker-compose.prod.yml`](docker-compose.prod.yml) — production Compose definition with named volumes, healthchecks, memory limits, and `1GB` TSDB cap

### Why

* **Named volumes instead of `tmpfs` / ephemeral container storage:** in prod,
  Prometheus TSDB segments must survive container recreation or image updates
  (`prometheus-data:/prometheus`), and Grafana's SQLite database
  (`grafana-data:/var/lib/grafana`) must persist admin password changes, session
  state, and user preferences across restarts. Removing `tmpfs` on
  `/var/lib/grafana` lets Docker initialize and persist the named volume with
  Grafana's container ownership (`uid=472`) while `/tmp` stays `tmpfs` under
  `read_only: true`.
* **Healthchecks across all five containers:** each official image ships `wget`,
  allowing lightweight probes (`/-/healthy`, `/api/health`, `/healthz`, `/`)
  with `30s` intervals. Container status in `docker compose ps` surfaces silent
  startup or runtime stalls (`unhealthy`) without installing extra binaries or
  publishing ports.
* **Bounded TSDB and per-container memory limits:** adding
  `--storage.tsdb.retention.size=1GB` alongside `15d` protects small EC2 root
  disks (`t4g.micro`) against sudden cardinality spikes, while
  `deploy.resources.limits.memory` (`704m` combined ceiling across the five
  containers) prevents a single exporter or query spike from triggering a
  host-wide OOM kill.

### Production considerations

This laboratory Compose file intentionally optimizes for a single-host `t4g.micro`
footprint and zero external dependencies. In a real production environment, six
architectural changes apply:

1. **Retention and remote storage:** a single host volume with `15d` / `1GB`
   limits loses metrics if the instance or EBS volume fails. Production stacks
   pair short local TSDB retention with `remote_write` into long-term object
   storage backends (Thanos, Grafana Mimir, Cortex, or Amazon Managed
   Prometheus).
2. **Alerting and routing:** Alertmanager is excluded here; production requires
   recording/alerting rules in Prometheus routed through redundant Alertmanager
   instances (grouping, deduplication, silences, and receivers such as Slack,
   PagerDuty, or SNS), including meta-monitoring (`Watchdog` / target-down alerts).
3. **Centralized authentication and secrets:** static credentials in `.env` and
   a shared Traefik bcrypt hash do not scale cleanly or support auditability.
   Production delegates authentication to an identity provider (OIDC / OAuth2 /
   SAML) with RBAC teams and fetches secrets from a vault or cloud secret
   manager with automatic rotation.
4. **Eliminating host Docker socket exposure and privileged `cAdvisor`:**
   mounting `/var/run/docker.sock` directly (even `:ro` in Traefik) and running
   `cAdvisor` with `privileged: true` increases blast radius if a container is
   compromised. Production restricts Docker socket access via a minimal socket
   proxy, collects node/container stats from kubelet-managed cAdvisor or
   scoped eBPF/daemon agents without `privileged: true`, and avoids host
   `/dev/kmsg` mounts.
5. **Realistic resource sizing and host isolation:** `256m` for Prometheus and
   sharing a 1 GiB host with production workloads causes query throttling and
   OOM pressure as active series grow. Production runs observability on dedicated
   compute sized by `prometheus_tsdb_head_series` and sets both memory requests
   and limits so observability cannot fail alongside the workload it monitors.
6. **External Grafana database for high availability:** file-backed SQLite inside
   a Docker volume binds Grafana to one node and prevents horizontal replicas.
   Production uses a managed PostgreSQL database (such as RDS Multi-AZ) so
   multiple stateless Grafana replicas can run behind the load balancer.

### Verification

```bash
# Confirm all 5 services reach healthy status (wait ~20–30s after up -d)
docker compose -f docker-compose.prod.yml ps
# → NAME                IMAGE                             STATUS
# → blackbox-exporter   prom/blackbox-exporter:v0.29.1    Up X seconds (healthy)
# → cadvisor            ghcr.io/google/cadvisor:v0.60.6   Up X seconds (healthy)
# → grafana             grafana/grafana:13.3.0            Up X seconds (healthy)
# → node-exporter       prom/node-exporter:v1.12.1        Up X seconds (healthy)
# → prometheus          prom/prometheus:v3.16.0           Up X seconds (healthy)

# Confirm both named volumes were created
docker volume ls | grep -E 'prometheus-data|grafana-data'
# → local     <project>_grafana-data
# → local     <project>_prometheus-data

# Test persistence across container replacement (do NOT pass -v)
docker compose -f docker-compose.prod.yml down
docker compose -f docker-compose.prod.yml up -d
sleep 20

# Confirm pre-restart TSDB samples remain queryable in Prometheus (>1 sample over 15m)
docker compose -f docker-compose.prod.yml exec -T prometheus wget -qO- \
  'http://localhost:9090/api/v1/query?query=count_over_time(up{job="prometheus"}[15m])' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['result'][0]['value'][1])"
# → <sample-count-preserved-across-restart>

# Confirm grafana-data preserved Grafana's internal health and state
docker compose -f docker-compose.prod.yml exec -T grafana wget -qO- http://localhost:3000/api/health
# → {"database":"ok","version":"13.3.0"}
```

---

## Step 13 — End-to-End Verification and Fault Injection

### What was done

Verify the complete observability loop end to end — all six Prometheus targets
`up`, both synthetic probes reporting `1`, live series populating the `Lab
Overview` dashboard in Grafana — then perform controlled fault injection by
stopping the `dns` container to confirm that `blackbox_exporter` and Grafana
surface the outage within two scrape cycles (`~30s`) and recover automatically
after `docker start dns`, followed by stack cleanup.

### Why

Monitoring only proves its value when failure changes telemetry predictably.
Stopping `dns` tests the full detection chain: Docker networking drops `:53`,
`blackbox-exporter` fails its UDP `SOA` lookup (`dns_lab_soa`), Prometheus
records `probe_success{job="blackbox-dns"} == 0` within one to two `15s` scrape
intervals, and Grafana's **Blackbox Probes OK** (`min(probe_success)`) and
**Probe Status (`probe_success`)** panels flip to `FAIL` / `DOWN` without manual
intervention. Meanwhile, `probe_success{job="blackbox-http"}` stays `1`, proving
probe isolation across independent targets.

### Verification

Run these commands against whichever Compose stack you have active (add `-f
docker-compose.prod.yml` if validating production):

```bash
# 1. Confirm all 6 targets report health "up"
docker compose exec -T prometheus wget -qO- http://localhost:9090/api/v1/targets \
  | python3 -c "import sys,json; [print(t['labels']['job'], t['labels']['host'], t['health']) for t in json.load(sys.stdin)['data']['activeTargets']]"
# → blackbox-dns lab-docker up
# → blackbox-http lab-docker up
# → cadvisor lab-docker up
# → node lab-docker up
# → prometheus lab-docker up
# → traefik lab-docker up

# 2. Confirm all synthetic probes report probe_success == 1
docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=probe_success' \
  | python3 -c "import sys,json; [print(r['metric']['job'], r['metric']['instance'], r['value'][1]) for r in json.load(sys.stdin)['data']['result']]"
# → blackbox-dns dns:53 1
# → blackbox-http https://traefik 1

# 3. Generate one HTTPS request so Traefik lazily initializes router/service metrics, then open
#    https://grafana.localhost (dashboard: Lab / Lab Overview) in your browser and confirm all 14 panels show data
curl -sk -o /dev/null -w "%{http_code}\n" --resolve web.localhost:443:127.0.0.1 https://web.localhost/
# → 200

# 4. Fault injection: stop the dns container and wait two scrape cycles (~35s)
docker stop dns
sleep 35

# Confirm blackbox-dns transitions to 0 while blackbox-http stays 1
docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=probe_success' \
  | python3 -c "import sys,json; [print(r['metric']['job'], r['metric']['instance'], r['value'][1]) for r in json.load(sys.stdin)['data']['result']]"
# → blackbox-dns dns:53 0
# → blackbox-http https://traefik 1

# Confirm Grafana's global probe summary (min(probe_success)) reflects failure (0 / FAIL)
docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=min(probe_success)' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['result'][0]['value'][1])"
# → 0
# In Grafana → Lab Overview, "Blackbox Probes OK" turns red (FAIL) and "Probe Status (probe_success)" drops dns:53 to DOWN (0)

# 5. Restore dns and wait two scrape cycles (~35s)
docker start dns
sleep 35

docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=probe_success' \
  | python3 -c "import sys,json; [print(r['metric']['job'], r['metric']['instance'], r['value'][1]) for r in json.load(sys.stdin)['data']['result']]"
# → blackbox-dns dns:53 1
# → blackbox-http https://traefik 1
```

#### Cleanup

When finished testing, stop the monitoring stack cleanly:

```bash
# Dev stack: removes containers; discards ephemeral TSDB data in /prometheus and tmpfs state in /var/lib/grafana
docker compose down

# Prod stack: stops containers while keeping prometheus-data and grafana-data volumes intact
docker compose -f docker-compose.prod.yml down
```

> **What is lost on `docker compose down` in dev:** because dev mounts no
> persistent volume on `/prometheus` and backs `/var/lib/grafana` with `tmpfs`,
> `docker compose down` permanently wipes all collected Prometheus time series
> and Grafana runtime state (active sessions and any UI edits not saved in
> provisioning). Versioned files under `configs/` and your local `.env` remain
> intact on disk; only running `down -v` on `docker-compose.prod.yml` deletes
> production volumes.
