# prod — Setup

Ubuntu 24.04 LTS with Docker Engine as the container runtime.
Target hosts: EC2 t4g.micro (ARM64) or local VM (x86_64 / ARM64).

---

## Environment

| Parameter | Value |
|---|---|
| OS | Ubuntu 24.04 LTS |
| Architecture | ARM64 (EC2 t4g.micro / Graviton2) · x86_64 (local VM) |
| Runtime | Docker Engine |
| Compose | docker compose v2 (plugin) |

---

## Prerequisites

This guide covers Docker Engine installation only. For instance provisioning,
user setup, SSH hardening, and firewall configuration, follow the corresponding
guide in [build-your-infra](https://github.com/Bios-Mod/build-your-infra):

- Local VM → [`environments/local/local-vm-setup.md`](https://github.com/Bios-Mod/build-your-infra/blob/main/environments/local/local-vm-setup.md)
- EC2 → [`environments/vps/vps-ec2-setup.md`](https://github.com/Bios-Mod/build-your-infra/blob/main/environments/vps/vps-ec2-setup.md)

Complete those guides before continuing here.

---

## Step 1 — Install Docker Engine

### What was done

Install Docker Engine and the Compose v2 plugin from Docker's official APT
repository.

```bash
# Remove any conflicting packages
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt remove -y $pkg 2>/dev/null
done

# Add Docker's official GPG key and repository
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Engine + Compose plugin
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

### Why

Docker Engine is installed from Docker's official repository, not from the
Ubuntu default packages. The Ubuntu package (`docker.io`) lags several minor
versions behind and does not include the Compose v2 plugin — it ships the
deprecated standalone `docker-compose` binary instead.

The Compose v2 plugin (`docker compose`) is the current standard. It is
distributed as a Docker CLI plugin and invoked as a subcommand, not a
standalone binary. All modules in this lab use `docker compose` exclusively.

### Verification

```bash
docker version
# → Client and Server both present — confirms Engine is running

docker compose version
# → Docker Compose version v2.x.x
```

---

## Step 2 — Post-install: run Docker as non-root

### What was done

Add the current user to the `docker` group so that `docker` commands do not
require `sudo`.

```bash
sudo usermod -aG docker $USER
# Log out and back in — group membership is evaluated at login
```

### Why

Running `docker` as root is the default after installation. Adding the user
to the `docker` group grants socket access without `sudo`. This is the
standard post-install step for any server that will run Docker commands
interactively or via CI.

> **Note:** membership in the `docker` group is equivalent to root-level access
> to the host. Only add trusted users.

### Verification

```bash
# After re-login — no sudo required
docker run --rm hello-world
# → Hello from Docker!
```

---

## Step 3 — Clone the repository

### What was done

Clone the repository to the production host.

```bash
git clone https://github.com/Bios-Mod/containerize-your-infra.git
cd containerize-your-infra
```

### Why

All module paths in this lab are relative to the repository root. Working
from inside the cloned directory ensures every `docker compose` command
resolves config files and volume paths correctly.

### Verification

```bash
ls
# → README.md  modules/  environments/  stacks/  ...
```

---

**Next:** deploy a module using its `docker-compose.prod.yml`, or deploy the
full stack from [`stacks/full-infra/`](../../stacks/full-infra/README.md).