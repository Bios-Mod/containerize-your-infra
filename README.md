![containerize-your-infra banner](./banner.png)

# containerize-your-infra — Containerized Infrastructure Lab

[![Web Server CI](https://github.com/Bios-Mod/containerize-your-infra/actions/workflows/web-server.yml/badge.svg)](https://github.com/Bios-Mod/containerize-your-infra/actions/workflows/web-server.yml)
[![File Transfer CI](https://github.com/Bios-Mod/containerize-your-infra/actions/workflows/file-transfer.yml/badge.svg)](https://github.com/Bios-Mod/containerize-your-infra/actions/workflows/file-transfer.yml)
[![DNS CI](https://github.com/Bios-Mod/containerize-your-infra/actions/workflows/dns.yml/badge.svg)](https://github.com/Bios-Mod/containerize-your-infra/actions/workflows/dns.yml)
[![Reverse Proxy CI](https://github.com/Bios-Mod/containerize-your-infra/actions/workflows/reverse-proxy.yml/badge.svg)](https://github.com/Bios-Mod/containerize-your-infra/actions/workflows/reverse-proxy.yml)
[![Full Infra CI](https://github.com/Bios-Mod/containerize-your-infra/actions/workflows/full-infra.yml/badge.svg)](https://github.com/Bios-Mod/containerize-your-infra/actions/workflows/full-infra.yml)
[![Pull Request CI](https://github.com/Bios-Mod/containerize-your-infra/actions/workflows/pull-request.yml/badge.svg)](https://github.com/Bios-Mod/containerize-your-infra/actions/workflows/pull-request.yml)

[![Docker](https://img.shields.io/badge/Nginx-custom%20image-009639?style=flat-square&logo=docker&logoColor=white)](modules/web-server/README.md)
[![BIND9](https://img.shields.io/badge/BIND9-DNS-informational?style=flat-square)](modules/dns/README.md)
[![SFTP](https://img.shields.io/badge/SFTP-file--transfer-blue?style=flat-square)](modules/file-transfer/README.md)
[![Traefik](https://img.shields.io/badge/Traefik-reverse--proxy-24A1C1?style=flat-square&logo=traefikproxy&logoColor=white)](modules/reverse-proxy/README.md)
[![Docker](https://img.shields.io/badge/Docker-Engine-2496ED?style=flat-square&logo=docker&logoColor=white)](environments/docker/dev/setup.md)
[![Compose](https://img.shields.io/badge/Compose-v2-2496ED?style=flat-square&logo=docker&logoColor=white)](environments/README.md)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04%20LTS-orange?style=flat-square&logo=ubuntu&logoColor=white)](environments/docker/prod/setup.md)
[![EC2](https://img.shields.io/badge/EC2-t4g.micro-FF9900?style=flat-square&logo=amazonec2&logoColor=white)](environments/docker/prod/setup.md)
[![Terraform](https://img.shields.io/badge/Terraform-automation-7B42BC?style=flat-square&logo=terraform&logoColor=white)](stacks/full-infra/docker/automation.md)

A practical, step-by-step reference for deploying infrastructure services with
Docker and, progressively, Kubernetes on Amazon EKS.

Docker is the current complete implementation: local development with OrbStack
and production deployment on Docker Engine over EC2. Kubernetes/EKS is the next
implementation of the same stack and will be introduced module by module
through Helm.

Each module covers a real infrastructure service — DNS, file transfer, web
server, and reverse proxy — with the reasoning behind every decision explained
inline.

Built and tested on Ubuntu 24.04 LTS and macOS on Apple Silicon. Docker Engine
runs on Linux hosts, including EC2 t4g.micro, while OrbStack provides the local
macOS development runtime. All configurations are architecture-agnostic unless
noted.

This lab deploys the same services as
[build-your-infra](https://github.com/Bios-Mod/build-your-infra): the same stack
containerized and automated. The two repositories are independent references
that cover the same infrastructure at different levels of abstraction:
self-managed infrastructure and containers.

---

## Runtime Implementations

| Runtime | Environments | Deployment model | Status |
|---|---|---|---|
| Docker | Local development and EC2 production | Docker Compose | Implemented |
| Kubernetes | Logical dev and prod environments in one EKS cluster | Helm | In implementation |

Docker and Kubernetes are complementary implementations of the same
infrastructure stack. Kubernetes does not replace the Docker implementation.

---

## Deploying This Lab

1. Choose your Docker environment and follow its setup guide
2. Apply modules in order — each module is independent and self-contained
3. Deploy the full Docker stack once all modules are verified
4. Provision the Docker production host on EC2 with Terraform —
   [`stacks/full-infra/docker/automation.md`](stacks/full-infra/docker/automation.md)

> **Standalone module deployment:** each module includes a
> `docker-compose.prod.yml` for isolated Docker production deployment from its
> own runtime directory.
>
> **Full-stack deployment:** all Docker modules are deployed as a single unit,
> orchestrated from [`stacks/full-infra/`](stacks/full-infra/README.md).
>
> **Automated deployment:** Terraform provisions the EC2 host and launches the
> Docker full stack automatically — no manual steps on the host.

---

## Environments

| Component | Docker dev | Docker prod |
|---|---|---|
| Host | macOS (Apple Silicon) | Ubuntu 24.04 LTS — EC2 t4g.micro / local VM |
| Runtime | OrbStack | Docker Engine |
| Architecture | ARM64 | ARM64 (Graviton2) / x86_64 |
| Volumes | Bind mounts | Named volumes |
| Restart policy | `no` | `unless-stopped` |

Set up the Docker environment before applying any module:

- **dev** — OrbStack on macOS →
  [`environments/docker/dev/setup.md`](environments/docker/dev/setup.md)
- **prod** — Docker Engine on Ubuntu 24.04 LTS →
  [`environments/docker/prod/setup.md`](environments/docker/prod/setup.md)

Kubernetes environment procedures will be added under
`environments/kubernetes/` when the EKS platform is implemented.

---

## Modules

| Module | Technology | build-your-infra equivalent | Doc |
|---|---|---|---|
| Web Server | Custom image (Dockerfile) on Nginx unprivileged | Nginx + HTTPS + reverse proxy | [`modules/web-server/`](modules/web-server/README.md) |
| File Transfer | atmoz/sftp | SFTP (OpenSSH subsystem) | [`modules/file-transfer/`](modules/file-transfer/README.md) |
| DNS | BIND9 | BIND9 | [`modules/dns/`](modules/dns/README.md) |
| Reverse Proxy | Traefik | Nginx proxy block | [`modules/reverse-proxy/`](modules/reverse-proxy/README.md) |
| Full Infrastructure Stack | All modules | All modules combined | [`stacks/full-infra/`](stacks/full-infra/README.md) |

---

## Automation

The Docker production host is provisioned with Terraform. A single Terraform
configuration defines the VPC, subnet, security group, key pair, and EC2
instance. On first boot, `user_data` installs Docker Engine, clones this
repository, and launches the Docker full stack automatically.

| Layer | Tool | Scope |
|---|---|---|
| Infrastructure | Terraform | VPC, subnet, security group, key pair, EC2 |
| Services | Docker Compose | Containers, networks, volumes |

Terraform is validated in CI with formatting and static configuration checks.
Cloud-facing operations, including `terraform plan` and `terraform apply`, are
performed manually with local AWS credentials before infrastructure changes are
applied.

See [`stacks/full-infra/docker/automation.md`](stacks/full-infra/docker/automation.md)
for the full implementation.

---

## Continuous Integration

Every Docker module and the Docker full stack are validated automatically
through GitHub Actions. Each module triggers its own workflow scoped by a
runtime-specific `paths` filter, so a Docker change does not run unrelated
module checks.

| Workflow | Docker scope | Validates |
|---|---|---|
| `web-server.yml` | `modules/web-server/docker/**` | Custom image build |
| `file-transfer.yml` | `modules/file-transfer/docker/**` | Compose configuration and image references |
| `dns.yml` | `modules/dns/docker/**` | Compose configuration and image references |
| `reverse-proxy.yml` | `modules/reverse-proxy/docker/**` | Compose configuration and image references |
| `full-infra.yml` | Docker stack and module Docker paths | Full-stack Compose config/build and Docker/EC2 Terraform |
| `pull-request.yml` | Changed Docker paths | Path-scoped module and full-stack Docker validation |

Kubernetes CI will be added independently when Helm charts and EKS Terraform
are implemented. It will not replace the existing Docker validation.

See [`continuous-integration.md`](continuous-integration.md) for the full
implementation and design decisions.

---

## Repository Structure

```text
containerize-your-infra/
├── README.md
├── continuous-integration.md
├── CONTRIBUTING.md
├── LICENSE
├── banner.png
├── environments/
│   ├── README.md
│   └── docker/
│       ├── dev/
│       │   └── setup.md
│       └── prod/
│           └── setup.md
├── modules/
│   ├── web-server/
│   │   ├── README.md
│   │   └── docker/
│   │       ├── Dockerfile
│   │       ├── configs/
│   │       ├── docker-compose.yml
│   │       ├── docker-compose.prod.yml
│   │       └── web-server-docker.md
│   ├── file-transfer/
│   │   ├── README.md
│   │   └── docker/
│   │       ├── configs/
│   │       ├── data/
│   │       ├── docker-compose.yml
│   │       ├── docker-compose.prod.yml
│   │       └── file-transfer-docker.md
│   ├── dns/
│   │   ├── README.md
│   │   └── docker/
│   │       ├── configs/
│   │       ├── docker-compose.yml
│   │       ├── docker-compose.prod.yml
│   │       └── dns-docker.md
│   ├── reverse-proxy/
│   │   ├── README.md
│   │   └── docker/
│   │       ├── configs/
│   │       ├── docker-compose.yml
│   │       ├── docker-compose.prod.yml
│   │       └── reverse-proxy-docker.md
│   └── ...
├── stacks/
│   └── full-infra/
│       ├── README.md
│       └── docker/
│           ├── automation/
│           │   └── terraform/
│           ├── automation.md
│           ├── docker-compose.prod.yml
│           └── full-infra-docker.md
└── .github/
    └── workflows/
```