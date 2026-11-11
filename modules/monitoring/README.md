# Monitoring

Collects host, container, and service telemetry across the infrastructure stack,
providing pull-based metrics scraping, synthetic endpoint probing, and centralized
dashboard visualization.

## Implementation

| Runtime | Environment | Technology | Doc |
|---|---|---|---|
| Docker | dev / prod | Prometheus · node_exporter · cAdvisor · blackbox_exporter · Grafana | [docker/monitoring-docker.md](docker/monitoring-docker.md) |
| Kubernetes | dev / prod | Prometheus · blackbox_exporter · Grafana (custom Helm chart) | [kubernetes/monitoring-kubernetes.md](kubernetes/monitoring-kubernetes.md) |

**Infrastructure & AWS native equivalent:** [`modules/monitoring`](https://github.com/Bios-Mod/build-your-infra/tree/main/modules/monitoring)
