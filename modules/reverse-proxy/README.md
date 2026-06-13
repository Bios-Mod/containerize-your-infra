# Reverse Proxy

Deploys Traefik as a reverse proxy that routes incoming HTTP/HTTPS requests
to backend services based on hostname or path rules, with automatic TLS
termination and a protected dashboard.

## Implementation

| Environment | Technology | Doc |
|---|---|---|
| dev | Traefik v3 + Nginx backend | [reverse-proxy.md](reverse-proxy.md) |
| prod | Traefik v3 + Nginx backend | [reverse-proxy.md](reverse-proxy.md) |

**Infrastructure & AWS native equivalent:** [`modules/web-server`](https://github.com/Bios-Mod/build-your-infra/tree/main/modules/web-server)