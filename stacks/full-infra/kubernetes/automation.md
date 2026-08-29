
# Kubernetes Automation — EKS Foundation

**Terraform · Amazon EKS · Managed Node Group · containerize-your-infra**

---

## Introduction

This document covers the Terraform plan that provisions the EKS foundation for the Kubernetes implementation of this stack: VPC, public and private subnets, NAT Gateways, IAM roles, the EKS control plane, and a Managed Node Group. Terraform
creates the infrastructure layer only — it does not manage in-cluster Kubernetes objects. Namespaces are created manually with `kubectl` (Step 5), and Helm owns the service layer on top of this foundation, exactly the same split of responsibility already applied between Terraform and Docker Compose in 
`stacks/full-infra/docker/automation.md`.

Every resource in this plan mirrors, one for one, the manual AWS CLI procedure already validated and documented in `environments/kubernetes/dev/setup.md`. This Terraform automates what was already understood by hand — it does not introduce a new design.

> **Prerequisites:** AWS CLI configured with a profile that has EKS, EC2 and IAM
> permissions. Terraform >= 1.15.6 installed locally. `kubectl` installed locally.

---

## Terraform file layout

```bash
automation/terraform/
├── main.tf.example          # provider, VPC, subnets, NAT, IAM, EKS cluster, node group
├── variables.tf             # all input declarations
├── outputs.tf.example        # cluster endpoint, kubeconfig command, subnet/SG ids
└── terraform.tfvars.example  # copy to terraform.tfvars and fill in values
```

📄 [`automation/terraform/`](automation/terraform/)

---

## Step 1 — Initialize the working directory

### What was done

Terraform downloads the AWS provider plugin and sets up the local state backend.
Run this once from `automation/terraform/` before any other command.

```bash
cd stacks/full-infra/kubernetes/automation/terraform
cp main.tf.example main.tf
cp outputs.tf.example outputs.tf
terraform init
```

📄 [`automation/terraform/main.tf.example`](automation/terraform/main.tf.example)
📄 [`automation/terraform/outputs.tf.example`](automation/terraform/outputs.tf.example)

### Why

`terraform init` reads the `required_providers` block in `main.tf` and downloads the matching provider version into `.terraform/`. The state file (`terraform.tfstate`) is kept local — no remote backend, same lab-scoped decision already made for the Docker/EC2 automation. In a team or production context, state would live in S3 with DynamoDB locking.

### Verification

```bash
terraform init
# → Terraform has been successfully initialized!
# → provider registry.terraform.io/hashicorp/aws v6.x.x
```

---

## Step 2 — Configure variables

### What was done

Copy the example vars file and fill in the values for your environment. No secrets are hardcoded in any `.tf` file.

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`

📄 [`automation/terraform/terraform.tfvars.example`](automation/terraform/terraform.tfvars.example)

### Why

Separating variables from resource definitions is a non-negotiable Terraform practice. `terraform.tfvars` is listed in `.gitignore` — it never enters version control. The `.example` file documents every required input without exposing real values. `kubernetes_version` is pinned explicitly rather than left to "latest" so the cluster stays reproducible between destroy/apply cycles — the same reasoning applied
manually in `setup.md` Step 4.

> **Network pattern:** two public subnets (one NAT Gateway each) and two private
> subnets (worker nodes), across two AZs — the same production-correct pattern
> validated manually, not a cost-shortcut. Nodes never receive a public IP; outbound
> traffic goes through NAT. This costs roughly two NAT Gateways × $0.045/hour during
> the validation window, acceptable because the whole stack is destroyed afterward. 
>
> **AMI type:** `AL2023_ARM_64_STANDARD`, not `AL2_ARM_64`. AWS deprecated the AL2
> AMI family for EKS node groups — `AL2_ARM_64` is only valid for Kubernetes 1.32
> or earlier and is rejected by the API on newer versions with
> `InvalidParameterException`. `setup.md` Step 6 predates this constraint and still
> shows `AL2_ARM_64` in its example command — that line is now stale, not a deliberate divergence from this Terraform.
>
> **No custom security group is created.** EKS attaches its own cluster security
> group automatically to the control plane and every node, with the correct rules
> for node ↔ control-plane traffic already in place. See Step 5 below.

### Verification

```bash
terraform fmt
terraform validate
# → Success! The configuration is valid.
```

---

## Step 3 — Review the execution plan

### What was done

Generate a dry-run plan and review every resource Terraform will create before anything touches AWS.

```bash
# Save the plan to a file — guarantees apply executes exactly what was reviewed
terraform plan -out full-infra-eks.tfplan
```

### Why

`terraform plan` compares the desired state (your `.tf` files) against the current state (the state file) and shows exactly what will be created, modified, or destroyed — the same gate already applied before touching the EC2 host in the Docker automation. Passing the saved plan file to `apply` guarantees no drift between the two steps. `full-infra-eks.tfplan` is gitignored (`*.tfplan`) and never committed.

---

## Step 4 — Apply the plan

### What was done

Terraform creates every resource in AWS, in dependency order, and writes the resulting state to `terraform.tfstate`. The EKS control plane and Managed Node Group take several minutes each to reach `ACTIVE`.

```bash
terraform apply full-infra-eks.tfplan
```

### Why

`terraform apply` executes exactly what `plan` described — nothing more. Terraform resolves the dependency graph itself: VPC and subnets first, then NAT Gateways and route tables, then IAM roles, then the EKS cluster, then the node group — the same order followed manually in `setup.md`, now expressed declaratively instead of as a sequence of individual AWS CLI calls.

### Verification

```bash
terraform apply
# → Apply complete! Resources: N added, 0 changed, 0 destroyed.

terraform output
# → cluster_name       = "full-infra"
# → cluster_endpoint   = "https://....eks.amazonaws.com"
# → kubeconfig_command = "aws eks update-kubeconfig --name full-infra --region eu-west-1 --profile default"
```

---

## Step 5 — Verify the cluster and configure kubectl

### What was done

Configure local `kubectl` access and confirm the control plane, node group, and cluster security group all match what was validated manually.

```bash
$(terraform output -raw kubeconfig_command)
kubectl cluster-info
kubectl get nodes -o wide
kubectl get nodes -L topology.kubernetes.io/zone
```

### Why

`aws eks update-kubeconfig` writes a context that shells out to the AWS CLI for authentication — no static credential is stored. Checking node distribution across `topology.kubernetes.io/zone` confirms the Managed Node Group actually spread its two nodes across both AZs, not just requested it. The cluster security group is not recreated here — the output `cluster_security_group_id` only confirms the one EKS
already attached automatically.

### Node access check

Managed Node Groups have no SSH key configured (`remote_access` is intentionally
omitted from `aws_eks_node_group.main` — nodes are not meant to be SSH'd into
directly). The equivalent of the Docker Step 5 SSH check is a debug session
attached directly to the node's host namespace:

```bash
kubectl debug node/<node-name> -it --image=busybox
# → drops into a shell chrooted at /host, running on that exact node

chroot /host
cat /etc/os-release
# → confirms the node OS/AMI matches AL2023 ARM64
exit
exit
```

### Why

`kubectl debug node` creates an ephemeral pod scheduled on that specific node with
its root filesystem mounted at `/host` — it proves the node is not just reporting
`Ready` to the API server, but is actually schedulable and reachable through the
cluster's own networking, the functional equivalent of SSHing into the Docker/EC2
host. No SSH key, bastion, or Session Manager setup is needed for this check.

> Namespaces are **not** created by this Terraform. Run this once, manually, after
> the cluster is `ACTIVE`:
>
> ```bash
> kubectl create namespace full-infra-dev
> kubectl create namespace full-infra-prod
> kubectl create namespace ingress-system
> ```
>
> Terraform provisions AWS infrastructure only; mixing an AWS provider and a
> Kubernetes/Helm provider in the same state for three static namespaces isn't
> justified in this milestone — see `AGENTS.md`.

### Verification

```bash
kubectl get nodes
# → 2 nodes, STATUS Ready

kubectl get ns
# → full-infra-dev, full-infra-prod, ingress-system, plus default system namespaces
```

---

## Step 6 — Destroy the infrastructure

### What was done

Tear down every resource created by this plan, in the correct dependency order.

```bash
terraform destroy
```

Type `yes` when prompted.

### Why

`terraform destroy` reads the state file and deletes every resource it created — node group first, then the cluster, then NAT Gateways, Elastic IPs, route tables, Internet Gateway, subnets, VPC, and finally both IAM roles — the exact reverse dependency order followed manually in `setup.md` Step 9, now automatic. This is the clean-up step that avoids leaving EKS (~$0.10/hour), NAT Gateways (~$0.045/hour each), and EC2 nodes accumulating cost.

### Verification

```bash
terraform destroy
# → Destroy complete! Resources: N destroyed.

terraform show
# → The state file is empty. No resources.

aws eks list-clusters --query 'clusters'
# → []
```
