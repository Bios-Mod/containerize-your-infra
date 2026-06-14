# dev — Setup

macOS with OrbStack as the Docker runtime.
Base environment for all `modules/*/` development and testing.

---

## Environment

| Parameter | Value |
|---|---|
| OS | macOS (Apple Silicon) |
| Architecture | ARM64 |
| Runtime | OrbStack |
| Compose | docker compose v2 (bundled with OrbStack) |

---

## Step 1 — Install OrbStack

### What was done
Download and install OrbStack from [orbstack.dev](https://orbstack.dev).
Open OrbStack after installation — Docker Engine starts automatically.

### Why
OrbStack provides a native ARM64 Docker Engine on macOS with significantly
lower resource overhead than alternatives. It exposes the standard Docker
CLI and `docker compose` v2 plugin with no additional configuration.
The `docker` and `docker compose` commands are available immediately in
any terminal after installation.

### Verification

```bash
docker version
# → Client and Server both present — confirms Engine is running

docker compose version
# → Docker Compose version v2.x.x
```

---

## Step 3 — Cross-architecture images

### What was done

No action required. OrbStack includes transparent QEMU emulation for
`linux/amd64` images on Apple Silicon — any image without a native ARM64
build runs automatically without additional configuration.

### Why

OrbStack ships with Rosetta-style emulation integrated into the Docker runtime.
When a `linux/amd64` image is pulled on an ARM64 host, OrbStack intercepts the
execution and runs it through its built-in translator. This is why modules like
`file-transfer` (`atmoz/sftp`) work in dev without any setup step.

In prod (Docker Engine on Ubuntu ARM64) this emulation is not included —
see [`environments/prod/setup.md`](../prod/setup.md) for the equivalent step.

### Verification

```bash
# An amd64-only image runs without exec format error or segfault
docker run --rm --platform linux/amd64 alpine uname -m
# → x86_64
```

---

## Step 2 — Clone the repository

### What was done
Clone the repository to the local machine.

```bash
git clone https://github.com/Bios-Mod/containerize-your-infra.git
cd containerize-your-infra
```

### Why
All module paths in this lab are relative to the repository root.
Working from inside the cloned directory ensures every `docker compose`
command resolves config files and volume paths correctly.

### Verification

```bash
ls
# → README.md  modules/  environments/  stacks/  ...
```

---

**Next:** [`modules/web-server/web-server.md`](../../modules/web-server/web-server.md)