#!/bin/bash
set -euo pipefail
exec > /var/log/user-data.log 2>&1

# ── Docker Engine & amd64 emulation ───────────────────────────────────────
apt-get update -y
# dns and file-transfer images are amd64 on a Graviton (arm64) host; install qemu-user-static before Compose starts
apt-get install -y ca-certificates curl gnupg git qemu-user-static

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable docker
systemctl start docker

# Allow ubuntu to run Docker without sudo on future SSH sessions (compose up below runs as root)
usermod -aG docker ubuntu

# ── Swap (1 GiB buffer for t4g.micro memory pressure and amd64 emulation) ─
if [ ! -f /swapfile ]; then
  fallocate -l 1G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
elif ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
  swapon /swapfile
fi
if ! grep -qE '^\s*/swapfile\s' /etc/fstab; then
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ── Free port 53 (systemd-resolved occupies it by default on Ubuntu 24.04) ──
mkdir -p /etc/systemd/resolved.conf.d/
cat > /etc/systemd/resolved.conf.d/no-stub.conf << 'RESOLVED'
[Resolve]
DNSStubListener=no
RESOLVED
systemctl restart systemd-resolved

# ── Repo ──────────────────────────────────────────────────────────────────
git clone https://github.com/Bios-Mod/containerize-your-infra.git \
  /home/ubuntu/containerize-your-infra

# ── TLS certificates for Traefik ──────────────────────────────────────────
mkdir -p /home/ubuntu/containerize-your-infra/modules/reverse-proxy/docker/configs/traefik/certs
openssl req -x509 -newkey rsa:4096 \
  -keyout /home/ubuntu/containerize-your-infra/modules/reverse-proxy/docker/configs/traefik/certs/lab.key \
  -out /home/ubuntu/containerize-your-infra/modules/reverse-proxy/docker/configs/traefik/certs/lab.crt \
  -days 365 -nodes -subj "/CN=localhost"

# ── Monitoring environment (.env) ─────────────────────────────────────────
ENV_FILE="/home/ubuntu/containerize-your-infra/stacks/full-infra/docker/.env"
if [ ! -f "$ENV_FILE" ]; then
  printf 'GRAFANA_ADMIN_PASSWORD=%s\n' "$(openssl rand -base64 18)" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  chown ubuntu:ubuntu "$ENV_FILE"
fi

# ── SSH keys for file-transfer ────────────────────────────────────────────
# Private keys are not versioned and are generated on first boot; the client
# private key stays on this host and host key fingerprints change if recreated.
FT_CFG="/home/ubuntu/containerize-your-infra/modules/file-transfer/docker/configs"
mkdir -p "$FT_CFG/ssh" "$FT_CFG/keys"

if [ -d "$FT_CFG/ssh/ssh_host_ed25519_key" ]; then
  rm -rf "$FT_CFG/ssh/ssh_host_ed25519_key"
fi
if [ ! -f "$FT_CFG/ssh/ssh_host_ed25519_key" ]; then
  ssh-keygen -q -t ed25519 -N "" -f "$FT_CFG/ssh/ssh_host_ed25519_key" </dev/null
fi

if [ -d "$FT_CFG/ssh/ssh_host_rsa_key" ]; then
  rm -rf "$FT_CFG/ssh/ssh_host_rsa_key"
fi
if [ ! -f "$FT_CFG/ssh/ssh_host_rsa_key" ]; then
  ssh-keygen -q -t rsa -b 4096 -N "" -f "$FT_CFG/ssh/ssh_host_rsa_key" </dev/null
fi

if [ -d "$FT_CFG/keys/labuser_ed25519" ]; then
  rm -rf "$FT_CFG/keys/labuser_ed25519"
fi
if [ ! -f "$FT_CFG/keys/labuser_ed25519" ]; then
  ssh-keygen -q -t ed25519 -N "" -f "$FT_CFG/keys/labuser_ed25519" </dev/null
fi

chmod 600 "$FT_CFG/ssh/ssh_host_ed25519_key" "$FT_CFG/ssh/ssh_host_rsa_key"

# Ensure ubuntu owns the repository so interactive git commands work without dubious ownership errors
chown -R ubuntu:ubuntu /home/ubuntu/containerize-your-infra

# ── Stack ─────────────────────────────────────────────────────────────────
cd /home/ubuntu/containerize-your-infra
docker compose -f stacks/full-infra/docker/docker-compose.prod.yml up -d
docker compose -f stacks/full-infra/docker/docker-compose.prod.yml ps
