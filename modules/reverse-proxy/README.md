# Reverse Proxy

Deploys Traefik as a reverse proxy that routes incoming HTTP/HTTPS requests
to backend services based on hostname or path rules, with TLS termination
and a protected dashboard.

## Implementation

| Runtime | Environment | Technology | Doc |
|---|---|---|---|
| Docker | dev / prod | Traefik v3 + Nginx backend | [docker/reverse-proxy-docker.md](docker/reverse-proxy-docker.md) |
| Kubernetes | dev / prod | Traefik (official Helm chart), IngressRoute + Middleware CRDs | [kubernetes/reverse-proxy-kubernetes.md](kubernetes/reverse-proxy-kubernetes.md) |

**Infrastructure & AWS native equivalent:** [`modules/web-server`](https://github.com/Bios-Mod/build-your-infra/tree/main/modules/web-server)