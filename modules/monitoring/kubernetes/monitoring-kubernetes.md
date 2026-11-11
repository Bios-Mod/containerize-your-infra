# Monitoring — containerize-your-infra

**Kubernetes · Helm chart on Amazon EKS (namespaces `full-infra-dev` / `full-infra-prod`)**

---

## Introduction

This document deploys Prometheus (`prom/prometheus:v3.16.0`) per environment namespace (`full-infra-dev` and `full-infra-prod`) via a custom Helm chart, extending `modules/monitoring/docker/monitoring-docker.md` to EKS. Prometheus self-scrapes, reads node/container metrics from kubelet `/metrics/cadvisor` (`id="/"`), and discovers Traefik Pods by annotation; probes and Grafana follow below.

> **Ephemeral TSDB and production changes:** without an EBS CSI driver, Prometheus writes to on-disk `emptyDir` (`1Gi` cap) lost on eviction/teardown. Production would add a `StatefulSet` with `PersistentVolumeClaim`, `remote_write` retention, Alertmanager, `kube-state-metrics`, and `node_exporter`.

## Environment

| Parameter | Value |
|---|---|
| Chart / Image | `modules/monitoring/kubernetes/helm/monitoring` · `prom/prometheus:v3.16.0` (UID/GID/`fsGroup` `65534`, `readOnlyRootFilesystem`) |
| Namespaces / release | `full-infra-dev`, `full-infra-prod` · standalone release `monitoring` (`ClusterIP` `:9090`) |
| Resources (dev / prod) | Dev: `50m / 128Mi` req, `200m / 256Mi` lim · Prod: `100m / 192Mi` req, `300m / 384Mi` lim |

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

> **New releases only:** if `monitoring` already exists (even failed), run `helm upgrade` instead of `helm install`.

```bash
helm lint modules/monitoring/kubernetes/helm/monitoring -f modules/monitoring/kubernetes/helm/monitoring/values.yaml -f modules/monitoring/kubernetes/helm/monitoring/values-dev.yaml
helm install monitoring modules/monitoring/kubernetes/helm/monitoring -n full-infra-dev -f modules/monitoring/kubernetes/helm/monitoring/values.yaml -f modules/monitoring/kubernetes/helm/monitoring/values-dev.yaml
```

📄 `modules/monitoring/kubernetes/helm/monitoring/{Chart.yaml,values.yaml,values-dev.yaml,values-prod.yaml}`
📄 `modules/monitoring/kubernetes/helm/monitoring/templates/prometheus-{configmap,deployment,service}.yaml`

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

kubectl get pods,svc -n full-infra-dev -l app.kubernetes.io/part-of=monitoring
# → pod/monitoring-prometheus-... 1/1 Running; svc/monitoring-prometheus ClusterIP 9090/TCP
kubectl port-forward -n full-infra-dev svc/monitoring-prometheus 9090:9090 &
sleep 3
curl -s http://localhost:9090/-/ready                                           # → Prometheus Server is Ready.
curl -s http://localhost:9090/api/v1/targets | python3 -c "import sys,json; [print(t['labels']['job'], t['health']) for t in sorted(json.load(sys.stdin)['data']['activeTargets'], key=lambda x: x['labels']['job'])]"
# → kubelet-cadvisor up (x2), prometheus up, traefik up
curl -s 'http://localhost:9090/api/v1/query?query=count(container_memory_working_set_bytes)' | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['result'][0]['value'][1])"
# → <positive integer>
kill %1
```
