# Web Server

Static content delivery via Nginx — HTTP only. TLS termination is handled upstream by the reverse-proxy module (Traefik).

## Implementation

| Environment | Technology | Doc |
|---|---|---|
| dev | Custom image (Dockerfile) — Nginx unprivileged, HTTP only | [web-server.md](web-server.md) |
| prod | Custom image (Dockerfile) — Nginx unprivileged, HTTP only | [web-server.md](web-server.md) |

**Infrastructure & AWS native equivalent:** [`modules/web-server`](https://github.com/Bios-Mod/build-your-infra/tree/main/modules/web-server)