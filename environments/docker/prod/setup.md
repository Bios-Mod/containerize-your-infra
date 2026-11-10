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

> **Automated EC2 provisioning:** the Terraform bootstrap
> ([`stacks/full-infra/docker/automation.md`](../../../stacks/full-infra/docker/automation.md))
> runs these host setup steps automatically on first boot via `user_data.sh`
> and launches the full Docker stack.

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

## Step 4 — Cross-architecture images (ARM64 hosts)

### What was done

Some images in this lab — `internetsystemsconsortium/bind9:9.20` (`dns`) and
`atmoz/sftp:alpine` (`file-transfer`) — publish `linux/amd64` manifests only.
On EC2 `t4g.micro` (Graviton / ARM64) these images require persistent QEMU
user-mode emulation before deploying any module or stack that uses them.

```bash
sudo apt-get update
sudo apt-get install -y qemu-user-static
```

### Why

Ubuntu 24.04 on ARM64 does not include `x86_64` emulation out of the box.
Without a registered `binfmt_misc` handler, the kernel rejects `amd64`
containers (`dns` and `file-transfer`) with `exec format error`.

Installing `qemu-user-static` registers QEMU binary format handlers under
`/proc/sys/fs/binfmt_misc` via `systemd-binfmt`, so emulation persists across
host reboots and Docker daemon restarts. Where possible, modules use images
with native ARM64 builds in `docker-compose.prod.yml` to avoid this overhead;
`qemu-user-static` covers the remaining `amd64`-only services.

### Verification

```bash
ls /proc/sys/fs/binfmt_misc | grep -i qemu
# → qemu-x86_64  (among others)

# Confirm an amd64-only image runs without exec format error
docker run --rm --platform linux/amd64 alpine uname -m
# → x86_64
```

---

## Step 5 — Configure swapfile (EC2 t4g.micro)

### What was done

Create a persistent `1 GiB` `/swapfile`, enable it immediately, and add it to
`/etc/fstab` so it stays active across reboots.

```bash
if [ ! -f /swapfile ]; then
  sudo fallocate -l 1G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
elif ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
  sudo swapon /swapfile
fi
if ! grep -qE '^\s*/swapfile\s' /etc/fstab; then
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
fi
```

### Why

An EC2 `t4g.micro` provides `1 GiB` of RAM, which runs tight when hosting the
full 9-container stack alongside `qemu-user-static` emulation for the `amd64`
services (`dns` and `file-transfer`). A `1 GiB` swapfile provides memory
headroom against container restarts and kernel OOM kills. Permission `600`
restricts access to root, and `/etc/fstab` preserves swap across reboots.

### Verification

```bash
swapon --show
# → NAME      TYPE  SIZE USED PRIO
# → /swapfile file 1024M   0B   -2

grep '/swapfile' /etc/fstab
# → /swapfile none swap sw 0 0
```

---

## Step 6 — Free port 53 on Ubuntu 24.04 (`systemd-resolved`)

### What was done

Disable `systemd-resolved`'s local DNS stub listener when preparing the host for
the `dns` module or the full stack, freeing port `53` TCP/UDP on the host.

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d/
sudo tee /etc/systemd/resolved.conf.d/no-stub.conf << 'EOF'
[Resolve]
DNSStubListener=no
EOF
sudo systemctl restart systemd-resolved
```

### Why

Ubuntu 24.04 LTS enables `systemd-resolved`'s stub listener on port `53`
(`127.0.0.53:53`) by default, which causes the `dns` container to fail with an
`address already in use` port-binding error. Writing a drop-in configuration
under `/etc/systemd/resolved.conf.d/` frees port `53` without modifying the
package-managed `/etc/systemd/resolved.conf`.

### Verification

```bash
ss -tuln | grep ':53 ' || true
# → (no output — port 53 is free for the dns container)
```

---