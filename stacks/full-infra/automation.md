# Full Infrastructure Stack — Automation

**Terraform · EC2 · Ubuntu 24.04 LTS · Docker Engine · containerize-your-infra**

---

## Introduction

This document covers the Terraform plan that provisions the EC2 host for the
full infrastructure stack. Terraform creates the infrastructure layer: instance,
network access, storage, and key pair. Once the host is up, a `user_data` script
takes over: it installs Docker Engine, clones this repository, and launches the
Compose stack.

The two layers are explicitly separated. Terraform does not know which containers
run on the host. Docker Compose does not know how the host was provisioned.
Changing one does not require touching the other.

> **Prerequisites:** AWS CLI configured with a profile that has EC2 and IAM
> permissions. Terraform >= 1.6 installed locally. An existing key pair name
> in the target region, or use the key pair resource in this plan.

---

## Terraform file layout

```bash
automation/terraform/
├── main.tf # provider, EC2, SG, EBS
├── variables.tf # all input declarations
├── outputs.tf # instance public IP, instance ID
├── terraform.tfvars.example # copy to terraform.tfvars and fill in values
└── user_data.sh # runs on first boot: Docker + clone + compose up
```

📄 [`automation/terraform/`](automation/terraform/)

---

## Step 1 — Initialize the working directory

### What was done

Terraform downloads the AWS provider plugin and sets up the local state backend.
Run this once from `automation/terraform/` before any other command.

```bash
cd stacks/full-infra/automation/terraform
terraform init
```

### Why

`terraform init` reads the `required_providers` block in `main.tf` and downloads
the matching provider version into `.terraform/`. Without this step, no Terraform
command will run. The state file (`terraform.tfstate`) is kept local — there is
no remote backend in this lab. In a team or production context, state would live
in S3 with DynamoDB locking.

### Verification

```bash
terraform init
# → Terraform has been successfully initialized!
# → provider registry.terraform.io/hashicorp/aws v5.x.x
```

---

## Step 2 — Configure variables

### What was done

Copy the example vars file and fill in the values for your environment. No
secrets are hardcoded in any `.tf` file.

```bash
mv terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
aws_region       = "eu-west-1"
instance_type    = "t4g.micro"
ami_id           = "ami-xxxxxxxxxxxxxxxxx"   # Ubuntu 24.04 LTS ARM64 in your region
key_name         = "your-existing-key-pair"
allowed_ssh_cidr = "YOUR_PUBLIC_IP/32"
repo_url         = "https://github.com/Bios-Mod/containerize-your-infra.git"
```

📄 [`automation/terraform/terraform.tfvars.example`](automation/terraform/terraform.tfvars.example)

### Why

Separating variables from resource definitions is a non-negotiable Terraform
practice. `terraform.tfvars` is listed in `.gitignore` — it never enters version
control. The `.example` file documents every required input without exposing
real values. `allowed_ssh_cidr` restricts port 22 to your IP only — the security
group does not open SSH to `0.0.0.0/0` under any circumstance.

> **Generate an SSH key pair for this lab before filling in the vars file:**
> ```bash
> ssh-keygen -t ed25519 -f ~/.ssh/containerize-lab -C "containerize-lab"
> ```
> The public key (`~/.ssh/containerize-lab.pub`) goes into `terraform.tfvars`
> as the value of `public_key`. The private key stays on your machine and is
> used to SSH into the instance after `apply`.
>
> **`terraform.tfvars` is gitignored.** Never commit it. It may contain your
> AWS region and IP. The `.example` file is what lives in the repo.
>
> **Port 22 is open to `0.0.0.0/0`** — the lab operator has a dynamic IP
> (ISP DHCP lease), making a fixed CIDR impractical. In a production environment
> SSH access would be restricted to a corporate CIDR block or replaced entirely
> with AWS Systems Manager Session Manager. This is an explicit documented
> decision, not an oversight.

---

## Step 3 — Review the execution plan

### What was done

Generate a dry-run plan and review every resource Terraform will create before
anything touches AWS.

```bash
# Save the plan to a file — guarantees apply executes exactly what was reviewed
terraform plan -out containerize.tfplan
```

### Why

`terraform plan` compares the desired state (your `.tf` files) against the
current state (the state file) and shows exactly what will be created, modified,
or destroyed. Running plan before apply is not optional — it is the gate that
prevents unintended changes. In build-your-infra the equivalent step was reading
through a shell script before executing it; here Terraform makes that diff
explicit and structured.
Passing the saved plan file to `apply` guarantees that what executes is
exactly what was reviewed in `plan` — no drift between the two steps.
`containerize.tfplan` is gitignored (`*.tfplan`) and never committed.

### Verification

```bash
terraform plan
# → Plan: 8 to add, 0 to change, 0 to destroy.
# → (EC2 instance, security group, EBS volume, key pair)
```

---

## Step 4 — Apply the plan

### What was done

Terraform creates all resources in AWS and writes the resulting state to
`terraform.tfstate`. The EC2 instance boots and executes `user_data.sh`
automatically on first start.

```bash
terraform apply containerize.tfplan
```

### Why

`terraform apply` executes exactly what `plan` described — nothing more. The
`user_data` script is injected into the instance at launch by the AWS API as
instance metadata. The script runs as root on first boot via `cloud-init`,
installs Docker Engine from the official Docker APT repository, clones this
repo, and runs `docker compose -f stacks/full-infra/docker-compose.prod.yml up -d`.

This is the handoff point between layers: Terraform's job ends when the
instance is running. Docker Compose's job begins inside that instance.

> **`user_data` runs only once** — on the first boot after instance creation.
> If you need to re-run it, terminate the instance and apply again, or SSH in
> and run the script manually.

### Verification

```bash
terraform apply
# → Apply complete! Resources: 4 added, 0 changed, 0 destroyed.

terraform output
# → instance_public_ip = "X.X.X.X"
# → instance_id        = "i-xxxxxxxxxxxxxxxxx"
```

---

## Step 5 — Verify the stack on the remote host

### What was done

SSH into the instance and confirm that `user_data.sh` completed successfully:
Docker Engine is running, the repo is cloned, and all four containers are up
and healthy.

> **Wait 2–3 minutes after `apply` completes** before SSHing in. `cloud-init`
> runs `user_data.sh` asynchronously after the instance reaches running state.
> The instance is reachable before the script finishes.

```bash
ssh -i ~/.ssh/your-key.pem ubuntu@$(terraform output -raw instance_public_ip)
```

Once inside the instance:

```bash
# cloud-init log — confirm user_data ran without errors
sudo cat /var/log/cloud-init-output.log | tail -30
# → ...
# → Successfully started all containers

# Repo was cloned
ls ~/containerize-your-infra/
# → AGENTS.md  README.md  modules/  stacks/  ...

# ── Docker ────────────────────────────────────────────────────────────────
docker --version
# → Docker version 27.x.x

# Docker Engine is running
sudo systemctl status docker --no-pager
# → Active: active (running)

# ── Containers ────────────────────────────────────────────────────────────
cd /home/ubuntu/containerize-your-infra
sudo docker compose -f stacks/full-infra/docker-compose.prod.yml ps
# → traefik         Up X minutes (healthy)
# → web-server      Up X minutes (healthy)
# → file-transfer   Up X minutes (healthy)
# → dns             Up X minutes (healthy)

# ── Web server — HTTP redirect ─────────────────────────────────────────────
curl -s -o /dev/null -w "%{http_code}\n" http://$(curl -s ifconfig.me)
# → 404 or 301

# ── Traefik dashboard ──────────────────────────────────────────────────────
curl -sk -o /dev/null -w "%{http_code}\n" \
  --resolve traefik.localhost:443:127.0.0.1 \
  https://traefik.localhost/dashboard/
# → 401  (auth challenge — Traefik está vivo)

# ── DNS ────────────────────────────────────────────────────────────────────
dig @127.0.0.1 dns.lab.local +short
# → 172.21.0.10

# ── File transfer ──────────────────────────────────────────────────────────
nc -zv 127.0.0.1 2222
# → Connection to 127.0.0.1 2222 port [tcp/*] succeeded!
```

### Why

`user_data.sh` execution is not confirmed by Terraform — Terraform considers
the instance ready as soon as the AWS API reports it running. The only source
of truth for what happened during first boot is `/var/log/cloud-init-output.log`.
Checking it here closes the loop between infrastructure provisioning and service
deployment.

**TLS certificates** are not committed to the repository — they are generated
automatically by `user_data.sh` after cloning the repo and before the stack
starts. `openssl` generates a self-signed certificate valid for `localhost`.
Traefik loads it at startup from `modules/reverse-proxy/configs/traefik/certs/`.
The `404` on `https://localhost/dashboard/` is expected — the dashboard router
rule matches `traefik.localhost`, not the bare IP or `localhost`.

---

## Step 6 — Destroy the infrastructure

### What was done

Tear down all resources created by this plan. The named Docker volumes on the
EBS volume are lost unless a snapshot was taken first.

```bash
terraform destroy
```

Type `yes` when prompted.

### Why

`terraform destroy` reads the state file and deletes every resource it created,
in the correct dependency order. In a lab context this is the clean-up step —
it avoids leaving a running EC2 instance accumulating cost. The EBS volume is
also destroyed unless `skip_destroy = true` is set on the volume resource.

In build-your-infra the equivalent was `sudo poweroff` on the VM. Here
Terraform guarantees that every AWS resource — not just the instance — is
removed: security group, key pair, volume. No orphaned resources.

> **Named volumes live on the instance's EBS.** `terraform destroy` terminates
> the instance and deletes the volume. If you need to preserve uploaded files
> or DNS zone data, snapshot the EBS volume before destroying.

### Verification

```bash
terraform destroy
# → Destroy complete! Resources: 4 destroyed.

# Confirm no resources remain
terraform show
# → The state file is empty. No resources.
```