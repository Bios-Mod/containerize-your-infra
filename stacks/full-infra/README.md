# Full Infrastructure Stack

A single `docker compose` command that brings up the complete lab:
web-server, file-transfer, dns, and reverse-proxy as interconnected services
on a shared Docker network (`proxy-net`).

## Implementation

| Environment | Doc |
|---|---|
| prod | [`full-infra.md`](full-infra.md) |

```bash
cd stacks/full-infra
docker compose -f docker-compose.prod.yml up -d
```

**Infrastructure & AWS native equivalent:** [`stacks/full-infra`](https://github.com/Bios-Mod/build-your-infra)