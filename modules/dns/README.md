# DNS

Name resolution for the lab — internal authority for `lab.local` and recursive resolution for external domains.

## Implementation

| Environment | Technology | Doc |
|---|---|---|
| dev | BIND9 in Docker — recursive resolver + authoritative zone | [docker/dns-docker.md](docker/dns-docker.md) |
| prod | BIND9 in Docker — recursive resolver + authoritative zone | [docker/dns-docker.md](docker/dns-docker.md) |

**Infrastructure & AWS native equivalent:** [`modules/dns`](https://github.com/Bios-Mod/build-your-infra/tree/main/modules/dns)