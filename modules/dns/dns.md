# DNS — containerize-your-infra

**Docker Engine · internetsystemsconsortium/bind9:9.20 (platform: linux/amd64)**

---

## Introduction

This module deploys BIND9 in a Docker container to provide two DNS functions
for the lab: recursive resolution for external names via Google DNS forwarders,
and an authoritative zone for `lab.local`.

The service runs on a dedicated Docker bridge network (`lab-net`) with a fixed
IP address — the same operational requirement as a real DNS server. A DNS that
changes IP on every restart is not a DNS.

> **No DHCP here.** This module covers name resolution only. IP assignment is
> out of scope.

> **Config files in `configs/bind/`** contain only the blocks or full files
> added by this module. The path inside the module folder is referenced after
> each deploy block.

---

## Environment

| Parameter     | Value                                              |
|---------------|----------------------------------------------------|
| Image         | `internetsystemsconsortium/bind9:9.20`             |
| Port          | 53 TCP/UDP                                         |
| DNS role      | Recursive resolver + authoritative zone            |
| Internal zone | `lab.local`                                        |
| Forwarders    | `8.8.8.8`, `8.8.4.4`                               |
| Fixed IP      | `172.20.0.10`                                      |
| Network       | `lab-net` — `172.20.0.0/24`                        |
| Config mount  | Bind mount (dev) — `configs/bind/`                 |

---

## Before You Start — Image Exploration (optional)

These commands inspect the image before any Compose deployment. Nothing here
affects the module state — no files are created, no config is applied.

**1. Pull and run the image as-is**

```bash
docker run --rm --platform linux/amd64 internetsystemsconsortium/bind9:9.20
```

The container starts and exits — BIND9 needs a valid `named.conf` to run.
This confirms the image is available locally before writing any config.

**2. Explore the image filesystem**

```bash
docker run --rm -it --platform linux/amd64 --entrypoint sh internetsystemsconsortium/bind9:9.20
```

Confirm the paths the Compose file will mount:

```sh
cat /etc/bind/named.conf
# → default named.conf 
ls /etc/bind/
# → named.conf 
```

**3. Check the default user**

```bash
docker run --rm --platform linux/amd64 internetsystemsconsortium/bind9:9.20 id
# → uid=101(bind) gid=101(bind) groups=101(bind)
```

BIND9 runs as the `bind` user (UID 101) by default in this image — no
additional hardening needed for the user context.

---

## Step 1 — Network and Compose File

### What was done

A dedicated Docker bridge network `lab-net` is created with subnet
`172.20.0.0/24`. The BIND9 service is assigned the fixed IP `172.20.0.10`
on that network and exposes port 53 on both TCP and UDP.

```bash
docker compose up -d
```

📄 [`docker-compose.yml`](docker-compose.yml) — `docker compose up -d` from this directory

### Why

DNS requires a stable, known address. If the container restarts and Docker
assigns a different IP from the bridge pool, every client that had the old
IP cached loses resolution. Assigning a fixed IP via `ipv4_address` is the
container equivalent of configuring a static IP on a server NIC.

In build-your-infra the DNS server had `172.16.0.1` fixed as the WireGuard
hub. Here the same principle applies: the DNS server owns its IP and nothing
else in the lab should need to change its address to find it.

A dedicated subnet (`lab-net`) isolates lab traffic from Docker's default
bridge and makes the network topology explicit. Every module that needs to
be reachable by name will join this same network.

DNS uses UDP for standard queries and TCP for zone transfers and responses
larger than 512 bytes — both transports must be published.

### Verification

```bash
# Container is running with the correct IP
docker compose ps
# → NAME   IMAGE                                    STATUS
# → dns    internetsystemsconsortium/bind9:9.20     Up X seconds
# → PORTS  53/tcp, 53/udp

docker inspect dns --format '{{ (index .NetworkSettings.Networks "lab-net").IPAddress }}'
# → 172.20.0.10

docker compose exec -T dns dig @127.0.0.1 lab.local SOA
# → ANSWER SECTION with SOA record

docker compose exec -T dns dig @127.0.0.1 dns.lab.local +short
# → 172.20.0.10
```

---

## Step 2 — Resolver Configuration

### What was done

BIND9 is configured as a recursive resolver with forwarders to Google DNS.
Queries for names outside `lab.local` are forwarded to `8.8.8.8` and
`8.8.4.4`. The server does not walk the root tree itself — it delegates
external resolution to the forwarders and caches the results.

📄 [`configs/bind/named.conf.options`](configs/bind/named.conf.options) — mounted at `/etc/bind/named.conf.options`

### Why

`forward only` means BIND9 will not attempt recursive resolution on its own
if the forwarders are unreachable — it fails cleanly rather than timing out
against root servers. For a lab resolver this is the correct posture: the
lab depends on Internet connectivity anyway.

`version "not available"` prevents version disclosure via DNS queries —
the same principle as hiding server tokens in Nginx.

### Verification

```bash
# Config syntax is valid
docker compose exec dns named-checkconf
# → no output

# External resolution works through forwarders
docker compose exec dns dig @127.0.0.1 google.com +short
# → an external IP address
```

---

## Step 3 — Authoritative Zone

### What was done

The `lab.local` zone is defined as a primary zone. BIND9 answers authoritatively
for all names under `lab.local` without forwarding those queries upstream.

The zone file defines the SOA, the NS record, and A records for the two hosts
in the lab: `dns.lab.local` and `web.lab.local`.

📄 [`configs/bind/named.conf.local`](configs/bind/named.conf.local) — mounted at `/etc/bind/named.conf.local`
📄 [`configs/bind/db.lab.local`](configs/bind/db.lab.local) — mounted at `/etc/bind/db.lab.local`

### Why

An authoritative zone means the server is the source of truth for that
domain — it does not ask anyone else. When a client queries `web.lab.local`,
BIND9 answers directly from the zone file without touching the forwarders.

The SOA serial follows the `YYYYMMDDNN` convention — the same format used
in build-your-infra. Incrementing the serial on every zone change is how
secondary servers detect that the zone has been updated.

### Verification

```bash
# Zone file syntax is valid
docker compose exec -T dns named-checkzone lab.local /etc/bind/db.lab.local
# → zone lab.local/IN: loaded serial 2026061201
# → OK

# Internal name resolves to the correct IP
docker compose exec dns dig @127.0.0.1 dns.lab.local +short
# → 172.20.0.10

docker compose exec dns dig @127.0.0.1 web.lab.local +short
# → 172.20.0.20
```

---

## Step 4 — Reverse Zone

### What was done

A reverse zone for `172.20.0.0/24` is added so that IP-to-name lookups
return hostnames for the lab subnet. PTR records map the last octet of
each fixed IP back to its fully qualified name.

📄 [`configs/bind/db.172.20.0`](configs/bind/db.172.20.0) — mounted at `/etc/bind/db.172.20.0`

### Why

Forward DNS maps names to IPs. Reverse DNS maps IPs back to names. Both
directions are necessary for a complete, production-grade DNS setup.

Reverse resolution is used by logging systems, SSH, and many monitoring
tools to display hostnames instead of raw IPs. In build-your-infra the
reverse zone covered `172.16.0.0/24` — here it covers `172.20.0.0/24`,
the lab-net subnet.

### Verification

```bash
# Reverse zone syntax is valid
docker compose exec -T dns named-checkzone 0.20.172.in-addr.arpa /etc/bind/db.172.20.0
# → zone 0.20.172.in-addr.arpa/IN: loaded serial 2026061201
# → OK

docker compose exec -T dns dig @127.0.0.1 -x 172.20.0.10 +short
# → dns.lab.local.

docker compose exec -T dns dig @127.0.0.1 -x 172.20.0.20 +short
# → web.lab.local.
```

---

## Step 5 — Smoke Test and Container Lifecycle

### What was done

Full lifecycle test: stop, remove, and bring the container back up from the
Compose file. This validates that all zones load cleanly on a cold start and
that the fixed IP is reassigned correctly.

> This step has no new config or deploy action. It is a verification-only
> step to confirm the module is complete before moving to the next module.

### Why

A DNS server that does not survive a restart is not a DNS server. In
build-your-infra the equivalent was `systemctl restart bind9` followed by
a zone check. Here the unit of restart is the container — the zone files
and config are on bind mounts, so nothing is lost between cycles.

### Verification

```bash
docker compose down
docker compose up -d

# Fixed IP is restored
docker inspect dns --format '{{ (index .NetworkSettings.Networks "lab-net").IPAddress }}'
# → 172.20.0.10

# Both internal and external resolution work on cold start
docker compose exec dns dig @127.0.0.1 dns.lab.local +short
# → 172.20.0.10

docker compose exec dns dig @127.0.0.1 google.com +short
# → an external IP address
```

---

## Production deployment

In production the module runs from `docker-compose.prod.yml` instead of
`docker-compose.yml`. The image, hardening, and BIND9 configuration are identical —
what changes is the operational layer.

| Parameter | dev | prod |
|---|---|---|
| Config mounts (`named.conf*`, zone files) | Bind mount | Bind mount `:ro` |
| Zone data (writable journal files) | Not applicable — static zones | Named volume |
| Restart policy | `"no"` (default) | `unless-stopped` |
| Healthcheck | None | `dig` SOA probe on port 53 |

Config files are always mounted from the repository as read-only. Zone journal
files (`.jnl`) generated by BIND9 at runtime are persisted in a named volume —
they are not config and must survive container replacement independently of the
host path.

> **Named volume and bind mounts coexist.** The config files (`named.conf*`,
> `db.*`) are bind-mounted read-only from `configs/bind/`. The named volume
> covers only the BIND9 working directory (`/var/cache/bind`) where runtime
> state is written.

```bash
docker compose -f docker-compose.prod.yml up -d
```

📄 [`docker-compose.prod.yml`](docker-compose.prod.yml)

### Verification

```bash
docker compose -f docker-compose.prod.yml ps
# → NAME   STATUS
# → dns    Up X seconds (healthy)

# Confirm healthcheck is passing — wait ~15s after start_period
docker inspect dns --format '{{ .State.Health.Status }}'
# → healthy

# Confirm named volume is mounted
docker inspect dns --format '{{ .Mounts }}'
# → [{volume dns-cache /var/lib/docker/volumes/dns-cache/...}]

# Confirm restart policy survives daemon restart
sudo systemctl restart docker
sleep 5
docker ps
# → dns   Up X seconds

# Confirm both internal and external resolution work after daemon restart
docker compose -f docker-compose.prod.yml exec dns dig @127.0.0.1 dns.lab.local +short
# → 172.20.0.10

docker compose -f docker-compose.prod.yml exec dns dig @127.0.0.1 google.com +short
# → an external IP address
```

---

**Next:** [`modules/reverse-proxy/reverse-proxy.md`](../reverse-proxy/reverse-proxy.md)