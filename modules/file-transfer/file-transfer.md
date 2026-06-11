# File Transfer — containerize-your-infra

**Docker Engine · atmoz/sftp:alpine**

---

## Introduction

This document covers the deployment of an SFTP server inside a Docker container
using `atmoz/sftp`. The service exposes port 2222 on the host and maps it to
port 22 inside the container. Authentication uses SSH keys exclusively — no
password auth.

This module is the direct container equivalent of the OpenSSH SFTP subsystem
deployed in build-your-infra. The protocol, the chroot pattern, and the key
management model are identical. What changes is the runtime boundary: instead
of a systemd-managed sshd process, the service runs as a containerized OpenSSH
daemon with its lifecycle owned by Compose.

> **Port 22 is not used on the host.** The container's sshd listens on 22
> internally. The host mapping is 2222 → 22 to avoid conflicts with the host's
> own SSH daemon.

> **Config files in `configs/`** contain only the files added by this module.
> The path inside the module folder is referenced after each deploy block.

---

## Environment

| Parameter    | Value                                              |
|--------------|----------------------------------------------------|
| Image        | `atmoz/sftp:alpine`                                |
| Port         | 2222 → 22 (SFTP)                                  |
| Auth         | SSH key only — password disabled                   |
| User         | `labuser` — UID 1001, chrooted to `/home/labuser` |
| Upload dir   | `/home/labuser/upload` (bind mount in dev)         |
| Host keys    | Persisted via bind mount — stable fingerprint      |

---

## Before You Start — Image Exploration (optional)

These commands inspect the image before any Compose deployment. Nothing here
affects the module state.

**1. Pull and run with a test user**

```bash
docker run --rm -p 2222:22 atmoz/sftp:alpine testuser:testpass:::upload
```

From another terminal, attempt a connection:

```bash
sftp -P 2222 testuser@localhost
# → Connected to localhost.
# → sftp>
```

This is the default behaviour — password auth, ephemeral container. The next
steps replace this with key-only auth and a persistent configuration.

**2. Inspect the chroot constraint**

Once connected via sftp, try to navigate above the home directory:

```bash
sftp> cd /
sftp> ls
# → upload
```

The user sees `/` but that `/` is their chroot jail — `/home/testuser` on the
host. This is the OpenSSH `ChrootDirectory` directive applied automatically by
the image. Same concept as build-your-infra, different delivery mechanism.

---

## Step 1 — SSH Host Keys

### What was done

Before writing the Compose file, generate the SSH host keys that the container
will use. Mounting them explicitly prevents OpenSSH from regenerating a new
fingerprint on every `docker compose down / up` cycle — which would trigger
a MITM warning on every reconnect.

```bash
mkdir -p configs/ssh
ssh-keygen -t ed25519 -f configs/ssh/ssh_host_ed25519_key -N ""
ssh-keygen -t rsa -b 4096 -f configs/ssh/ssh_host_rsa_key -N ""
```

> **Do not commit the private host keys to a public repository.**
> Add `configs/ssh/ssh_host_*` (without `.pub`) to `.gitignore`.

📄 `configs/ssh/ssh_host_ed25519_key` — mounted at `/etc/ssh/ssh_host_ed25519_key`
📄 `configs/ssh/ssh_host_rsa_key` — mounted at `/etc/ssh/ssh_host_rsa_key`

### Why

In build-your-infra, sshd host keys are generated once at install time and
never change unless you reinstall the OS. In a container, every time the image
is recreated from scratch, OpenSSH generates new host keys at startup — so any
SFTP client that cached the fingerprint will refuse the connection with a
host key mismatch warning.

Mounting pre-generated host keys restores the same stability guarantee: the
fingerprint is bound to the mounted file, not to the container lifecycle.
The `ed25519` key is the preferred algorithm (smaller, faster, modern).
The `rsa` key is kept for client compatibility.

### Verification

```bash
ls -la configs/ssh/
# → ssh_host_ed25519_key
# → ssh_host_ed25519_key.pub
# → ssh_host_rsa_key
# → ssh_host_rsa_key.pub

# Permissions must be 600 for the private keys — OpenSSH will reject them otherwise
chmod 600 configs/ssh/ssh_host_ed25519_key configs/ssh/ssh_host_rsa_key
```

---

## Step 2 — Client SSH Key Pair

### What was done

Generate the key pair that the SFTP client will use to authenticate. The
public key is mounted into the container; the private key stays on the client.

```bash
mkdir -p configs/keys
ssh-keygen -t ed25519 -f configs/keys/labuser_ed25519 -N ""
```

> **Do not commit the private client key to a public repository.**
> Add `configs/keys/labuser_ed25519` (without `.pub`) to `.gitignore`.

📄 `configs/keys/labuser_ed25519.pub` — mounted at `/home/labuser/.ssh/keys/labuser_ed25519.pub:ro`

### Why

`atmoz/sftp` auto-appends any public key found in `/home/<user>/.ssh/keys/`
to the user's `authorized_keys` file at container startup. Mounting the public
key as read-only (`:ro`) at that path is the image's supported mechanism for
SSH key auth — no manual `authorized_keys` file management required.

Disabling password auth entirely removes the largest brute-force attack surface
on an SSH-exposed port. In build-your-infra this was enforced via
`PasswordAuthentication no` in `sshd_config`. Here the equivalent is omitting
the password field in `users.conf` — an empty password field signals the image
to disable it for that user.

### Verification

```bash
ls configs/keys/
# → labuser_ed25519
# → labuser_ed25519.pub

cat configs/keys/labuser_ed25519.pub
# → ssh-ed25519 AAAA... (public key content)
```

---

## Step 3 — Users Configuration

### What was done

User definitions are written to `configs/sftp/users.conf` and mounted into the
container at `/etc/sftp/users.conf`. This file-based approach keeps user config
explicit and version-controlled, avoiding inline command arguments.

📄 [`configs/sftp/users.conf`](configs/sftp/users.conf) — mounted at `/etc/sftp/users.conf:ro`

### Why

`atmoz/sftp` supports three ways to define users: CLI arguments, the
`SFTP_USERS` environment variable, or a `users.conf` file. The file approach
is preferred here for the same reason a config file is preferred over inline
arguments in any service: it is auditable, diff-able, and maps cleanly to the
bind mount pattern used across this repo.

The syntax `user::uid::dir` defines the upload subdirectory directly. An empty
password field disables password authentication for that user — only key auth
works. UID 1001 matches the key pair generated in Step 2 so that file
ownership on the host volume is consistent.

### Verification

```bash
cat configs/sftp/users.conf
# → labuser::1001::upload
```

---

## Step 4 — Compose File

### What was done

The `docker-compose.yml` file defines the SFTP service with all mounts from
the previous steps: host keys, client public key, users config, and the upload
data directory.

```bash
docker compose up -d
```

📄 [`docker-compose.yml`](docker-compose.yml) — `docker compose up -d` from this directory

### Why

`atmoz/sftp:alpine` is chosen over `:debian` for the same reason as the
web-server module — smaller attack surface, faster pulls. Alpine carries a
newer OpenSSH than the Debian variant.

Port 2222 on the host avoids conflict with the host's own sshd on port 22.
This is a dev-only mapping — in prod the port assignment follows the
environment overlay. The container's sshd always listens on 22 internally;
only the host-side mapping changes.

`cap_drop: ALL` with `cap_add: [NET_BIND_SERVICE]` is the correct hardening
posture for this image. Unlike the web-server module where `cap_drop: ALL`
alone was sufficient, OpenSSH requires `NET_BIND_SERVICE` to bind port 22
inside the container. Adding back only this one capability keeps the surface
minimal while remaining functional.

`read_only: true` cannot be applied to this image without significant tmpfs
mapping that varies across OpenSSH versions — it is documented as out of scope
for this module. The hardening posture is: non-root data ownership, cap_drop,
no password auth.

### Verification

```bash
# Container is running
docker compose ps
# → NAME            IMAGE               STATUS
# → file-transfer   atmoz/sftp:alpine   Up X seconds

# SFTP connection with key auth
sftp -P 2222 -i configs/keys/labuser_ed25519 -oStrictHostKeyChecking=no labuser@localhost
# → Connected to localhost.
# → sftp>

# Upload a test file
sftp> put /etc/hostname upload/
# → Uploading /etc/hostname to /upload/hostname
# → /etc/hostname    100%   ...

# Confirm the file landed on the host bind mount
ls -la data/upload/
# → hostname

# Confirm no password auth
ssh -p 2222 -o PasswordAuthentication=yes -o PubkeyAuthentication=no labuser@localhost
# → Permission denied (publickey)
```

---

## Step 5 — Smoke Test and Container Lifecycle

### What was done

Full lifecycle test: stop, remove, and bring back up. Validates that the host
keys are preserved (no fingerprint change) and uploaded files persist across
the container lifecycle via the bind mount.

> This step has no new config or deploy action. It is a verification-only step
> to confirm the module is production-ready at the dev level before moving to
> the next module.

### Why

In build-your-infra, `systemctl restart ssh` was the equivalent check. Here
the unit of restart is the container. The critical difference: if host keys
were not mounted, every `docker compose down / up` would generate a new
fingerprint and break existing client connections. This step confirms the
persistence contract is working.

### Verification

```bash
# Record the current host key fingerprint
ssh-keyscan -p 2222 localhost 2>/dev/null | ssh-keygen -lf -
# → <fingerprint>

# Stop and remove the container
docker compose down

# Bring back up
docker compose up -d

# Fingerprint must be identical
ssh-keyscan -p 2222 localhost 2>/dev/null | ssh-keygen -lf -
# → <same fingerprint as before>

# Uploaded files survived the cycle
ls data/upload/
# → hostname  (file from Step 4 is still present)

# Inspect applied capabilities
docker inspect file-transfer --format '{{ .HostConfig.CapDrop }}'
# → [ALL]

docker inspect file-transfer --format '{{ .HostConfig.CapAdd }}'
# → [NET_BIND_SERVICE]
```

---

**Next:** [`modules/dns/dns.md`](../dns/dns.md)