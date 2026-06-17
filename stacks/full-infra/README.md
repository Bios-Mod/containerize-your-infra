# Full Infrastructure Stack

A single `docker compose` command that brings up the complete lab:
web-server, file-transfer, dns, and reverse-proxy as interconnected services
on a shared Docker network (`proxy-net`).

## Implementation

| Environment | Doc |
|---|---|
| prod | [`full-infra.md`](full-infra.md) |

```bash
cd stacks/full-infra
docker compose -f docker-compose.prod.yml up -d
```

## Automation

The host running this stack is provisioned with Terraform. A single plan
creates the EC2 instance, security group, EBS volume, and key pair — then
passes a `user_data` script that installs Docker Engine, clones this
repository, and runs `docker compose -f stacks/full-infra/docker-compose.prod.yml up -d`.

The Compose stack and the Terraform plan are intentionally decoupled:
Terraform owns the infrastructure layer; Docker Compose owns the service
layer. Neither layer needs to know the internals of the other.

| Layer | Tool | Scope |
|---|---|---|
| Infrastructure | Terraform | EC2, SG, EBS, key pair |
| Services | Docker Compose | Containers, networks, volumes |

Automation source: [`stacks/full-infra/automation/`](automation/)

**Infrastructure & AWS native equivalent:** [`stacks/full-infra`](https://github.com/Bios-Mod/build-your-infra)