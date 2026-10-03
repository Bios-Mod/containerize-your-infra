# Kubernetes Automation — EKS Platform and Registry

**Terraform · Amazon EKS · Managed Node Group · Amazon ECR · containerize-your-infra**

---

## Introduction

This document covers the Terraform that provisions the AWS layer of the Kubernetes implementation of this stack. It is split into two independent states:

- **`cluster/`** — VPC, public and private subnets, NAT Gateways, IAM roles, the EKS control plane and a Managed Node Group.
- **`registry/`** — the Amazon ECR repositories for the custom `web-server` and `dns` images.

Terraform creates the infrastructure layer only — it does not manage in-cluster Kubernetes objects or container images. Namespaces are created manually with `kubectl` (Step 5), images are built and pushed, and Helm owns the service layer on top of this foundation, following [`full-infra-kubernetes.md`](full-infra-kubernetes.md). It is the same split of responsibility already applied between Terraform and Docker Compose in [`stacks/full-infra/docker/automation.md`](../docker/automation.md).

> **Scope:** the service layer — images, production guardrails, Secrets and the Helm release — is deployed by following [`full-infra-kubernetes.md`](full-infra-kubernetes.md) step by step. Automating that layer is not covered here; it is the subject of a later iteration of the repository, with Ansible.

Every resource in the cluster plan mirrors, one for one, the manual AWS CLI procedure already validated and documented in [`environments/kubernetes/dev/setup.md`](../../../environments/kubernetes/dev/setup.md). This Terraform automates what was already understood by hand — it does not introduce a new design.

> **Prerequisites:** AWS CLI configured with a profile that has EKS, EC2, IAM and ECR permissions. Terraform >= 1.15.6 installed locally. `kubectl` installed locally.

---

## Terraform file layout

```bash
automation/terraform/
├── cluster/
│   ├── main.tf.example           # provider, VPC, subnets, NAT, IAM, EKS cluster, node group
│   ├── variables.tf              # all input declarations
│   ├── outputs.tf.example        # cluster endpoint, kubeconfig command, subnet/SG ids
│   └── terraform.tfvars.example  # copy to terraform.tfvars and fill in values
└── registry/
    ├── providers.tf              # provider and version constraints
    ├── ecr.tf                    # web-server and dns repositories, lifecycle policies
    ├── variables.tf              # region, profile, repository names, tag mutability
    ├── outputs.tf                # repository URLs and ARNs
    └── terraform.tfvars.example  # copy to terraform.tfvars and fill in values
```

📄 [`automation/terraform/cluster/`](automation/terraform/cluster/)
📄 [`automation/terraform/registry/`](automation/terraform/registry/)

---

## Step 1 — Initialize the cluster working directory

### What was done

Terraform downloads the AWS provider plugin and sets up the local state backend. Run this once from `automation/terraform/cluster/` before any other command.

```bash
cd stacks/full-infra/kubernetes/automation/terraform/cluster
cp main.tf.example main.tf
cp outputs.tf.example outputs.tf
terraform init
```

📄 [`automation/terraform/cluster/main.tf.example`](automation/terraform/cluster/main.tf.example)
📄 [`automation/terraform/cluster/outputs.tf.example`](automation/terraform/cluster/outputs.tf.example)

### Why

`terraform init` reads the `required_providers` block in `main.tf` and downloads the matching provider version into `.terraform/`. The state file (`terraform.tfstate`) is kept local — no remote backend, same lab-scoped decision already made for the Docker/EC2 automation. In a team or production context, state would live in S3 with locking.

The `.example` files are copied to their working names so the committed files carry no account-specific values.

### Verification

```bash
terraform init
# → Terraform has been successfully initialized!
# → provider registry.terraform.io/hashicorp/aws v6.x.x
```

---

## Step 2 — Configure the cluster variables

### What was done

Copy the example vars file and fill in the values for your environment. No secrets are hardcoded in any `.tf` file.

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`.

📄 [`automation/terraform/cluster/terraform.tfvars.example`](automation/terraform/cluster/terraform.tfvars.example)

### Why

Separating variables from resource definitions is a non-negotiable Terraform practice. `terraform.tfvars` is listed in `.gitignore` — it never enters version control. The `.example` file documents every required input without exposing real values. `kubernetes_version` is pinned explicitly rather than left to "latest" so the cluster stays reproducible between destroy/apply cycles — the same reasoning applied manually in `setup.md` Step 4.

> **Network pattern:** two public subnets (one NAT Gateway each) and two private subnets (worker nodes), across two AZs — the same production-correct pattern validated manually, not a cost-shortcut. Nodes never receive a public IP; outbound traffic goes through NAT. This costs roughly two NAT Gateways × $0.045/hour during the validation window, acceptable because the whole stack is destroyed afterward.
>
> **AMI type:** `AL2023_ARM_64_STANDARD`, not `AL2_ARM_64`. AWS deprecated the AL2 AMI family for EKS node groups — `AL2_ARM_64` is only valid for Kubernetes 1.32 or earlier and is rejected by the API on newer versions with `InvalidParameterException`.
>
> **No custom security group is created.** EKS attaches its own cluster security group automatically to the control plane and every node, with the correct rules for node ↔ control-plane traffic already in place. See Step 5 below.

### Verification

```bash
terraform fmt
terraform validate
# → Success! The configuration is valid.
```

---

## Step 3 — Review the cluster execution plan

### What was done

Generate a dry-run plan and review every resource Terraform will create before anything touches AWS.

```bash
# Save the plan to a file — guarantees apply executes exactly what was reviewed
terraform plan -out full-infra-eks.tfplan
```

### Why

`terraform plan` compares the desired state (your `.tf` files) against the current state (the state file) and shows exactly what will be created, modified, or destroyed — the same gate already applied before touching the EC2 host in the Docker automation. Passing the saved plan file to `apply` guarantees no drift between the two steps. `full-infra-eks.tfplan` is gitignored (`*.tfplan`) and never committed.

### Verification

```bash
terraform plan -out full-infra-eks.tfplan
# → Plan: N to add, 0 to change, 0 to destroy.
```

---

## Step 4 — Apply the cluster plan

### What was done

Terraform creates every resource in AWS, in dependency order, and writes the resulting state to `terraform.tfstate`. The EKS control plane and Managed Node Group take several minutes each to reach `ACTIVE`.

```bash
terraform apply full-infra-eks.tfplan
```

### Why

`terraform apply` executes exactly what `plan` described — nothing more. Terraform resolves the dependency graph itself: VPC and subnets first, then NAT Gateways and route tables, then IAM roles, then the EKS cluster, then the node group — the same order followed manually in `setup.md`, now expressed declaratively instead of as a sequence of individual AWS CLI calls.

### Verification

```bash
terraform output
# → cluster_name       = "full-infra"
# → cluster_endpoint   = "https://....eks.amazonaws.com"
# → kubeconfig_command = "aws eks update-kubeconfig --name full-infra --region eu-west-1 --profile default"
```

---

## Step 5 — Verify the cluster and configure kubectl

### What was done

Configure local `kubectl` access, confirm the control plane, node group, and cluster security group all match what was validated manually, and create the namespaces.

```bash
$(terraform output -raw kubeconfig_command)
kubectl cluster-info
kubectl get nodes -o wide
kubectl get nodes -L topology.kubernetes.io/zone

kubectl create namespace full-infra-dev
kubectl create namespace full-infra-prod
kubectl create namespace ingress-system
```

### Why

`aws eks update-kubeconfig` writes a context that shells out to the AWS CLI for authentication — no static credential is stored. Checking node distribution across `topology.kubernetes.io/zone` confirms the Managed Node Group actually spread its two nodes across both AZs, not just requested it. The cluster security group is not recreated here — the output `cluster_security_group_id` only confirms the one EKS already attached automatically.

Namespaces are **not** created by this Terraform. They are three static objects, and mixing an AWS provider and a Kubernetes provider in the same state for them is not justified: Terraform provisions AWS infrastructure only.

### Node access check

Managed Node Groups have no SSH key configured (`remote_access` is intentionally omitted from `aws_eks_node_group.main` — nodes are not meant to be SSH'd into directly). The equivalent of the Docker Step 5 SSH check is a debug session attached directly to the node's host namespace:

```bash
kubectl debug node/<node-name> -it --image=busybox
# → drops into a shell chrooted at /host, running on that exact node

chroot /host
cat /etc/os-release
# → confirms the node OS/AMI matches AL2023 ARM64
exit
exit
```

`kubectl debug node` creates an ephemeral pod scheduled on that specific node with its root filesystem mounted at `/host` — it proves the node is not just reporting `Ready` to the API server, but is actually schedulable and reachable through the cluster's own networking, the functional equivalent of SSHing into the Docker/EC2 host. No SSH key, bastion, or Session Manager setup is needed for this check.

> The debug Pod is left in the `default` namespace. Delete it once the check is done: `kubectl delete pod -l app=debug` is not applicable here — use `kubectl get pods` to find the `node-debugger-*` Pod and delete it by name.

### Verification

```bash
kubectl get nodes
# → 2 nodes, STATUS Ready

kubectl get ns
# → full-infra-dev, full-infra-prod, ingress-system, plus default system namespaces
```

---

## Step 6 — Provision the registry

### What was done

The ECR repositories for the `web-server` and `dns` images are created from their own Terraform state, independent from the cluster.

```bash
cd ../registry
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform fmt -check
terraform validate
terraform plan -out registry.tfplan
terraform apply registry.tfplan
```

Edit `terraform.tfvars` before the plan.

📄 [`automation/terraform/registry/ecr.tf`](automation/terraform/registry/ecr.tf) — `aws_ecr_repository` and lifecycle policy for `web-server` and `dns`
📄 [`automation/terraform/registry/variables.tf`](automation/terraform/registry/variables.tf) — region, profile, repository names, tag mutability
📄 [`automation/terraform/registry/outputs.tf`](automation/terraform/registry/outputs.tf) — repository URLs and ARNs

### Why

The registry has its own state because its lifecycle is independent from the cluster's: the repositories and their images can survive any number of cluster destroy and apply cycles, and destroying them is a separate, deliberate act. Mixing both in one state would force a registry recreation, and a full rebuild and push of the images, every time the cluster is torn down.

One repository per image keeps tags and lifecycle independent. Four settings are deliberate:

- `image_tag_mutability = "IMMUTABLE"`: a tag can never be overwritten, so a deployed tag always points to the same image. This is what makes `helm rollback` meaningful.
- `scan_on_push = true`: every pushed image is scanned for known vulnerabilities at no extra operational cost.
- A lifecycle policy expires untagged images after 7 days, so abandoned layers do not accumulate.
- `force_delete = true`: `terraform destroy` removes a repository even if it still holds images. It is appropriate for a lab that is destroyed after each session; a production registry would not set it.

Terraform owns the repositories only. The images are built and pushed following [`full-infra-kubernetes.md`](full-infra-kubernetes.md) — building a container is application delivery, not infrastructure, and a Terraform-managed push would try to re-push an existing tag whenever the build context changes, which immutable tags reject.

### Verification

```bash
terraform plan -out registry.tfplan
# → Plan: 4 to add, 0 to change, 0 to destroy.   (two repositories, two lifecycle policies)

terraform output
# → repository_url     = "<account-id>.dkr.ecr.eu-west-1.amazonaws.com/containerize-your-infra/web-server"
# → repository_arn     = "arn:aws:ecr:eu-west-1:<account-id>:repository/containerize-your-infra/web-server"
# → dns_repository_url = "<account-id>.dkr.ecr.eu-west-1.amazonaws.com/containerize-your-infra/dns"
# → dns_repository_arn = "arn:aws:ecr:eu-west-1:<account-id>:repository/containerize-your-infra/dns"

aws ecr describe-repositories --region eu-west-1 --query 'repositories[].[repositoryName,imageTagMutability]' --output text
# → containerize-your-infra/web-server  IMMUTABLE
# → containerize-your-infra/dns         IMMUTABLE
```

---

## Step 7 — Destroy the infrastructure

### What was done

Tear down every resource created by this document, in the correct dependency order. If the `full-infra` release is installed, uninstall it first, as described in the Teardown of [`full-infra-kubernetes.md`](full-infra-kubernetes.md).

```bash
cd stacks/full-infra/kubernetes/automation/terraform/cluster
terraform destroy

cd ../registry
terraform destroy
```

Type `yes` when prompted, in each directory.

### Why

`terraform destroy` reads the state file and deletes every resource it created. In the cluster state: node group first, then the cluster, then NAT Gateways, Elastic IPs, route tables, Internet Gateway, subnets, VPC, and finally both IAM roles — the exact reverse dependency order followed manually in `setup.md` Step 9, now automatic. This is the clean-up step that avoids leaving EKS (~$0.10/hour), NAT Gateways (~$0.045/hour each), and EC2 nodes accumulating cost.

The release must be uninstalled before the cluster is destroyed. The Traefik `LoadBalancer` Service provisions an AWS Classic ELB that Terraform does not track: destroying the cluster first would orphan it, leaving a billable resource that blocks the deletion of the VPC subnets.

The registry is destroyed last and separately because it has its own state. With `force_delete`, both repositories are removed together with their images; the next cycle starts from zero.

### Verification

```bash
terraform show
# → The state file is empty. No resources are represented.
# (in each directory)

aws eks list-clusters --region eu-west-1 --query 'clusters'
# → []

aws ecr describe-repositories --region eu-west-1 --query 'repositories[].repositoryName'
# → []

aws elb describe-load-balancers --region eu-west-1 --query 'LoadBalancerDescriptions[]'
# → []
```
