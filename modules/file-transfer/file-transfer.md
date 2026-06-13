# File Transfer — containerize-your-infra

**Docker Engine · atmoz/sftp:alpine (platform: linux/amd64)**

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
docker run --rm --platform linux/amd64 -p 2222:22 atmoz/sftp:alpine testuser:testpass:::upload
```

From another terminal, attempt a connection:

```bash
sftp -P 2222 testuser@localhost
# → password testpass
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
# Check te destination folder before continue

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
on an SSH-exposed port. An empty password field in `SFTP_USERS` signals the
image to disable it for that user.

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

The SFTP user is defined via the `SFTP_USERS` environment variable in
`docker-compose.yml`. No external config file is required.

```yaml
environment:
  - SFTP_USERS=labuser::1001::upload
```

The format is `user:password:uid:gid:directory`. An empty password field
disables password authentication — SSH key auth only. UID 1001 matches the
key pair generated in Step 2 so file ownership on the host bind mount is
consistent.

### Why

`SFTP_USERS` keeps the user definition co-located with the rest of the service
config in `docker-compose.yml`. A `users.conf` file is the alternative for
deployments with many users — for a single lab user it adds a file and a mount
with no benefit.

The format `user::uid::dir` defines the upload subdirectory directly. An empty
password field disables password authentication for that user — only key auth
works. UID 1001 matches the key pair generated in Step 2 so that file
ownership on the host bind mount is consistent.

### Verification

```bash
# Confirm the variable is set inside the running container
docker compose exec file-transfer env | grep SFTP_USERS
# → SFTP_USERS=labuser::1001::upload

# Confirm the user exists inside the container
docker compose exec file-transfer id labuser
# → uid=1001(labuser) gid=100(users) groups=100(users)
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

`atmoz/sftp:alpine` over `:debian` — smaller attack surface, newer OpenSSH.

`platform: linux/amd64` is required because the image has no native ARM64
build. Docker runs it under emulation on both OrbStack and EC2 t4g.micro —
acceptable overhead for a lab service.

The entrypoint runs as root to create the system user, set chroot permissions,
and prepare `authorized_keys`, then sshd drops privileges per connection — same
pattern as OpenSSH on bare metal. This requires more capabilities than a
purely non-root image:

| Capability | Required for |
|---|---|
| `NET_BIND_SERVICE` | sshd binding port 22 |
| `CHOWN` / `SETUID` / `SETGID` | user creation and privilege drop |
| `DAC_OVERRIDE` | writing `/etc/shadow` |
| `FOWNER` | `chmod 600` on `authorized_keys` |
| `SYS_CHROOT` | applying the chroot jail per session |

This is not `privileged: true` — only the six capabilities this process
legitimately needs. Everything else is dropped.

Host keys are not mounted `:ro` — the entrypoint enforces `chmod` on them at
startup and OpenSSH rejects keys with wrong permissions.

`read_only: true` is out of scope — the entrypoint writes to `/etc/passwd`,
`/etc/shadow`, and `/etc/group` during startup. Hardening posture: scoped
capabilities, key-only auth, `:ro` on all config mounts.

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
sftp> put /etc/hosts upload
# → Uploading /etc/hosts to /upload/hosts
# → /etc/hosts    100%   ...

# Confirm the file landed on the host bind mount
ls -la data/upload/
# → hosts

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

> **What this verifies:** `ssh-keyscan` retrieves the public host key that the
> server announces on port 2222. `ssh-keygen -lf -` converts it to a short
> fingerprint. Running this command before and after a `down / up` cycle
> confirms that the mounted host keys survived — if the fingerprint changes,
> the container regenerated new keys and the mount is not working.

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
```

> **In normal use**, if host keys are not persisted and the container
> regenerates them, any client with a cached fingerprint in `~/.ssh/known_hosts`
> will receive a REMOTE HOST IDENTIFICATION HAS CHANGED warning on the next
> connection — the same MITM alert SSH uses for genuine key changes.

```bash

# Uploaded files survived the cycle
ls data/upload/
# → hostname  (file from Step 4 is still present)

# Inspect applied capabilities
docker inspect file-transfer --format '{{ .HostConfig.CapDrop }}'
# → [ALL]

docker inspect file-transfer --format '{{ .HostConfig.CapAdd }}'
# → [CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER CAP_NET_BIND_SERVICE CAP_SETGID CAP_SETUID CAP_SYS_CHROOT]
```

---

**Next:** [`modules/dns/dns.md`](../dns/dns.md)