# Full Infrastructure Stack

A single Docker Compose deployment that brings up the complete lab:
web-server, file-transfer, dns, and reverse-proxy as interconnected services
on a shared Docker network (`proxy-net`).

## Implementation

| Runtime | Environment | Doc |
|---|---|---|
| Docker | prod | [`full-infra-docker.md`](docker/full-infra-docker.md) |
| Kubernetes | dev / prod | Planned |

## Docker automation

The host running the Docker stack is provisioned with Terraform. A single plan
creates the EC2 instance, security group, EBS volume, and key pair — then
passes a `user_data` script that installs Docker Engine, clones this
repository, and runs:

```bash
docker compose -f stacks/full-infra/docker/docker-compose.prod.yml up -d
```

The Compose stack and the Terraform plan are intentionally decoupled:
Terraform owns the infrastructure layer; Docker Compose owns the service
layer. Neither layer needs to know the internals of the other.

| Layer | Tool | Scope | Doc |
|---|---|---|---|
| Infrastructure | Terraform | EC2, security group, EBS volume, key pair | [`automation.md`](docker/automation/automation.md) |
| Services | Docker Compose | Containers, networks, volumes | [`full-infra-docker.md`](docker/full-infra-docker.md) |

Terraform source: [`docker/automation/terraform/`](docker/automation/terraform/)

## Kubernetes implementation

Kubernetes will provide a second implementation of the same stack on Amazon
EKS. Docker Compose remains the current, complete implementation for local
development and EC2 production.

The Kubernetes runtime will use Helm for packaging and deployment, with
separate logical development and production environments in a shared EKS
cluster. It is not implemented yet.

**Infrastructure & AWS native equivalent:** [`stacks/full-infra`](https://github.com/Bios-Mod/build-your-infra/tree/main/stacks/full-infra)