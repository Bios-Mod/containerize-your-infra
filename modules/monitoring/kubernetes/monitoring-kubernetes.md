# Monitoring — containerize-your-infra

**Kubernetes · Helm chart on Amazon EKS (namespaces `full-infra-dev` / `full-infra-prod`)**

---

## Introduction

This document deploys the pull-based observability module on Amazon EKS as a custom
Helm chart (`modules/monitoring/kubernetes/helm/monitoring`), using
`modules/monitoring/docker/monitoring-docker.md` as the functional baseline.
Prometheus (`prom/prometheus:v3.16.0`) runs per environment namespace (`full-infra-dev`
and `full-infra-prod`) to scrape self-health metrics, node and container telemetry from
every worker node's kubelet cAdvisor endpoint (`/metrics/cadvisor`), and Traefik
reverse-proxy metrics discovered dynamically via Pod annotations.

Subsequent steps add synthetic blackbox probes (`blackbox_exporter`), Grafana
visualization with pre-provisioned datasources and dashboards, and integration as a
subchart of the `full-infra` umbrella stack.

> **One release per environment namespace.** Just like `reverse-proxy`, monitoring is
> installed independently in `full-infra-dev` and `full-infra-prod`. A namespaced
> `Role` limits Pod discovery to the target namespace, while cluster-scoped RBAC
> resources embed both the release name and namespace to avoid naming collisions.

> **No `node_exporter`, `kube-state-metrics`, or `kube-prometheus-stack`.** On EKS, the
> kubelet exposes container and root node metrics directly under `/metrics/cadvisor`
> (`id="/"`). Writing a plain Helm chart keeps every RBAC rule, service discovery job,
> and hardening constraint explicit without deploying an operator or CRDs.

> **Ephemeral TSDB storage (`emptyDir`) and production changes.** The EKS foundation
> includes no EBS CSI driver and clusters are torn down between validation sessions, so
> Prometheus stores its TSDB on an on-disk `emptyDir` capped at `1Gi`. In a real
> production cluster, this would switch to a `StatefulSet` with `PersistentVolumeClaim`
> storage, `remote_write` retention (Thanos, Mimir, or Amazon Managed Service for
> Prometheus), Alertmanager routing, `kube-state-metrics` for Kubernetes object state,
> and `node_exporter` for full host kernel and filesystem telemetry.

> **Chart files in `helm/monitoring/`** hold all templates and environment values. Paths
> are referenced after each step using the `📄` convention rather than embedding full
> manifests inline.

---

## Environment

| Parameter | Value |
|---|---|
| Chart | `modules/monitoring/kubernetes/helm/monitoring` (custom Helm chart, v2) |
| Image | `prom/prometheus:v3.16.0` |
| Cluster | Amazon EKS (`arm64` Managed Node Group, foundation already provisioned) |
| Namespaces | `full-infra-dev`, `full-infra-prod` — one release per namespace |
| Release name | `monitoring` (standalone validation) |
| Service | `monitoring-prometheus`, `ClusterIP`, port `9090` |
| Scrape interval | `15s` global (`scrape_interval` and `evaluation_interval`) |
| Discovery & targets | `prometheus` (`localhost:9090`), `kubelet-cadvisor` (`InternalIP:10250/metrics/cadvisor`), `traefik` (Pod SD on `:9100/metrics` in release namespace) |
| Storage & retention | On-disk `emptyDir` (`sizeLimit: 1Gi`) · TSDB retention `15d` / `800MB` |
| RBAC | `ServiceAccount` `monitoring-prometheus` (`automountServiceAccountToken: true`), namespaced `Role`, `ClusterRole` `<release>-<namespace>-prometheus-kubelet` |
| Hardening | `runAsNonRoot: true`, UID/GID/`fsGroup` `65534`, `seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` |
| Resources | Dev: `50m / 128Mi` requests, `200m / 256Mi` limits · Prod: `100m / 192Mi` requests, `300m / 384Mi` limits |

---

## Before You Start

Confirm the EKS cluster is reachable, the environment namespaces exist, and (to verify
the `traefik` scrape target end-to-end) the `reverse-proxy` release is already running
in the target namespace (`modules/reverse-proxy/kubernetes/reverse-proxy-kubernetes.md`).

```bash
kubectl get ns full-infra-dev full-infra-prod
# → both namespaces Active

kubectl get nodes -L kubernetes.io/arch
# → node group Ready, ARCH arm64

kubectl get pods -n full-infra-dev -l app.kubernetes.io/name=traefik
# → reverse-proxy-traefik Pod 1/1 Running (required for the traefik scrape target)
```

---

## Step 1 — RBAC and ServiceAccount

### What was done

Before Prometheus can list Traefik Pods or authenticate against each worker node's
kubelet API, it needs a dedicated Kubernetes identity and least-privilege RBAC across
two scopes:

- **`ServiceAccount` (`{{ .Release.Name }}-prometheus`):** mounts a projected API token
  (`automountServiceAccountToken: true`) used both by Prometheus's in-cluster Kubernetes
  Service Discovery client and as the bearer credential when scraping kubelet
  `/metrics/cadvisor`.
- **Namespaced `Role` and `RoleBinding` (`{{ .Release.Name }}-prometheus`):** grants
  read-only `get`, `list`, and `watch` on `pods`, `services`, and `endpoints` strictly
  inside `{{ .Release.Namespace }}`.
- **Cluster-scoped `ClusterRole` and `ClusterRoleBinding`
  (`{{ .Release.Name }}-{{ .Release.Namespace }}-prometheus-kubelet`):** grants `get`,
  `list`, and `watch` on `nodes` and `get` on the `nodes/metrics` subresource so
  Prometheus can resolve worker nodes and query kubelet `/metrics/cadvisor`.

Inspect the rendered manifests for `full-infra-dev` before installing:

```bash
helm template monitoring modules/monitoring/kubernetes/helm/monitoring \
  -n full-infra-dev \
  --show-only templates/serviceaccount.yaml \
  --show-only templates/rbac.yaml
```

📄 `modules/monitoring/kubernetes/helm/monitoring/templates/serviceaccount.yaml` — ServiceAccount with `automountServiceAccountToken: true`
📄 `modules/monitoring/kubernetes/helm/monitoring/templates/rbac.yaml` — namespaced `Role`/`RoleBinding` and namespace-qualified `ClusterRole`/`ClusterRoleBinding`

### Why

- **Two RBAC scopes:** `pods`, `services`, and `endpoints` are namespaced objects, so a
  namespaced `Role` keeps dev Prometheus unable to inspect `full-infra-prod` (and vice
  versa). `Node` objects and kubelet `/metrics/cadvisor` endpoints are cluster-wide
  resources with no namespace, so only a `ClusterRole` can grant access to `nodes` and
  `nodes/metrics`.
- **Why the `ClusterRole` and `ClusterRoleBinding` names include the namespace:**
  unlike `Role` or `Deployment`, cluster-scoped resources live in one flat namespace-less
  registry across the entire EKS cluster. Deploying both `full-infra-dev` and
  `full-infra-prod` using the same release name (`monitoring` standalone or `full-infra`
  under an umbrella) would fail on the second install if both created a
  `ClusterRole` with the same name. Embedding `{{ .Release.Namespace }}` guarantees each
  release owns a distinct object.
- **Least-privilege RBAC:** no `secrets` read permission, no `nodes/proxy` (direct
  kubelet scrapes hit port `10250` using webhook authorization against `nodes/metrics`,
  not API server proxying), no write verbs, and no wildcard resource access. Only the
  Prometheus workload mounts a ServiceAccount token; subsequent stateless components
  leave token auto-mounting disabled.

### Verification

> **Cluster-evaluated check:** `kubectl auth can-i` queries live RBAC objects stored in
> the Kubernetes API server. Before Step 2 runs `helm install`, all commands below
> report `no`; re-run them right after installing the chart in Step 2 to confirm the
> effective permissions.

```bash
kubectl auth can-i list pods -n full-infra-dev \
  --as=system:serviceaccount:full-infra-dev:monitoring-prometheus
# → yes

kubectl auth can-i get nodes \
  --as=system:serviceaccount:full-infra-dev:monitoring-prometheus
# → yes

kubectl auth can-i get nodes --subresource=metrics \
  --as=system:serviceaccount:full-infra-dev:monitoring-prometheus
# → yes

kubectl auth can-i get secrets -n full-infra-dev \
  --as=system:serviceaccount:full-infra-dev:monitoring-prometheus
# → no

kubectl auth can-i list pods -n full-infra-prod \
  --as=system:serviceaccount:full-infra-dev:monitoring-prometheus
# → no
```

---

## Step 2 — Prometheus

### What was done

Deploy Prometheus (`prom/prometheus:v3.16.0`) as standalone release `monitoring` into
`full-infra-dev` using `values.yaml` plus `values-dev.yaml`. The chart provisions:

- A `ConfigMap` (`monitoring-prometheus`) mounted read-only at `/etc/prometheus` with a
  `15s` global scrape interval and three jobs: `prometheus` (`localhost:9090`,
  `host: lab-eks`), `kubelet-cadvisor` (`role: node`, `https://<InternalIP>:10250/metrics/cadvisor`),
  and `traefik` (`role: pod` in `full-infra-dev`, matched via `prometheus.io/*`
  annotations).
- A hardened single-replica `Deployment` (`monitoring-prometheus`) running as UID/GID
  `65534` (`nobody`) with `fsGroup: 65534`, `seccompProfile: RuntimeDefault`,
  `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `drop: [ALL]`,
  `checksum/config` rollout triggering, HTTP readiness (`/-/ready`) and liveness
  (`/-/healthy`) probes on port `9090`, TSDB retention `15d` / `800MB`, and an on-disk
  `emptyDir` (`sizeLimit: 1Gi`) at `/prometheus`.
- A `ClusterIP` Service (`monitoring-prometheus`) exposing port `9090`.

> **`helm install` applies a new release only.** If `monitoring` already exists in
> `full-infra-dev` (including a failed install visible with `helm list -a -n full-infra-dev`),
> apply changes with `helm upgrade monitoring ...` rather than re-running `helm install`.

```bash
helm lint modules/monitoring/kubernetes/helm/monitoring \
  -f modules/monitoring/kubernetes/helm/monitoring/values.yaml \
  -f modules/monitoring/kubernetes/helm/monitoring/values-dev.yaml
# → 1 chart(s) linted, 0 chart(s) failed

helm install monitoring modules/monitoring/kubernetes/helm/monitoring \
  -n full-infra-dev \
  -f modules/monitoring/kubernetes/helm/monitoring/values.yaml \
  -f modules/monitoring/kubernetes/helm/monitoring/values-dev.yaml
```

📄 `modules/monitoring/kubernetes/helm/monitoring/Chart.yaml` — chart metadata (`appVersion: "3.16.0"`)
📄 `modules/monitoring/kubernetes/helm/monitoring/values.yaml` — baseline config and prod resource defaults
📄 `modules/monitoring/kubernetes/helm/monitoring/values-dev.yaml` — scaled-down dev CPU and memory requests/limits
📄 `modules/monitoring/kubernetes/helm/monitoring/values-prod.yaml` — explicit prod baseline values (`LimitRange`-compliant)
📄 `modules/monitoring/kubernetes/helm/monitoring/templates/prometheus-configmap.yaml` — `prometheus.yml` scrape jobs
📄 `modules/monitoring/kubernetes/helm/monitoring/templates/prometheus-deployment.yaml` — hardened Deployment, probes, `emptyDir` TSDB, and `checksum/config`
📄 `modules/monitoring/kubernetes/helm/monitoring/templates/prometheus-service.yaml` — internal `ClusterIP` Service on `9090`

### Why

- **On-disk `emptyDir` vs `medium: Memory` and PVC:** the EKS foundation has no EBS CSI
  driver, so Prometheus uses `emptyDir` rather than a `PersistentVolumeClaim`. Leaving
  `emptyDir.medium` unset places `/prometheus` on the worker node's disk instead of RAM
  — crucial here because a memory-backed `emptyDir` counts against the container's
  `memory` limit (`256Mi` in dev, `384Mi` in prod) and would cause OOMKills as TSDB
  series accumulate. Setting `sizeLimit: 1Gi` while capping Prometheus at
  `--storage.tsdb.retention.size=800MB` (800 MiB) leaves ~224 MiB of disk headroom for
  WAL segments and compaction before kubelet eviction triggers.
- **Kubelet `/metrics/cadvisor` on `InternalIP:10250` and `insecure_skip_verify: true`:**
  Prometheus `kubernetes_sd_configs` (`role: node`) resolves each EKS worker node's
  `InternalIP` and kubelet port (`10250`), sending the projected ServiceAccount token
  (`authorization.credentials_file`) over HTTPS to `/metrics/cadvisor`. Only this scrape
  target sets `insecure_skip_verify: true`: kubelet serving certificates are self-signed
  without a cluster-wide client CA bundle in this lab, whereas Kubernetes SD queries to
  the EKS API server still validate the control-plane CA via the mounted `ca.crt`. All
  kubelet traffic stays inside private node subnets (`10.0.10.0/24` and `10.0.11.0/24`)
  and remains protected by ServiceAccount webhook authorization (`nodes/metrics`).
- **Pod discovery for Traefik (`role: pod`) instead of Service scraping:** the Traefik
  chart exposes only ports `80` (`web`) and `443` (`websecure`) on its Service, while
  exposing Prometheus metrics on container port `9100` (`/metrics`) and annotating its
  Pods with `prometheus.io/scrape: "true"`, `prometheus.io/path: /metrics`, and
  `prometheus.io/port: "9100"`. Filtering `role: pod` strictly to `{{ .Release.Namespace }}`
  discovers the namespace's Traefik Pod without altering `reverse-proxy`'s Service or
  cross-contaminating `full-infra-dev` and `full-infra-prod`. Relabel rules filter on
  `prometheus.io/scrape`, map `prometheus.io/path` to `__metrics_path__`, rewrite
  `__address__` with port `prometheus.io/port`, and attach `namespace` and `pod` labels.
- **Config reloads and hardening:** `checksum/config` restarts the Pod whenever
  `prometheus.yml` changes in the ConfigMap. Pod-level `runAsUser`/`runAsGroup`/`fsGroup:
  65534` ensures `/prometheus` is writable without root ownership, while
  `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`,
  `capabilities.drop: [ALL]`, and `seccompProfile: RuntimeDefault` preserve the Docker
  hardening baseline.

### Verification

Confirm the Pod is healthy and security enforcement is active (if you deferred Step 1's
`kubectl auth can-i` checks until after `helm install`, run them now):

```bash
kubectl get pods,svc -n full-infra-dev -l app.kubernetes.io/part-of=monitoring
# → pod/monitoring-prometheus-...   1/1     Running
# → service/monitoring-prometheus   ClusterIP   <cluster-ip>   <none>   9090/TCP

kubectl get pod -n full-infra-dev -l app.kubernetes.io/name=prometheus \
  -o jsonpath='{.items[0].spec.securityContext.runAsUser}{" "}{.items[0].spec.containers[0].securityContext.readOnlyRootFilesystem}{"\n"}'
# → 65534 true

kubectl logs -n full-infra-dev deploy/monitoring-prometheus | grep -i 'level=error'
# → no output
```

> **Wait ~15–20 seconds after Pod readiness** before querying `/api/v1/targets` so the
> first `15s` scrape cycle finishes. Open `kubectl port-forward` in a **separate terminal**
> (and restart it if a later `helm upgrade` replaces the Pod).

In a separate terminal:

```bash
kubectl port-forward -n full-infra-dev svc/monitoring-prometheus 9090:9090
```

Query Prometheus readiness, scrape target health, and cAdvisor series:

```bash
curl -s http://localhost:9090/-/ready
# → Prometheus Server is Ready.

curl -s http://localhost:9090/api/v1/targets \
  | python3 -c "import sys,json; [print(t['labels']['job'], t['health']) for t in sorted(json.load(sys.stdin)['data']['activeTargets'], key=lambda x: x['labels']['job'])]"
# → kubelet-cadvisor up
# → kubelet-cadvisor up
# → prometheus up
# → traefik up

curl -s 'http://localhost:9090/api/v1/query?query=count(container_memory_working_set_bytes)' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['result'][0]['value'][1])"
# → <positive integer>
```
