# Monitoring — containerize-your-infra

**Docker Engine · prom/prometheus:v3.16.0 · prom/node-exporter:v1.12.1 · ghcr.io/google/cadvisor:v0.60.6**

---

## Introduction

This document covers the deployment of the pull-based observability stack for
containerized infrastructure monitoring: `node_exporter` for host telemetry,
`cAdvisor` for per-container resource usage, `blackbox_exporter` for synthetic
HTTP/DNS availability probes, and `Prometheus` as the time-series scraper and
query engine.

In `build-your-infra`, host metrics were collected by an OS-level
`prometheus-node-exporter` package over a WireGuard tunnel. Here, all
components run as containers on the shared `proxy-net` Docker bridge network and
communicate via Docker's embedded DNS without publishing any metrics ports to
the host.

> **Prerequisite — Reverse Proxy (`proxy-net`):** the `reverse-proxy` module
> must already be running (`modules/reverse-proxy/docker/`) so the external
> Docker network `proxy-net` (`172.21.0.0/24`) exists before running
> `docker compose up -d` in this module.

> **Config files in `configs/prometheus/`** contain only the configuration added
> by this module. Referenced paths sit relative to `modules/monitoring/docker/`.

---

## Environment

| Parameter | Value |
|---|---|
| Prometheus image | `prom/prometheus:v3.16.0` |
| Node Exporter image | `prom/node-exporter:v1.12.1` |
| cAdvisor image | `ghcr.io/google/cadvisor:v0.60.6` |
| Blackbox Exporter image | `prom/blackbox-exporter:v0.29.1` |
| Network | External `proxy-net` (`172.21.0.0/24`) |
| Published ports | None — internal `proxy-net` endpoints only |
| Scrape interval | `15s` (`prometheus`, `node`, `cadvisor`) |
| TSDB retention | `15d` (`--storage.tsdb.retention.time=15d`) |
| TSDB persistence (dev) | None — ephemeral container storage, lost on `down` |
| Config mount | Bind mount `:ro` — `configs/prometheus/prometheus.yml` |
| Restart policy (dev) | `"no"` |

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
