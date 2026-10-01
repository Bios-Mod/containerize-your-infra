# DNS

Name resolution for the lab — internal authority for `lab.local` and recursive resolution for external domains.

## Implementation

| Runtime | Environment | Technology | Doc |
|---|---|---|---|
| Docker | dev / prod | BIND9 in Docker — recursive resolver + authoritative zone | [docker/dns-docker.md](docker/dns-docker.md) |
| Kubernetes | dev / prod | BIND9 Helm chart on a custom arm64 image — ConfigMap zones, ClusterIP Service TCP/UDP | [kubernetes/dns-kubernetes.md](kubernetes/dns-kubernetes.md) |

**Infrastructure & AWS native equivalent:** [`modules/dns`](https://github.com/Bios-Mod/build-your-infra/tree/main/modules/dns)

CI Test