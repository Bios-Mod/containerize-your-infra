# Full Infrastructure Stack

The complete lab deployed as a single unit: web-server, dns and reverse-proxy
as interconnected services, plus file-transfer in the Docker runtime. Both
runtimes reproduce the same topology — one HTTP/S entry point, one backend and
one resolver — with different tooling.

## Implementation

| Runtime | Environment | Technology | Doc |
|---|---|---|---|
| Docker | prod | Docker Compose on EC2 | [`full-infra-docker.md`](docker/full-infra-docker.md) |
| Kubernetes | dev / prod | Helm umbrella chart on Amazon EKS | [`full-infra-kubernetes.md`](kubernetes/full-infra-kubernetes.md) |

`file-transfer` is part of the Docker stack only; it is not migrated to
Kubernetes.

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
| Infrastructure | Terraform | EC2, security group, EBS volume, key pair | [`automation.md`](docker/automation.md) |
| Services | Docker Compose | Containers, networks, volumes | [`full-infra-docker.md`](docker/full-infra-docker.md) |

Terraform source: [`docker/automation/terraform/`](docker/automation/terraform/)

## Kubernetes implementation

The same stack runs on Amazon EKS and is packaged with Helm. A single cluster
hosts two logical environments, `full-infra-dev` and `full-infra-prod`,
separated by namespace and Helm values. The `full-infra` umbrella chart
composes the web-server, reverse-proxy and dns charts into one release, so the
whole stack is installed, upgraded and rolled back together.

Traefik is the single entry point: `ClusterIP` in dev, validated through
`kubectl port-forward`, and a `LoadBalancer` in prod. DNS stays internal to the
cluster.

| Layer | Tool | Scope | Doc |
|---|---|---|---|
| Infrastructure | Terraform | VPC, subnets, NAT, IAM, EKS cluster, managed node group, ECR repositories | [`automation.md`](kubernetes/automation.md) |
| Services | Helm | web-server, reverse-proxy and dns in one release | [`full-infra-kubernetes.md`](kubernetes/full-infra-kubernetes.md) |

Terraform owns the AWS layer and Helm owns the service layer, the same split
of responsibility as in the Docker runtime. Images are built and pushed
following [`full-infra-kubernetes.md`](kubernetes/full-infra-kubernetes.md).

Terraform source: [`kubernetes/automation/terraform/`](kubernetes/automation/terraform/)
(`cluster/` for the EKS platform, `registry/` for the ECR repositories — separate
states, because the registry outlives the cluster).
Umbrella chart: [`kubernetes/helm/full-infra/`](kubernetes/helm/full-infra/)

**Infrastructure & AWS native equivalent:** [`stacks/full-infra`](https://github.com/Bios-Mod/build-your-infra/tree/main/stacks/full-infra)
