# Monitoring — containerize-your-infra

**Kubernetes · Helm chart on Amazon EKS (namespaces `full-infra-dev` / `full-infra-prod`)**

---

## Introduction

This document deploys Prometheus (`prom/prometheus:v3.16.0`), `blackbox_exporter` (`prom/blackbox-exporter:v0.29.1`), and Grafana (`grafana/grafana:13.3.0`) per environment namespace (`full-infra-dev` and `full-infra-prod`) via a custom Helm chart, extending `modules/monitoring/docker/monitoring-docker.md` to EKS. Prometheus collects self, kubelet `/metrics/cadvisor` (`id="/"`), Traefik Pod, and synthetic HTTPS/DNS probe metrics visualized in Grafana.

> **Ephemeral state and production changes:** without an EBS CSI driver, Prometheus TSDB (`1Gi`) and Grafana SQLite (`256Mi`) use on-disk `emptyDir` lost on eviction/teardown. Production would add `StatefulSet`/PVCs, remote retention, Alertmanager, `kube-state-metrics`, and `node_exporter`.

## Environment

| Parameter | Value |
|---|---|
| Chart / Images | `modules/monitoring/kubernetes/helm/monitoring` · Prometheus `v3.16.0`, blackbox `v0.29.1`, Grafana `13.3.0` |
| Namespaces / release | `full-infra-dev`, `full-infra-prod` · standalone release `monitoring` |
| Services | `ClusterIP` `:9090` (Prometheus), `:9115` (blackbox), `:3000` (Grafana; conditional `IngressRoute` `grafana.local`) |
| Resources (dev / prod) | Prometheus `50m/128Mi`–`200m/256Mi` / `100m/192Mi`–`300m/384Mi` · blackbox `10m/16Mi`–`50m/48Mi` · Grafana `25m/192Mi`–`150m/512Mi` / `50m/192Mi`–`200m/512Mi` |

> **Grafana memory sizing:** without node swap on EKS, Grafana 13 needs a `512Mi` memory limit (matching the prod `LimitRange` ceiling) to avoid `OOMKilled` on startup.

## Before You Start

```bash
kubectl get ns full-infra-dev full-infra-prod                                # → both Active
kubectl get nodes -L kubernetes.io/arch                                     # → 2 nodes Ready, arm64
kubectl get pods -n full-infra-dev -l app.kubernetes.io/name=traefik        # → 1/1 Running
```

## Step 1 — RBAC and ServiceAccount

### What was done
Create ServiceAccount `<release>-prometheus` (`automountServiceAccountToken: true`) with two read-only RBAC scopes: a namespaced `Role` (`pods`, `services`, `endpoints`) and a `ClusterRole` `<release>-<namespace>-prometheus-kubelet` (`nodes` list/watch, `nodes/metrics` get).

```bash
helm template monitoring modules/monitoring/kubernetes/helm/monitoring -n full-infra-dev --show-only templates/serviceaccount.yaml --show-only templates/rbac.yaml
```

📄 `modules/monitoring/kubernetes/helm/monitoring/templates/{serviceaccount,rbac}.yaml`

### Why
- **Two RBAC scopes:** `pods`/`services`/`endpoints` are namespaced (isolating dev and prod), while `nodes` and `nodes/metrics` are cluster-wide.
- **Namespace in ClusterRole name:** cluster-scoped names are global, so `<namespace>` avoids ownership clashes between `full-infra-dev` and `full-infra-prod`.
- **Minimal RBAC:** omits `secrets`, writes, and `nodes/proxy` (kubelet `:10250` checks `nodes/metrics`). Other components disable `automountServiceAccountToken`.

## Step 2 — Prometheus

### What was done
Validate and install `monitoring` into `full-infra-dev` with `15s` scrape interval, `15d` / `800MB` TSDB retention, `checksum/config` rollout trigger, and `/-/ready` / `/-/healthy` probes.

> **New releases only:** if `monitoring` already exists (even failed), run `helm upgrade` instead of `helm install`. Grafana waits on `monitoring-grafana-admin` until Step 4.

```bash
helm lint modules/monitoring/kubernetes/helm/monitoring -f modules/monitoring/kubernetes/helm/monitoring/values.yaml -f modules/monitoring/kubernetes/helm/monitoring/values-dev.yaml
helm install monitoring modules/monitoring/kubernetes/helm/monitoring -n full-infra-dev -f modules/monitoring/kubernetes/helm/monitoring/values.yaml -f modules/monitoring/kubernetes/helm/monitoring/values-dev.yaml
```

📄 `modules/monitoring/kubernetes/helm/monitoring/{Chart.yaml,values.yaml,values-dev.yaml,values-prod.yaml}` · `templates/prometheus-{configmap,deployment,service}.yaml`

### Why
- **On-disk `emptyDir` vs RAM/PVC:** omitting `medium: Memory` keeps TSDB off Pod RAM (`256Mi`/`384Mi` limits), while `1Gi` `sizeLimit` leaves WAL headroom above `800MB` retention.
- **Kubelet `InternalIP:10250` and `insecure_skip_verify`:** worker kubelets use self-signed serving certs; API discovery keeps CA verification (`ca.crt`) inside private VPC subnets.
- **Traefik Pod SD (`role: pod`):** Traefik Service exposes `80`/`443` only, while Pod annotations expose `:9100/metrics` inside the release namespace without altering `reverse-proxy`.
- **Hardening baseline:** `seccompProfile: RuntimeDefault`, `drop: [ALL]`, non-root `65534`, `fsGroup: 65534`, and `readOnlyRootFilesystem: true` preserve Docker security controls.

### Verification

> **Wait ~20s after Pod Ready** before checking `/api/v1/targets` so the first `15s` scrape completes.

```bash
kubectl auth can-i list pods -n full-infra-dev --as=system:serviceaccount:full-infra-dev:monitoring-prometheus   # → yes
kubectl auth can-i get nodes --as=system:serviceaccount:full-infra-dev:monitoring-prometheus                      # → yes
kubectl auth can-i get nodes --subresource=metrics --as=system:serviceaccount:full-infra-dev:monitoring-prometheus # → yes
kubectl auth can-i get secrets -n full-infra-dev --as=system:serviceaccount:full-infra-dev:monitoring-prometheus # → no
kubectl auth can-i list pods -n full-infra-prod --as=system:serviceaccount:full-infra-dev:monitoring-prometheus # → no

kubectl get pods,svc -n full-infra-dev -l app.kubernetes.io/name=prometheus
# → pod/monitoring-prometheus-... 1/1 Running; svc/monitoring-prometheus ClusterIP 9090/TCP
kubectl port-forward -n full-infra-dev svc/monitoring-prometheus 9090:9090 & PROM_PID=$!
sleep 3
curl -s http://localhost:9090/-/ready                                           # → Prometheus Server is Ready.
curl -s 'http://localhost:9090/api/v1/query?query=count(container_memory_working_set_bytes)' | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['result'][0]['value'][1])"
# → <positive integer>
kill $PROM_PID
```

## Step 3 — Blackbox probes

### What was done
Deploy `<release>-blackbox` (`ClusterIP` `:9115`, `UID/GID 65534`, `automountServiceAccountToken: false`, no `emptyDir`) with `http_2xx_insecure` and `dns_lab_soa`, scraped via Prometheus `blackbox-http` and `blackbox-dns` jobs.

```bash
helm template monitoring modules/monitoring/kubernetes/helm/monitoring -n full-infra-dev --show-only templates/blackbox-configmap.yaml --show-only templates/blackbox-deployment.yaml --show-only templates/blackbox-service.yaml
```

📄 `modules/monitoring/kubernetes/helm/monitoring/templates/{blackbox-configmap,blackbox-deployment,blackbox-service,prometheus-configmap}.yaml`

### Why
- **SNI + `Host` override (`server_name: web.local`):** Prometheus dials `<service>:443` internally, so matching SNI and `Host` ensures Traefik selects the HTTPS router alongside `insecure_skip_verify: true`.
- **Parameterized targets (`probes.*`):** standalone defaults (`reverse-proxy-traefik`, `dns-dns`) switch cleanly to `full-infra-*` under the umbrella `values.yaml`.
- **Stateless hardening:** blackbox writes nothing to disk, needing no `emptyDir` alongside `readOnlyRootFilesystem: true`.

## Step 4 — Grafana

### What was done
Create Secret `monitoring-grafana-admin` (`admin-password`), finish `<release>-grafana` startup (`ClusterIP` `:3000`, `UID/GID/fsGroup 472`, `emptyDir` `256Mi`, datasource + `Lab Overview (Kubernetes)` ConfigMaps, conditional `IngressRoute`), and expose `:3000` via `port-forward`.

```bash
kubectl create secret generic monitoring-grafana-admin -n full-infra-dev --from-literal=admin-password="$(openssl rand -base64 18)"
kubectl rollout status deploy/monitoring-grafana -n full-infra-dev
kubectl get secret monitoring-grafana-admin -n full-infra-dev -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl port-forward -n full-infra-dev svc/monitoring-grafana 3000:3000 & GRAF_PID=$!
```

📄 `modules/monitoring/kubernetes/helm/monitoring/templates/grafana-{datasource-configmap,dashboards-configmap,deployment,service,ingressroute}.yaml` · `dashboards/lab-overview-k8s.json`

### Why
- **Secret outside Git:** kubelet holds Pod creation until `monitoring-grafana-admin` exists; credentials never enter `values.yaml`.
- **`GF_PLUGINS_PREINSTALL_DISABLED=true`:** forces Grafana's bundled Go datasource binary (`gpx_*`) instead of downloading plugins into read-only storage.
- **Separate JSON + `.Files.Get`:** prevents Helm template evaluation of PromQL/Grafana `{{node}}`/`{{pod}}` variables while `checksum/config` triggers rollouts.
- **`ClusterIP` + conditional `IngressRoute`:** dev uses `port-forward`; prod uses Traefik `websecure` + shared `reverse-proxy-tls` (`grafana.local`).

## Step 5 — End-to-end verification

### What was done
Confirm all five Prometheus scrape jobs, both blackbox probes (`probe_success == 1`), and provisioned Grafana datasource/dashboard state in `full-infra-dev`.

### Verification

```bash
PASS=$(kubectl get secret monitoring-grafana-admin -n full-infra-dev -o jsonpath='{.data.admin-password}' | base64 -d)
kubectl port-forward -n full-infra-dev svc/monitoring-prometheus 9090:9090 & PROM_PID=$!
sleep 3
curl -s http://localhost:9090/api/v1/targets | python3 -c "import sys,json; [print(t['labels']['job'], t['health']) for t in sorted(json.load(sys.stdin)['data']['activeTargets'], key=lambda x: x['labels']['job'])]"
# → blackbox-dns up, blackbox-http up, kubelet-cadvisor up (x2), prometheus up, traefik up
curl -s 'http://localhost:9090/api/v1/query?query=probe_success' | python3 -c "import sys,json; [print(r['metric']['job'], r['value'][1]) for r in json.load(sys.stdin)['data']['result']]"
# → blackbox-http 1, blackbox-dns 1
curl -s -u "admin:$PASS" http://localhost:3000/api/datasources/uid/prometheus | grep -o '"name":"Prometheus"'         # → "name":"Prometheus"
curl -s -u "admin:$PASS" http://localhost:3000/api/dashboards/uid/lab-overview-k8s | grep -o '"title":"Lab Overview (Kubernetes)"'
# Open http://localhost:3000 (Lab → Lab Overview (Kubernetes)) and confirm panels render data
kill $PROM_PID $GRAF_PID && unset PASS
```
