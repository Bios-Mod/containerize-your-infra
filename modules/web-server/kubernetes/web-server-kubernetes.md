# Web Server — containerize-your-infra

**Kubernetes · Helm chart on Amazon EKS (namespaces `full-infra-dev` / `full-infra-prod`)**

---

## Introduction

This document covers the deployment of the web-server module as the first Helm chart
in the Kubernetes migration. It validates the Deployment / Service pattern for a
stateless HTTP workload before any other module is migrated. The Docker implementation
(`modules/web-server/docker/web-server-docker.md`) remains the functional baseline —
this doc reproduces the same behaviour on a different runtime, it does not redesign the
service.

> **No Ingress in this chart.** Upstream routing and TLS termination are addressed in
> the reverse-proxy Kubernetes migration — same boundary already
> established in the Docker doc.

> **No ConfigMap in this chart.** `nginx.conf` and `index.html` stay baked into the
> image at build time, same as the Docker implementation. Externalizing static config
> via ConfigMap is a pattern practiced in the `dns` module (Fase 6), where BIND9 zone
> files justify it — not here.

> **Chart files in `helm/web-server/`** contain only what this module needs. Paths are
> referenced after each deploy block, following the same 📄 convention as the Docker doc.

---

## Environment

| Parameter   | Value                                                             |
|-------------|--------------------------------------------------------------------|
| Base image  | `nginxinc/nginx-unprivileged:stable-alpine` (unchanged)            |
| Registry    | Amazon ECR — `containerize-your-infra/web-server`, Terraform-managed, isolated state |
| Cluster     | Amazon EKS (Fase 3 foundation)                                     |
| Namespaces  | `full-infra-dev`, `full-infra-prod`                                |
| Port        | 8080 → 8080 (ClusterIP)                                            |
| TLS         | None — handled by reverse-proxy module (out of scope here)         |
| Config      | `nginx.conf` and `index.html` baked into image (no ConfigMap)      |
| Hardening   | `securityContext`: non-root (UID/GID 101), `capabilities.drop: [ALL]`, `readOnlyRootFilesystem: true`, `emptyDir` (`medium: Memory`) for writable paths |
| Packaging   | Helm chart, no umbrella dependency yet                             |

---

## Before You Start — Cluster State (optional)

These commands confirm the Fase 3 foundation is reachable before deploying anything new.

```bash
kubectl get ns full-infra-dev full-infra-prod ingress-system
# → all three namespaces Active

kubectl get nodes
# → node group Ready
```

---

## Step 1 — Container Registry (Amazon ECR, isolated Terraform state)

### What was done

ECR is provisioned with its own Terraform state, separate from the EKS platform state.
Unlike the cluster (short-lived, up/down per module implementation cycle), the registry
is long-lived — it must survive every `terraform destroy` run against the cluster.
Mixing both in one state would force a registry recreation (and a full rebuild/push)
every time the cluster is torn down between modules.

```bash
cd stacks/full-infra/kubernetes/automation/terraform/registry

terraform init
terraform apply
# → outputs: repository_url = <account-id>.dkr.ecr.<region>.amazonaws.com/containerize-your-infra/web-server
```

📄 `stacks/full-infra/kubernetes/automation/terraform/registry/ecr.tf` — `aws_ecr_repository` resource, isolated state
📄 `stacks/full-infra/kubernetes/automation/terraform/cluster/` — EKS platform Terraform, separate state (Fase 3), unaffected by this apply

Once the repository exists, the image built from the existing `Dockerfile`
(`modules/web-server/docker/Dockerfile`) is pushed to it:

```bash
cd stacks/full-infra/kubernetes/automation/terraform/registry

REPO_URL=$(terraform output -raw repository_url)
REGION=$(terraform output -raw region 2>/dev/null || echo "<tu-region>")

cd -   # back to repo root

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${REPO_URL%%/*}"

docker build -t "$REPO_URL:v1" -f modules/web-server/docker/Dockerfile modules/web-server/docker

docker push "$REPO_URL:v1"
```

📄 `modules/web-server/docker/Dockerfile` — build context reused as-is; Kubernetes does not build images, it pulls them

### Set the real registry URI in values.yaml

`values.yaml` must reference the real `$REPO_URL`, never the placeholder. Kubernetes
rejects `<` and `>` as invalid characters in an image reference — leaving them in
produces `InvalidImageName` at Pod scheduling time, not a pull error.

```bash
grep "repository:" modules/web-server/kubernetes/helm/web-server/values.yaml
# → confirm it still shows the placeholder before editing

# Replace image.repository in values.yaml with the value of $REPO_URL, then confirm:
grep "repository:" modules/web-server/kubernetes/helm/web-server/values.yaml
# → repository: <real-account-id>.dkr.ecr.<real-region>.amazonaws.com/containerize-your-infra/web-server
# must NOT contain "<" or ">"
```

📄 `modules/web-server/kubernetes/helm/web-server/values.yaml` — `image.repository` updated with the real ECR URI

### Push environment-specific tags

`values-dev.yaml` and `values-prod.yaml` reference `image.tag: dev` and
`image.tag: prod` respectively — these must exist in ECR as their own tags before
Step 6, even though they point at the same build as `v1` today. `docker tag` creates a
second reference to the same local image; each still needs its own `docker push`.

```bash
docker tag "$REPO_URL:v1" "$REPO_URL:dev"
docker push "$REPO_URL:dev"

docker tag "$REPO_URL:v1" "$REPO_URL:prod"
docker push "$REPO_URL:prod"
```

📄 `modules/web-server/kubernetes/helm/web-server/values-dev.yaml` — expects `image.tag: dev` to exist in ECR
📄 `modules/web-server/kubernetes/helm/web-server/values-prod.yaml` — expects `image.tag: prod` to exist in ECR

### Why

Kubernetes has no local `build:` equivalent — `kubelet` only pulls images by reference,
so a pushed artifact must exist before any Deployment can use it. Connect to known: an
ECR image URI plays the same role a versioned AMI played in build-your-infra — a
pre-baked, immutable artifact pulled at deploy time, not assembled on the host.

Separating the registry's Terraform state from the cluster's is a **production-correct
pattern**, not a lab shortcut: state should be isolated by resource lifecycle, not just
by service. A shared blast radius between a long-lived registry and a short-lived
cluster is incorrect in any context — it risks destroying build artifacts as a side
effect of tearing down infrastructure that has nothing to do with them.

The `:local` tag from the Docker doc is a dev-only convenience; from here on, tags must
be immutable (`v1`, or a git SHA). A floating tag like `latest` is incorrect in any
context — it removes the ability to roll back to a known image state, which is the
entire point of `helm rollback` used later in this doc.

Leaving `values.yaml` with the literal placeholder is the single point of failure that
breaks every step from here on — Helm renders it as-is, Kubernetes only rejects it at
Pod scheduling, several steps downstream from where the mistake actually happened. This
step exists precisely so the substitution is a checked, verifiable action instead of a
line of prose that's easy to read past.

`dev` and `prod` are tag aliases of the same `v1` build today, not separate code
versions — the environment split lives in Helm values (replicas, resources), not in the
image content, until a real code change justifies a distinct tag per environment.

### Verification

```bash
aws ecr describe-images --repository-name containerize-your-infra/web-server --region "$REGION" \
  --query 'imageDetails[*].imageTags' --output text
# → v1  dev  prod

docker pull "$REPO_URL:v1"
# → Status: Image is up to date
```

---

## Step 3 — Deployment (workload, hardening, probes, resources)

### What was done

`templates/deployment.yaml` runs one container from the ECR image on port 8080. The
`securityContext` reproduces the Docker hardening: non-root (UID/GID 101), all
capabilities dropped, read-only root filesystem. Three `emptyDir` volumes (backed by
`medium: Memory`) replace the Compose `tmpfs` mounts (`/var/cache/nginx`, `/var/run`,
`/tmp`). `readinessProbe` and `livenessProbe` both do an HTTP `GET /` on port 8080, with
the same timing as the Docker healthcheck (`start_period: 10s`, `interval: 30s`).

📄 `modules/web-server/kubernetes/helm/web-server/templates/deployment.yaml`

### Why

Connect to known: `securityContext` here is the Kubernetes-native equivalent of
`cap_drop` + `read_only` + `tmpfs` in Compose — same hardening intent, different API.
`medium: Memory` on the `emptyDir` volumes is what makes them behave like Compose's
`tmpfs` (RAM-backed, not node disk) — omitting it would still work, but it would be a
disk-backed `emptyDir`, which is a different guarantee.

Two probes are deliberate: `readinessProbe` gates whether the Service routes traffic to
this Pod; `livenessProbe` restarts the container on failure — something Compose's
`healthcheck` cannot do on its own, it only reports `unhealthy`. Requests/limits at this
size are **valid for a lab**; in a real production workload they'd come from load
testing, not be guessed — worth saying plainly in an interview.

> No cluster deployment yet. This step only writes and statically validates the
> manifest — the first real `helm install` happens in Step 6, once Service and
> values files also exist.

### Verification

```bash
helm template modules/web-server/kubernetes/helm/web-server | grep -A5 "securityContext"
# → confirms runAsNonRoot, readOnlyRootFilesystem, capabilities.drop rendered correctly

helm template modules/web-server/kubernetes/helm/web-server | grep "containerPort"
# → containerPort: 8080
```

---

## Step 4 — Service (ClusterIP)

### What was done

`templates/service.yaml` exposes the Deployment as `ClusterIP`, port 8080 →
targetPort 8080, selector matching the Deployment's `app.kubernetes.io/name` and
`app.kubernetes.io/instance` labels.

> No Ingress and no LoadBalancer in this chart. Only Traefik/Ingress (once migrated in
> Fase 5) should reach this Service — same single-entry-point boundary as the Docker doc.

📄 `modules/web-server/kubernetes/helm/web-server/templates/service.yaml`

### Why

`ClusterIP` is correct here — not a lab shortcut. A `LoadBalancer` or `NodePort` at this
stage would be incorrect in any context: it breaks the single-entry-point design the
reverse-proxy module exists to enforce.

> Still no cluster deployment. Selector-to-label matching is verified statically here;
> actual routing is confirmed once the chart is installed in Step 6.

### Verification

```bash
helm template modules/web-server/kubernetes/helm/web-server --show-only templates/service.yaml
# → confirms type: ClusterIP, port: 8080, targetPort: 8080

helm template modules/web-server/kubernetes/helm/web-server \
  | grep -E "app.kubernetes.io/name: web-server"
# → 5 matches: Deployment labels, Deployment selector, Pod template labels,
#   Service labels, Service selector — all identical, confirming the Service
#   selector matches the Deployment's Pod labels
```

---

## Step 5 — values.yaml / values-dev.yaml / values-prod.yaml

### What was done

`values.yaml` holds every default: image reference, port, probes, resources,
securityContext. `values-dev.yaml` and `values-prod.yaml` declare only real deltas —
`replicaCount`, `image.tag` and resource headroom.

📄 `modules/web-server/kubernetes/helm/web-server/values.yaml`
📄 `modules/web-server/kubernetes/helm/web-server/values-dev.yaml`
📄 `modules/web-server/kubernetes/helm/web-server/values-prod.yaml`

### Why

Connect to known: this is the Helm equivalent of `docker-compose.prod.yml` as an
override layer — same chart, same image family, different operational parameters.
`replicaCount: 2` in prod is a lab-defensible statement about redundancy.

### Verification

```bash
helm template modules/web-server/kubernetes/helm/web-server \
  -f modules/web-server/kubernetes/helm/web-server/values.yaml \
  -f modules/web-server/kubernetes/helm/web-server/values-prod.yaml | grep replicas
# → replicas: 2
```

---

## Step 6 — Deploy to full-infra-dev and full-infra-prod

### What was done

This is the first real deployment of the chart — everything up to this point was
written and statically validated, but nothing was running in the cluster yet. Same
chart, two independent releases, one per namespace.

```bash
helm install web-server modules/web-server/kubernetes/helm/web-server \
  -n full-infra-dev \
  -f modules/web-server/kubernetes/helm/web-server/values.yaml \
  -f modules/web-server/kubernetes/helm/web-server/values-dev.yaml

helm install web-server modules/web-server/kubernetes/helm/web-server \
  -n full-infra-prod \
  -f modules/web-server/kubernetes/helm/web-server/values.yaml \
  -f modules/web-server/kubernetes/helm/web-server/values-prod.yaml
```

### Why

Both environments deploy the same components — no service is removed to simplify dev. Differences live entirely in values, not
in templates. Deploying once, after every template is written and lint-validated,
avoids installing a chart that is still incomplete — same discipline as running
`docker compose config` before `docker compose up`, just deferred to the point where
the whole chart is actually ready.

### Verification

```bash
kubectl get pods -n full-infra-dev -l app.kubernetes.io/name=web-server
kubectl get pods -n full-infra-prod -l app.kubernetes.io/name=web-server
# → both: 1/1 or 2/2 Running

kubectl exec -n full-infra-dev deploy/web-server-web-server -- whoami
# → nginx

kubectl exec -n full-infra-dev deploy/web-server-web-server -- touch /test
# → touch: /test: Read-only file system

kubectl get svc -n full-infra-dev
kubectl port-forward -n full-infra-dev svc/web-server-web-server 8080:8080 & 
curl -I http://localhost:8080
# → HTTP/1.1 200 OK
```

---

## Step 7 — Rolling Update and Rollback

### What was done

A new image tag is pushed and rolled out via `helm upgrade`, then reverted via
`helm rollback`, validating the full lifecycle before this module is considered closed.
The rollback target is identified from the real rollout history, not assumed as a fixed
revision number — revision numbers are not portable across sessions once manual
`kubectl scale`/`rollout restart` interventions have happened.

```bash
docker build -t "$REPO_URL:v2" -f modules/web-server/docker/Dockerfile modules/web-server/docker
docker push "$REPO_URL:v2"

helm upgrade web-server modules/web-server/kubernetes/helm/web-server \
  -n full-infra-dev \
  -f modules/web-server/kubernetes/helm/web-server/values.yaml \
  -f modules/web-server/kubernetes/helm/web-server/values-dev.yaml \
  --set image.tag=v2

kubectl rollout status deployment/web-server-web-server -n full-infra-dev
```

📄 `modules/web-server/kubernetes/helm/web-server/values.yaml` — baseline `image.repository` reused, only `image.tag` overridden inline

### Why

Connect to known: this is the Kubernetes-native version of the Docker doc's smoke-test
step, but rollout here is a first-class object (`kubectl rollout`, `helm history`)
rather than a manual `down`/`up` cycle.

Rolling back to a hardcoded revision number (e.g. `helm rollback web-server 1`) is
**incorrect in any context** once a deployment's history includes manual interventions
— `kubectl scale`, `rollout restart`, or a failed `helm upgrade` all consume revision
numbers without guaranteeing they point to a healthy state. The correct pattern is to
inspect the image recorded in each candidate revision first, then roll back to the one
confirmed healthy — not to the oldest or the first number that comes to mind.

### Verification

```bash
kubectl rollout history deployment/web-server-web-server -n full-infra-dev
# → lists all revisions currently retained

kubectl rollout history deployment/web-server-web-server -n full-infra-dev --revision=<N>
# → run for each recent revision, inspect the "Image:" field
# identify the last revision whose image matches a known-good tag (v1 or v2)

helm rollback web-server <confirmed-healthy-revision> -n full-infra-dev

kubectl rollout status deployment/web-server-web-server -n full-infra-dev
kubectl get pods -n full-infra-dev -l app.kubernetes.io/name=web-server
# → 1/1 Running, no InvalidImageName / ImagePullBackOff

curl -I http://localhost:8080
# → HTTP/1.1 200 OK (confirms rollback restored a working image)
```

---