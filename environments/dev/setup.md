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