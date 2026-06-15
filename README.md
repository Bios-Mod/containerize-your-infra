![containerize-your-infra banner](./banner.png)

# containerize-your-infra — Docker Infrastructure Lab

[![Nginx](https://img.shields.io/badge/Nginx-containerized-009639?style=flat-square&logo=nginx&logoColor=white)](modules/web-server/README.md)
[![BIND9](https://img.shields.io/badge/BIND9-DNS-informational?style=flat-square)](modules/dns/README.md)
[![SFTP](https://img.shields.io/badge/SFTP-file--transfer-blue?style=flat-square)](modules/file-transfer/README.md)
[![Traefik](https://img.shields.io/badge/Traefik-reverse--proxy-24A1C1?style=flat-square&logo=traefikproxy&logoColor=white)](modules/reverse-proxy/README.md)
[![Docker](https://img.shields.io/badge/Docker-Engine-2496ED?style=flat-square&logo=docker&logoColor=white)](environments/dev/setup.md)
[![Compose](https://img.shields.io/badge/Compose-v2-2496ED?style=flat-square&logo=docker&logoColor=white)](environments/README.md)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04%20LTS-orange?style=flat-square&logo=ubuntu&logoColor=white)](environments/prod/setup.md)

A practical, step-by-step reference for deploying containerized infrastructure services using Docker. Each module covers a real service — DNS, file transfer, web server, reverse proxy — with the reasoning behind every decision explained inline.

Built and tested on Ubuntu 24.04 LTS and macOS (Apple Silicon). Docker Engine on Linux (local VM + EC2 t4g.micro) and OrbStack on macOS. All configurations are architecture-agnostic unless noted.

This lab deploys the same services as [build-your-infra](https://github.com/Bios-Mod/build-your-infra) — same stack, containerized. That repo covers the same infrastructure across three environments: local VM, VPS/EC2, and AWS managed services. The two repos are independent references that cover the same stack at different levels of abstraction: bare-metal and Docker.

---

## Environments

| Component | dev | prod |
|---|---|---|
| Host | macOS (Apple Silicon) | Ubuntu 24.04 LTS — EC2 t4g.micro / local VM |
| Runtime | OrbStack | Docker Engine |
| Architecture | ARM64 | ARM64 (Graviton2) / x86_64 |
| Volumes | Bind mounts | Named volumes |
| Restart policy | no | unless-stopped |

Set up your environment before applying any module:

- **dev** — OrbStack on macOS → [`environments/dev/setup.md`](environments/dev/setup.md)
- **prod** — Docker Engine on Ubuntu 24.04 LTS → [`environments/prod/setup.md`](environments/prod/setup.md)

---

## Deploying This Lab

1. Choose your environment and follow its setup guide
2. Apply modules in order — each module is independent and self-contained
3. Deploy the full stack once all modules are verified

> **Standalone module deployment:** each module includes a `docker-compose.prod.yml`
> for isolated prod deployment from its own directory.
>
> **Full-stack deployment:** all modules as a single unit, orchestrated from
> [`stacks/full-infra/`](stacks/full-infra/README.md):
> ```bash
> cd stacks/full-infra
> docker compose -f docker-compose.prod.yml up -d
> ```

---

## Modules

| Module | Technology | build-your-infra equivalent | Doc |
|---|---|---|---|
| Web Server | Nginx official image | Nginx + HTTPS + reverse proxy | [`modules/web-server/`](modules/web-server/README.md) |
| File Transfer | atmoz/sftp | SFTP (OpenSSH subsystem) | [`modules/file-transfer/`](modules/file-transfer/README.md) |
| DNS | BIND9 | BIND9 | [`modules/dns/`](modules/dns/README.md) |
| Reverse Proxy | Traefik | Nginx proxy block | [`modules/reverse-proxy/`](modules/reverse-proxy/README.md) |
| Full Infrastructure Stack | All modules | All modules combined | [`stacks/full-infra/`](stacks/full-infra/README.md) |

> **Automation phase — planned next:** Each module includes an `automation/` directory reserved for this. The upcoming phase coordinated with the automation phase of [build-your-infra](https://github.com/Bios-Mod/build-your-infra).

---

## Repository Structure

```bash
containerize-your-infra/
├── AGENTS.md
├── CONTRIBUTING.md
├── LICENSE
├── README.md
├── banner.png
├── context
│   ├── current-iteration.md
│   └── decisions-log.md
├── environments
│   ├── README.md
│   ├── dev
│   │   └── setup.md
│   └── prod
│       └── setup.md
├── modules
│   ├── dns
│   │   ├── README.md
│   │   ├── automation
│   │   ├── configs
│   │   │   └── bind
│   │   ├── dns.md
│   │   ├── docker-compose.prod.yml
│   │   └── docker-compose.yml
│   ├── file-transfer
│   │   ├── README.md
│   │   ├── automation
│   │   ├── configs
│   │   │   ├── keys
│   │   │   └── ssh
│   │   ├── data
│   │   │   └── upload
│   │   ├── docker-compose.prod.yml
│   │   ├── docker-compose.yml
│   │   └── file-transfer.md
│   ├── reverse-proxy
│   │   ├── README.md
│   │   ├── automation
│   │   ├── configs
│   │   │   └── traefik
│   │   ├── docker-compose.prod.yml
│   │   ├── docker-compose.yml
│   │   └── reverse-proxy.md
│   └── web-server
│       ├── README.md
│       ├── automation
│       ├── configs
│       │   ├── html
│       │   └── nginx
│       ├── docker-compose.prod.yml
│       ├── docker-compose.yml
│       └── web-server.md
└── stacks
    └── full-infra
        ├── README.md
        ├── docker-compose.prod.yml
        └── full-infra.md
```