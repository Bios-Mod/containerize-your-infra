# Web Server

Static content delivery via Nginx — HTTP only. TLS termination is handled upstream by the reverse-proxy module (Traefik).

## Implementation

| Runtime | Environment | Technology | Doc |
|---|---|---|---|
| Docker | dev / prod | Custom image (Dockerfile) — Nginx unprivileged, HTTP only | [./docker/web-server-docker.md](./docker/web-server-docker.md) |
| Kubernetes | dev / prod | Helm chart on Amazon EKS — same image, ClusterIP Service | [./kubernetes/web-server-kubernetes.md](./kubernetes/web-server-kubernetes.md) |

**Infrastructure & AWS native equivalent:** [`modules/web-server`](https://github.com/Bios-Mod/build-your-infra/tree/main/modules/web-server)