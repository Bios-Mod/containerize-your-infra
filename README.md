![containerize-your-infra banner](./banner.png)

# containerize-your-infra — Docker Infrastructure Lab

[![Nginx](https://img.shields.io/badge/Nginx-containerized-009639?style=flat-square&logo=nginx&logoColor=white)](modules/web-server/README.md)
[![BIND9](https://img.shields.io/badge/BIND9-DNS-informational?style=flat-square)](modules/dns/README.md)
[![SFTP](https://img.shields.io/badge/SFTP-file--transfer-blue?style=flat-square)](modules/file-transfer/README.md)
[![Traefik](https://img.shields.io/badge/Traefik-reverse--proxy-24A1C1?style=flat-square&logo=traefikproxy&logoColor=white)](modules/reverse-proxy/README.md)
[![Docker](https://img.shields.io/badge/Docker-Engine-2496ED?style=flat-square&logo=docker&logoColor=white)](environments/dev/setup.md)
[![Compose](https://img.shields.io/badge/Compose-v2-2496ED?style=flat-square&logo=docker&logoColor=white)](environments/README.md)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04%20LTS-orange?style=flat-square&logo=ubuntu&logoColor=white)](environments/prod/setup.md)

The containerized companion to [build-your-infra](https://github.com/Bios-Mod/build-your-infra).

The same infrastructure — DNS, file transfer, web server, reverse proxy — re-implemented as Docker containers. Each module mirrors its bare-metal equivalent, making the two repos a direct side-by-side reference: same service, two different primitives.

Built and tested on Ubuntu 24.04 LTS and macOS (Apple Silicon). Docker Engine on Linux (dev VM + EC2 t4g.micro) and Docker OrbStack on macOS. All configurations are architecture-agnostic unless noted.

---

## Sister Repo

This lab is the second phase of a multi-repo infrastructure portfolio:

| Repo | Primitive | Status |
|---|---|---|
| [build-your-infra](https://github.com/Bios-Mod/build-your-infra) | Bare-metal · VM · AWS managed services | Phase 1 complete |
| containerize-your-infra | Docker containers | In progress |

Each module in this repo links back to its equivalent in build-your-infra. Following both repos in parallel shows the same infrastructure knowledge expressed at two different levels of abstraction.

---

## Environments

| Component | dev | prod |
|---|---|---|
| Host | macOS (Apple Silicon) | Ubuntu 24.04 LTS — EC2 t4g.micro / local VM |
| Runtime | Docker Desktop | Docker Engine |
| Architecture | ARM64 | ARM64 (Graviton2) / x86_64 |
| Volumes | Bind mounts | Named volumes |
| Restart policy | no | unless-stopped |

Set up your environment before applying any module:

- **dev** — Docker Desktop on macOS → [`environments/dev/setup.md`](environments/dev/setup.md)
- **prod** — Docker Engine on Ubuntu 24.04 LTS → [`environments/prod/setup.md`](environments/prod/setup.md)

---

## Deploying This Lab

1. Choose your environment and follow its setup guide
2. Apply modules in order — each module is independent and self-contained
3. Phase 2 (environments override files) is applied after all modules are deployed

---

## Modules

| Module | Technology | build-your-infra equivalent | Doc |
|---|---|---|---|
| Web Server | Nginx official image | Nginx + HTTPS + reverse proxy | [`modules/web-server/`](modules/web-server/README.md) |
| File Transfer | atmoz/sftp | SFTP (OpenSSH subsystem) | [`modules/file-transfer/`](modules/file-transfer/README.md) |
| DNS | BIND9 | BIND9 | [`modules/dns/`](modules/dns/README.md) |
| Reverse Proxy | Traefik | Nginx proxy block | [`modules/reverse-proxy/`](modules/reverse-proxy/README.md) |

---

## Roadmap

### Phase 1 — Core Modules (current)
Deploy each module in order. Each module is independent — no hard prerequisites between services.

### Phase 2 — Environments & Stack
`environments/dev` and `environments/prod` override files applied at the close of Phase 1.
`stacks/full-infra` — single compose that brings up the complete lab — documented as a future milestone.

### Phase 3 — Automation
GitHub Actions for image builds and compose validation.
Coordinated with the automation phase of [build-your-infra](https://github.com/Bios-Mod/build-your-infra).

**Automation soon**

---

## Repository Structure

```bash
containerize-your-infra/
├── AGENTS.md
├── banner.png
├── context
│   ├── current-iteration.md
│   └── decisions-log.md
├── CONTRIBUTING.md
├── environments
│   ├── dev
│   │   ├── docker-compose.override.yml
│   │   └── setup.md
│   ├── prod
│   │   ├── docker-compose.prod.yml
│   │   └── setup.md
│   └── README.md
├── LICENSE
├── modules
│   ├── dns
│   │   ├── automation
│   │   ├── configs
│   │   ├── dns.md
│   │   ├── docker-compose.yml
│   │   └── README.md
│   ├── file-transfer
│   │   ├── automation
│   │   ├── configs
│   │   ├── docker-compose.yml
│   │   ├── file-transfer.md
│   │   └── README.md
│   ├── reverse-proxy
│   │   ├── automation
│   │   ├── configs
│   │   ├── docker-compose.yml
│   │   ├── README.md
│   │   └── reverse-proxy.md
│   └── web-server
│       ├── automation
│       ├── configs
│       ├── docker-compose.yml
│       ├── README.md
│       └── web-server.md
├── README.md
└── stacks
    └── full-infra
        └── README.md
```

---