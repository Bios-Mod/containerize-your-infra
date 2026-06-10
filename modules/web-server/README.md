# Web Server

Static content delivery via Nginx — HTTP in dev, HTTPS with TLS termination in prod.

## Implementation

| Environment | Technology | Doc |
|---|---|---|
| dev | Nginx official image — HTTP | [web-server.md](web-server.md) |
| prod | Nginx official image — HTTPS (Let's Encrypt / self-signed) | [web-server.md](web-server.md) |

**Infrastructure & AWS native equivalent:** [`modules/web-server`](https://github.com/Bios-Mod/build-your-infra/tree/main/modules/web-server)