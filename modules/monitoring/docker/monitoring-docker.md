# Monitoring — containerize-your-infra

**Docker Engine · prom/prometheus:v3.16.0 · grafana/grafana:13.3.0 · prom/node-exporter:v1.12.1 · ghcr.io/google/cadvisor:v0.60.6 · prom/blackbox-exporter:v0.29.1**

---

## Introduction

This document deploys the pull-based observability stack on the `proxy-net`
bridge network: `node_exporter` (host telemetry), `cAdvisor` (per-container
metrics), `blackbox_exporter` (synthetic HTTPS and DNS probes), Traefik `/metrics`,
`Prometheus` (scraper and TSDB), and `Grafana` (provisioned datasource and
`Lab Overview` dashboard) exposed exclusively via Traefik HTTPS.

In `build-your-infra`, host metrics ran via OS packages over WireGuard. Here,
every component runs as a container resolving peers via Docker DNS with no
Prometheus, exporter, or direct Grafana ports published on the host.

> **Config files in `configs/`** (`configs/prometheus/`, `configs/blackbox/`, and
> `configs/grafana/`) contain only module configuration relative to
> `modules/monitoring/docker/`.

---

## Environment

| Parameter | Value |
|---|---|
| Images | `prom/prometheus:v3.16.0` · `grafana/grafana:13.3.0` · `prom/node-exporter:v1.12.1` · `ghcr.io/google/cadvisor:v0.60.6` · `prom/blackbox-exporter:v0.29.1` |
| Network | External `proxy-net` (`172.21.0.0/24`) |
| Published ports | None — internal `proxy-net` endpoints only; Grafana via Traefik (`https://grafana.localhost:443`) |
| Persistence | Dev: ephemeral TSDB + `tmpfs` `/var/lib/grafana` · Prod: named volumes `prometheus-data`, `grafana-data` |
| Credentials | `.env` copied from `.env.example` (gitignored — holds `GRAFANA_ADMIN_PASSWORD`) |
| TSDB retention | `15d` in dev (`--storage.tsdb.retention.time=15d`) · `15d` + `1GB` cap in prod (`--storage.tsdb.retention.size=1GB`) |

---

## Step 1 — Prerequisites and Environment

### What was done

Verify that `proxy-net` exists (created by `reverse-proxy`), enter
`modules/monitoring/docker/`, and create `.env` from `.env.example` with a
strong `GRAFANA_ADMIN_PASSWORD` before validating the Compose file.

> **`.env` rules:** `modules/monitoring/docker/.env` is gitignored. `docker compose config`
> fails unless `GRAFANA_ADMIN_PASSWORD` is set (`grep GRAFANA_ADMIN_PASSWORD .env` to recall it).
> Avoid `$` in the `.env` password (Docker Compose interpolates `$`; escape literal `$` as `$$`).

```bash
cd modules/monitoring/docker/

docker network inspect proxy-net --format '{{.Name}} ({{.Driver}})'
# → proxy-net (bridge)

cp .env.example .env
# Edit .env → GRAFANA_ADMIN_PASSWORD=<strong-password>
```

📄 [`docker-compose.yml`](docker-compose.yml) — service definitions, hardening flags, and external `proxy-net`
📄 [`.env.example`](.env.example) — template for `GRAFANA_ADMIN_PASSWORD`

### Why

* **External `proxy-net` network:** attaching containers to `proxy-net` reuses
  Traefik's network and Docker DNS without publishing ports on the host.
* **Fail-fast `.env` validation:** `${GRAFANA_ADMIN_PASSWORD:?set GRAFANA_ADMIN_PASSWORD in .env}`
  aborts `docker compose` immediately instead of booting Grafana with a default password.
* **Credentials out of git:** copying `.env.example` keeps secrets local and
  prevents accidental exposure in commits.

### Verification

```bash
docker compose config --quiet
# → (no output — exit code 0 confirms valid Compose syntax and .env interpolation)
```

---

## Step 2 — Host and Container Metrics

### What was done

Deploy `node-exporter` (`prom/node-exporter:v1.12.1`) and `cadvisor`
(`ghcr.io/google/cadvisor:v0.60.6`) on `proxy-net` with read-only host mounts
to expose kernel/host telemetry (`:9100`) and per-container resource metrics (`:8080`).

```bash
docker compose up -d node-exporter cadvisor
```

📄 [`docker-compose.yml`](docker-compose.yml) — `node-exporter` and `cadvisor` service definitions

### Why

* **Host visibility vs. bridge isolation:** `pid: host` and `/:/host:ro,rslave`
  expose host counters to `node-exporter`; keeping it on `proxy-net` means `node_network_*` reflects container `eth0` instead of physical NICs.
* **OrbStack runtime note:** on macOS OrbStack, host metrics report the Linux VM
  and `cAdvisor` may omit some container labels; on native Linux (EC2), host metrics reflect the instance directly.
* **Justified `cadvisor` `privileged: true`:** required to read cgroups, block I/O,
  and `/dev/kmsg`; mitigated with `read_only: true`, `no-new-privileges:true`, and `:ro` host mounts.
* **`node-exporter` hardening:** runs as unprivileged `USER nobody` with
  `cap_drop: [ALL]`, `read_only: true`, and `no-new-privileges:true`.

### Verification

```bash
docker compose ps node-exporter cadvisor
# → NAME            IMAGE                             STATUS
# → cadvisor        ghcr.io/google/cadvisor:v0.60.6   Up X seconds (healthy)
# → node-exporter   prom/node-exporter:v1.12.1        Up X seconds

docker compose exec -T node-exporter wget -qO- http://localhost:9100/metrics | head -n 5
# → # HELP go_gc_duration_seconds ...

docker compose exec -T cadvisor wget -qO- http://localhost:8080/healthz
# → ok

docker compose exec -T cadvisor wget -qO- http://localhost:8080/metrics | head -n 5
# → # HELP cadvisor_version_info ...
```

---

## Step 3 — Prometheus

### What was done

Validate `configs/prometheus/prometheus.yml` with `promtool`, then start
`prometheus` (`prom/prometheus:v3.16.0`) configured with a `15s` scrape interval,
`15d` dev retention, and scrape jobs tagged `host: lab-docker`.

```bash
docker compose run --rm --no-deps --entrypoint promtool prometheus check config /etc/prometheus/prometheus.yml
# → Checking /etc/prometheus/prometheus.yml
# →  SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax

docker compose up -d prometheus
```

📄 [`configs/prometheus/prometheus.yml`](configs/prometheus/prometheus.yml) — global `15s` intervals and module scrape jobs
📄 [`docker-compose.yml`](docker-compose.yml) — `prometheus` service definition

### Why

* **Read-only config and uniform labels:** mounting `prometheus.yml` as `:ro` prevents
  runtime mutation, while `host: lab-docker` enables consistent label filtering.
* **Ephemeral TSDB in dev:** omitting a named volume on `/prometheus` keeps dev
  iterations clean (`down` wipes TSDB), while `--storage.tsdb.retention.time=15d` bounds live growth.
* **Hardening:** runs as `USER nobody` (`65534`), drops all capabilities
  (`cap_drop: [ALL]`), enforces `read_only: true` and `no-new-privileges:true`, and publishes no ports.

### Verification

Wait ~15–20 seconds after startup so the first scrape cycle completes:

```bash
docker compose exec -T prometheus wget -qO- http://localhost:9090/-/ready
# → Prometheus Server is Ready.

docker compose exec -T prometheus wget -qO- http://localhost:9090/api/v1/targets \
  | python3 -c "import sys,json; [print(t['labels']['job'], t['labels']['host'], t['health']) for t in json.load(sys.stdin)['data']['activeTargets']]"
# → prometheus, node, and cadvisor report up (blackbox-* and traefik turn up after Steps 4–5)

docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=node_memory_MemAvailable_bytes' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['result'][0]['value'][1])"
# → <available-bytes>

docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=topk(3,container_memory_working_set_bytes)' \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin)['data']['result']))"
# → 3
```

---

## Step 4 — Synthetic Probes

### What was done

Validate `configs/blackbox/blackbox.yml`, start `blackbox-exporter`
(`prom/blackbox-exporter:v0.29.1`, `user: "65534:65534"`), and ensure Prometheus
scrapes the `blackbox-http` (`https://traefik` via `http_2xx_insecure`) and
`blackbox-dns` (`dns:53` via `dns_lab_soa`) probe jobs.

> **Standalone prerequisite:** `reverse-proxy` (`traefik`, `web-server`) and `dns` must be reachable on `proxy-net`; if `dns` started on `lab-net` only, run `docker network connect proxy-net dns`.

```bash
docker compose run --rm --no-deps blackbox-exporter --config.file=/config/blackbox.yml --config.check
# → ... msg="Config file is ok exiting..."

docker compose up -d blackbox-exporter
docker compose restart prometheus
```

📄 [`configs/blackbox/blackbox.yml`](configs/blackbox/blackbox.yml) — `http_2xx_insecure` and `dns_lab_soa` probe modules
📄 [`configs/prometheus/prometheus.yml`](configs/prometheus/prometheus.yml) — `blackbox-http` and `blackbox-dns` `relabel_configs` jobs
📄 [`docker-compose.yml`](docker-compose.yml) — `blackbox-exporter` with `user: "65534:65534"`

### Why

* **Probing `https://traefik` (`Host: web.localhost`) vs. `web-server` directly:** hitting
  Traefik exercises TLS termination, certificate validity, routing rules, and Nginx in one probe.
* **Why `insecure_skip_verify: true`:** accepts the lab's self-signed wildcard
  certificate (`CN=*.localhost`) without custom CA injection; set to `false` with a trusted CA in production.
* **`dns_lab_soa` vs. `pidof named`, plus `relabel_configs`:** querying `lab.local` SOA
  on UDP `:53` proves zone resolution, while `relabel_configs` rewrites targets to `blackbox-exporter:9115/probe`.
* **Hardening:** runs as `65534:65534` (`nobody`) with `cap_drop: [ALL]`,
  `read_only: true`, and `no-new-privileges:true` (no ICMP probe, so `CAP_NET_RAW` is omitted).

### Verification

Wait ~15–20 seconds after restarting `prometheus`:

```bash
docker compose ps blackbox-exporter
# → NAME                IMAGE                          STATUS
# → blackbox-exporter   prom/blackbox-exporter:v0.29.1 Up X seconds

docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=probe_success' \
  | python3 -c "import sys,json; [print(r['metric']['job'], r['metric']['instance'], r['value'][1]) for r in json.load(sys.stdin)['data']['result']]"
# → blackbox-dns dns:53 1
# → blackbox-http https://traefik 1

docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=probe_ssl_earliest_cert_expiry' \
  | python3 -c "import sys,json; [print(r['metric']['instance'], r['value'][1]) for r in json.load(sys.stdin)['data']['result']]"
# → https://traefik <unix-timestamp>
```

---

## Step 5 — Traefik Metrics

### What was done

Enable `metrics.prometheus` on Traefik's internal `dashboard` entrypoint (`:8080`)
in `traefik.yml`, restart the `traefik` container so it reloads static config, and
verify the `traefik` scrape job (`traefik:8080/metrics`, `host: lab-docker`).

```yaml
# Excerpt in reverse-proxy static config (traefik.yml)
metrics:
  prometheus:
    entryPoint: dashboard
    addEntryPointsLabels: true
    addRoutersLabels: true
    addServicesLabels: true
```

> **Static configuration requires a proxy restart:** Traefik loads `traefik.yml`
> only at startup, causing a brief connection drop on ports `80`/`443` during restart.

```bash
docker restart traefik
```

📄 [`../../reverse-proxy/docker/configs/traefik/traefik.yml`](../../reverse-proxy/docker/configs/traefik/traefik.yml) — enables `metrics.prometheus` on `dashboard` (`:8080`)
📄 [`configs/prometheus/prometheus.yml`](configs/prometheus/prometheus.yml) — `traefik` job scraping `traefik:8080/metrics`

### Why

* **Internal `:8080` exposure:** binding metrics to `dashboard` keeps `/metrics`
  reachable only inside `proxy-net` without publishing new host ports.
* **Router and service labels:** `addEntryPointsLabels`, `addRoutersLabels`, and
  `addServicesLabels` enable per-backend request rate, 5xx error rate, and p95 latency metrics.
* **Plan B (rollback):** if `traefik` fails to start, run `git revert` on the `traefik.yml` metrics commit and restart `traefik`,
  then remove the `traefik` job from `prometheus.yml` and continue using `blackbox_exporter` probes only.

### Verification

Wait ~15–20 seconds after restarting `traefik`:

```bash
docker compose exec -T prometheus wget -qO- http://traefik:8080/metrics | grep -E '^traefik_' | head -n 5
# → traefik_config_last_reload_success 1

docker compose exec -T prometheus wget -qO- http://localhost:9090/api/v1/targets \
  | python3 -c "import sys,json; [print(t['labels']['job'], t['health']) for t in json.load(sys.stdin)['data']['activeTargets'] if t['labels']['job']=='traefik']"
# → traefik up

curl -sk -o /dev/null -w "%{http_code}\n" --resolve web.localhost:443:127.0.0.1 https://web.localhost/
# → 200

curl -sk -o /dev/null -w "%{http_code}\n" --resolve traefik.localhost:443:127.0.0.1 https://traefik.localhost/dashboard/
# → 401
```

---

## Step 6 — Grafana

### What was done

Bring up the monitoring stack (`docker compose up -d`) on `proxy-net` so Grafana
starts after Prometheus (`depends_on: [prometheus]`) with read-only file provisioning
for the `Prometheus` datasource (`uid: prometheus`), `Lab` folder provider, and
14-panel `Lab Overview` dashboard (`uid: lab-overview`), exposed via Traefik HTTPS
at `https://grafana.localhost` (`GF_SERVER_ROOT_URL=https://grafana.localhost/`).

```bash
docker compose up -d
```

📄 [`docker-compose.yml`](docker-compose.yml) — `grafana` service, `tmpfs` mounts, `depends_on`, and Traefik labels
📄 [`configs/grafana/provisioning/datasources/prometheus.yml`](configs/grafana/provisioning/datasources/prometheus.yml) — default `Prometheus` datasource (`http://prometheus:9090`)
📄 [`configs/grafana/provisioning/dashboards/lab.yml`](configs/grafana/provisioning/dashboards/lab.yml) — file provider loading `/etc/grafana/dashboards` into folder `Lab`
📄 [`configs/grafana/dashboards/lab-overview.json`](configs/grafana/dashboards/lab-overview.json) — 14 panels covering Status, Host, Containers, Traefik, and Synthetic Probes

### Why

* **Prometheus plugin backend (`GF_PLUGINS_PREINSTALL_DISABLED=true`):** since Grafana 13.2,
  the Prometheus datasource runs an external Go backend binary (`gpx_*`). Disabling background preinstalls avoids downloading plugin updates onto the `noexec` `/var/lib/grafana` `tmpfs` (`fork/exec: permission denied` / `plugin.notRegistered`), keeping all container hardening intact by running the immutable bundled plugin.
* **Traefik TLS termination + Grafana native login:** Traefik terminates TLS on
  `websecure` without edge BasicAuth, leaving UI and API authentication to Grafana (`admin` / `GRAFANA_ADMIN_PASSWORD`) with no published `:3000` host port.
* **Hardening & stateless dev storage:** runs as `uid=472` with `cap_drop: [ALL]`,
  `read_only: true`, `no-new-privileges:true`, and `tmpfs` `/var/lib/grafana` (`noexec`) and `/tmp`.
* **Deterministic provisioning:** fixed UIDs (`prometheus`, `lab-overview`), `depends_on: [prometheus]`,
  and `30s` refresh load the dashboard cleanly without external community imports.

### Verification

```bash
# Confirm provisioning succeeded and no plugin backend errors appear
docker compose logs grafana | grep -i provision
# → ... msg="finished to provision ..." (no error lines)

# Load GRAFANA_ADMIN_PASSWORD from .env and verify health, datasource backend, and dashboard via Traefik HTTPS
set -a && source .env && set +a

curl -sk --resolve grafana.localhost:443:127.0.0.1 -u "admin:${GRAFANA_ADMIN_PASSWORD}" https://grafana.localhost/api/health
# → {"database":"ok","version":"13.3.0"}

curl -sk --resolve grafana.localhost:443:127.0.0.1 -u "admin:${GRAFANA_ADMIN_PASSWORD}" https://grafana.localhost/api/datasources/uid/prometheus/health
# → {"details":{"application":"Prometheus",...},"message":"Successfully queried the Prometheus API.","status":"OK"}

curl -sk --resolve grafana.localhost:443:127.0.0.1 -u "admin:${GRAFANA_ADMIN_PASSWORD}" 'https://grafana.localhost/api/search?query=Lab' \
  | python3 -c "import sys,json; print([(d['uid'], d['title'], d['folderTitle']) for d in json.load(sys.stdin)])"
# → [('lab-overview', 'Lab Overview', 'Lab')]
```

Open `https://grafana.localhost/d/lab-overview` directly (or navigate to
**Dashboards > Lab > Lab Overview** after accepting the self-signed certificate
and logging in with `admin` and `GRAFANA_ADMIN_PASSWORD` from `.env`), and confirm
data appears across **Status**, **Host**, **Containers**, **Traefik**, and
**Synthetic Probes**.

### Troubleshooting

| Symptom | Check | Resolution |
|---|---|---|
| `401` on `/api/health` via Traefik | Stale container keeping `GF_AUTH_BASIC_ENABLED=false` or `auth-dashboard@file` | Recreate container: `docker compose up -d --force-recreate grafana` |
| `404` on `/api/health` | Router missing in Traefik or wrong network | Check `docker logs traefik` and confirm `grafana` is attached to `proxy-net` |
| `502` or `504` | Grafana process crashed or did not finish starting | Inspect startup errors with `docker compose logs grafana` |
| Login rejected | `.env` password has unescaped `$` (interpolated by Compose) or `.env` changed without recreating | Avoid `$` or escape as `$$` in `.env`, inspect `docker compose exec -T grafana printenv GF_SECURITY_ADMIN_PASSWORD`, and run `docker exec grafana grafana cli admin reset-admin-password '<new>'` |
| Panels show "No data" | Check `GET /api/datasources/uid/prometheus/health` and `docker compose ps prometheus` | `plugin.notRegistered`: ensure `GF_PLUGINS_PREINSTALL_DISABLED=true` is set; Prometheus down: start stack (`docker compose up -d`); also check time range (dev TSDB is ephemeral) |

---

## Step 7 — End-to-End Verification and Fault Injection

### What was done

Verify all six Prometheus scrape targets report `up`, generate an HTTPS request,
inject a failure with `docker stop dns` for `30s` (two `15s` scrape cycles) to
confirm `probe_success{job="blackbox-dns"} == 0` in Prometheus and the dashboard,
restore `dns`, and shut down the dev stack.

### Why

* **End-to-end outage validation:** stopping `dns` tests UDP `:53` drop detection
  through `blackbox_exporter`, `15s` Prometheus scraping, and Grafana panels without affecting `blackbox-http`.
* **Ephemeral dev cleanup:** `docker compose down` discards ephemeral `/prometheus` TSDB
  and `/var/lib/grafana` `tmpfs` state while preserving `configs/` and `.env`.

### Verification

```bash
# 1. Confirm all 6 targets are up and both probes return 1
docker compose exec -T prometheus wget -qO- http://localhost:9090/api/v1/targets \
  | python3 -c "import sys,json; [print(t['labels']['job'], t['labels']['host'], t['health']) for t in json.load(sys.stdin)['data']['activeTargets']]"
# → blackbox-dns lab-docker up
# → blackbox-http lab-docker up
# → cadvisor lab-docker up
# → node lab-docker up
# → prometheus lab-docker up
# → traefik lab-docker up

curl -sk -o /dev/null -w "%{http_code}\n" --resolve web.localhost:443:127.0.0.1 https://web.localhost/
# → 200

# 2. Fault injection: stop dns and wait two 15s scrape cycles (30s)
docker stop dns
sleep 30

docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=probe_success' \
  | python3 -c "import sys,json; [print(r['metric']['job'], r['metric']['instance'], r['value'][1]) for r in json.load(sys.stdin)['data']['result']]"
# → blackbox-dns dns:53 0
# → blackbox-http https://traefik 1
# In Grafana → Lab Overview, "Blackbox Probes OK" turns FAIL and "Probe Status" drops dns:53 to 0

# 3. Restore dns and confirm recovery after 30s
docker start dns
sleep 30

docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=probe_success' \
  | python3 -c "import sys,json; [print(r['metric']['job'], r['metric']['instance'], r['value'][1]) for r in json.load(sys.stdin)['data']['result']]"
# → blackbox-dns dns:53 1
# → blackbox-http https://traefik 1
```

> **What is lost on dev `down`:** stopping the dev stack wipes Prometheus TSDB
> series and Grafana `tmpfs` runtime state; `configs/` and `.env` remain untouched on disk.

```bash
docker compose down
```

---

## Step 8 — Production

### What was done

Deploy `docker-compose.prod.yml` on a Linux host (EC2 or VM), switching to
`restart: unless-stopped`, named volumes (`prometheus-data`, `grafana-data`
without `tmpfs`), `wget` healthchecks on all five containers, `deploy.resources.limits.memory`
(`prometheus: 256m`, `grafana: 192m`, `cadvisor: 128m`, `node-exporter: 64m`, `blackbox-exporter: 64m`), and `--storage.tsdb.retention.size=1GB`.

> **Prerequisites on the production host:** ensure `reverse-proxy` and core
> services are running on `proxy-net` (`dns` and `file-transfer` run as `amd64`
> via `qemu-user-static` on Graviton `arm64`, slowing initial boot), pull updates,
> ensure `modules/monitoring/docker/.env` exists (for the unified EC2 stack, see
> [`Updating a deployed host`](../../../stacks/full-infra/docker/full-infra-docker.md#updating-a-deployed-host)),
> and stop dev (`sudo docker compose down`) if active.

```bash
cd ~/containerize-your-infra/modules/monitoring/docker
ls -l .env  # must exist (copied from .env.example)
sudo docker compose -f docker-compose.prod.yml config --quiet
# → (no output — exit code 0)

sudo docker compose -f docker-compose.prod.yml up -d
```

📄 [`docker-compose.prod.yml`](docker-compose.prod.yml) — production Compose with named volumes, healthchecks, memory limits, and `1GB` TSDB cap

### Why

* **Persistent named volumes:** `prometheus-data` (`/prometheus`) and `grafana-data`
  (`/var/lib/grafana`) preserve TSDB history and Grafana's SQLite state across restarts while `/tmp` stays `tmpfs`.
* **Native `wget` healthchecks:** lightweight probes on all five official images
  surface container stalls directly in `docker compose ps` without published ports.
* **Memory and disk caps:** `704m` combined memory limits plus `1GB` TSDB size
  retention protect small `t4g.micro` hosts from OOM kills and root-disk exhaustion.

### Production considerations

* **Retention, remote storage, and alerting:** pair short local retention with
  `remote_write` (Thanos/Mimir/AMP) and Prometheus alerting rules routed via Alertmanager.
* **Centralized authentication:** replace static `.env` secrets and Traefik
  bcrypt hashes with OIDC/OAuth2 + cloud secret rotation.
* **Host mounts and Docker socket:** replace direct `/var/run/docker.sock` and
  privileged `cAdvisor` with a minimal socket proxy and unprivileged runtime telemetry.
* **Realistic resource sizing:** run dedicated observability compute sized by
  active series (`prometheus_tsdb_head_series`) instead of sharing a 1 GiB host.
* **External Grafana database:** use managed PostgreSQL (RDS Multi-AZ) instead of
  local SQLite so multiple Grafana replicas scale horizontally.

### Verification

```bash
# Confirm all 5 services report healthy and named volumes exist
sudo docker compose -f docker-compose.prod.yml ps
# → NAME                IMAGE                             STATUS
# → blackbox-exporter   prom/blackbox-exporter:v0.29.1    Up X seconds (healthy)
# → cadvisor            ghcr.io/google/cadvisor:v0.60.6   Up X seconds (healthy)
# → grafana             grafana/grafana:13.3.0            Up X seconds (healthy)
# → node-exporter       prom/node-exporter:v1.12.1        Up X seconds (healthy)
# → prometheus          prom/prometheus:v3.16.0           Up X seconds (healthy)

sudo docker volume ls | grep -E 'prometheus-data|grafana-data'
# → local     <project>_grafana-data
# → local     <project>_prometheus-data

# Confirm TSDB and Grafana state persist across down/up (never pass -v)
sudo docker compose -f docker-compose.prod.yml down
sudo docker compose -f docker-compose.prod.yml up -d
sleep 20

sudo docker compose -f docker-compose.prod.yml exec -T prometheus wget -qO- \
  'http://localhost:9090/api/v1/query?query=count_over_time(up{job="prometheus"}[15m])' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['result'][0]['value'][1])"
# → <sample-count-preserved-across-restart>

# Verify Grafana HTTPS ingress and provisioned dashboard on the host
set -a && source .env && set +a

curl -sk --resolve grafana.localhost:443:127.0.0.1 -u "admin:${GRAFANA_ADMIN_PASSWORD}" https://grafana.localhost/api/health
# → {"database":"ok","version":"13.3.0"}

curl -sk --resolve grafana.localhost:443:127.0.0.1 -u "admin:${GRAFANA_ADMIN_PASSWORD}" 'https://grafana.localhost/api/search?query=Lab' \
  | python3 -c "import sys,json; print([(d['uid'], d['title'], d['folderTitle']) for d in json.load(sys.stdin)])"
# → [('lab-overview', 'Lab Overview', 'Lab')]
```

> **Host Docker permissions & password persistence:** run `sudo docker ...` on Linux
> hosts unless your user belongs to the `docker` group (effective after starting a new SSH
> session). `GRAFANA_ADMIN_PASSWORD` applies only when Grafana first creates its database in
> `grafana-data`; reset it later with `sudo docker exec grafana grafana cli admin reset-admin-password '<new-password>'`.

To access Grafana remotely from your workstation, open an SSH tunnel forwarding
host port `443` (`ssh -L 8443:localhost:443 ubuntu@<ip>`) and browse to
`https://grafana.localhost:8443/d/lab-overview` (**Dashboards > Lab > Lab Overview**),
logging in with `admin` and `GRAFANA_ADMIN_PASSWORD` — editing `/etc/hosts` does not
route `grafana.localhost` remotely because browsers resolve `*.localhost` strictly to loopback.
