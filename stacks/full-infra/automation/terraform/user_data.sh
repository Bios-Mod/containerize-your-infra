#!/bin/bash
set -euo pipefail
exec > /var/log/user-data.log 2>&1

# ── Docker Engine ─────────────────────────────────────────────────────────
apt-get update -y
apt-get install -y ca-certificates curl gnupg git

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
openssl req -x509 -newkey rsa:4096 \
  -keyout /home/ubuntu/containerize-your-infra/modules/reverse-proxy/configs/traefik/certs/lab.key \
  -out /home/ubuntu/containerize-your-infra/modules/reverse-proxy/configs/traefik/certs/lab.crt \
  -days 365 -nodes -subj "/CN=localhost"

# ── Stack ─────────────────────────────────────────────────────────────────
cd /home/ubuntu/containerize-your-infra
docker compose -f stacks/full-infra/docker-compose.prod.yml up -d