# DNS — containerize-your-infra

**Kubernetes · Helm chart on Amazon EKS (namespaces `full-infra-dev` / `full-infra-prod`)**

---

## Introduction

This document migrates the BIND9 DNS module to Kubernetes as a Helm chart. BIND9 keeps
its role — authoritative zone for `lab.local` plus a forwarding resolver for everything
else — and only the runtime changes. The Docker implementation
(`modules/dns/docker/dns-docker.md`) remains the functional baseline; this doc reproduces
its behaviour on a different runtime, it does not redesign the service.

> **Custom image.** The official ISC image is published for amd64 only and the EKS nodes
> are arm64, so this module builds its own image (Step 1). The Docker implementation keeps
> the official image.

> **Internal service only.** DNS is exposed through a `ClusterIP` Service. No Ingress, no
> `LoadBalancer`: HTTP routing does not apply to DNS, and nothing in the lab requires
> resolving `lab.local` from outside the cluster.

> **Config lives in a ConfigMap.** This is the module where externalizing static config
> is justified: BIND9 zone and option files are plain text that must change without
> rebuilding an image. The chart carries its own copy of the config because Helm cannot
> read files outside the chart directory.

> **Chart files in `helm/dns/`** contain only what this module needs. Paths are
> referenced after each deploy block, following the same 📄 convention as the Docker doc.

---

## Environment

| Parameter        | Value                                                                        |
|------------------|------------------------------------------------------------------------------|
| Image            | Custom image on Ubuntu 24.04 (`bind9` package), built for `linux/arm64`       |
| Registry         | Amazon ECR — `containerize-your-infra/dns`, created by hand (outside Terraform) |
| Cluster          | Amazon EKS (foundation already provisioned, arm64 nodes)                      |
| Namespaces       | `full-infra-dev`, `full-infra-prod`                                           |
| Release name     | `dns` in both namespaces                                                      |
| Service          | `dns-dns`, `ClusterIP`, 53 TCP/UDP → container port 5353                      |
| DNS role         | Authoritative zone `lab.local` + forwarding resolver                          |
| Forwarders       | `8.8.8.8`, `8.8.4.4` (unchanged)                                              |
| Cluster zone     | `cluster.local` forwarded to kube-dns                                         |
| Replicas         | 1 in dev, 2 in prod                                                           |
| Config           | ConfigMap `dns-dns` mounted read-only at `/etc/bind`                          |
| Writable paths   | `emptyDir` (`medium: Memory`) on `/var/cache/bind`, `/var/run/named`, `/tmp`  |
| Hardening        | non-root (UID/GID 101), `capabilities.drop: [ALL]`, `readOnlyRootFilesystem`  |
| Packaging        | Helm chart, no umbrella dependency yet                                        |

---

## Before You Start — Cluster State (optional)

These commands confirm the foundation and the `web-server` release are reachable before
deploying anything new. `web-server` is not required for BIND9 to start, only to validate
the `web.lab.local` record in Step 5.

```bash
kubectl get ns full-infra-dev full-infra-prod
# → both namespaces Active

kubectl get nodes -L kubernetes.io/arch
# → node group Ready, ARCH arm64

kubectl get svc web-server-web-server -n full-infra-dev
kubectl get svc web-server-web-server -n full-infra-prod
# → ClusterIP, 8080/TCP in both namespaces
```

---

## Step 1 — Container Image (Dockerfile, ECR, push)

### What was done

The official ISC image cannot run on this cluster, so the module builds its own. The ECR
repository is created by hand, the image is built for `linux/arm64` from the module
Dockerfile and pushed, and `REPO_URL` is kept for the next steps.

```bash
REGION=eu-west-1
aws ecr create-repository --repository-name containerize-your-infra/dns --region "$REGION"

REPO_URL=$(aws ecr describe-repositories --repository-names containerize-your-infra/dns \
  --region "$REGION" --query 'repositories[0].repositoryUri' --output text)
echo "$REPO_URL"
# → <account-id>.dkr.ecr.eu-west-1.amazonaws.com/containerize-your-infra/dns

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${REPO_URL%%/*}"

docker build --platform linux/arm64 -t "$REPO_URL:v1" \
  -f modules/dns/kubernetes/Dockerfile modules/dns/kubernetes
docker push "$REPO_URL:v1"
```

📄 `modules/dns/kubernetes/Dockerfile` — build context is `modules/dns/kubernetes/`

### Why

`internetsystemsconsortium/bind9` is published as a single amd64 manifest and the EKS nodes
are arm64: the Pod crashed with `exec format error`. A Dockerfile on Ubuntu 24.04 gives a
native arm64 build with the same layout as the official image (`/etc/bind`, user `bind`
with UID 101, `named -g`), so the config, probes and chart do not change. The image also
includes `dig`, used by the probes and the validation steps.
The Ubuntu 24.04 package ships BIND 9.18 (Extended Support Version), one minor behind the 9.20 used by the Docker module; the configuration used here exists in both.

The repository is separate from `web-server`: one repository per image keeps tags and
lifecycle independent. It is created by hand, without Terraform — automating it belongs to
the full-infra stack, once the manual procedure is understood. Because it is outside
Terraform state, `terraform destroy` does not remove it; the Teardown deletes it explicitly.

Tags are never reused: a rebuilt image gets a new tag (`v2`) and `values.yaml` follows it.

### Verification

```bash
aws ecr describe-images --repository-name containerize-your-infra/dns --region "$REGION" \
  --query 'imageDetails[*].imageTags' --output text
# → v1

docker image inspect "$REPO_URL:v1" --format '{{.Architecture}}'
# → arm64

docker run --rm --entrypoint id "$REPO_URL:v1" bind
# → uid=101(bind) gid=101(bind) groups=101(bind)

docker run --rm --entrypoint sh "$REPO_URL:v1" -c 'for b in named dig named-checkzone named-checkconf; do command -v $b; done'
# → /usr/sbin/named
# → /usr/bin/dig
# → /usr/bin/named-checkzone
# → /usr/bin/named-checkconf

docker run --rm --entrypoint named "$REPO_URL:v1" -V | head -1
# → BIND 9.18.x (Extended Support Version)
```

---

## Step 2 — Chart Skeleton and Baseline Values

### What was done

The chart directory is created with `Chart.yaml` and the baseline `values.yaml`.
`image.repository` is set to the `REPO_URL` from Step 1 and `image.tag` to `v1`. `appVersion`
in `Chart.yaml` is set to the BIND version printed at the end of Step 1.

Before anything else, the one value that belongs to the cluster and not to the chart is
confirmed: the ClusterIP of the `kube-dns` Service, used in Step 3 to forward
`cluster.local`.

```bash
grep -A3 "^image:" modules/dns/kubernetes/helm/dns/values.yaml
# →   repository: <real-account-id>.dkr.ecr.eu-west-1.amazonaws.com/containerize-your-infra/dns
# →   tag: "v1"
# must NOT contain "<" or ">"

kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}'; echo
# → 172.20.0.10

grep -A1 "kubeDns:" modules/dns/kubernetes/helm/dns/values.yaml
# →   ip: 172.20.0.10
```

If the two `kubeDns.ip` values differ, update `values.yaml` before continuing.

📄 `modules/dns/kubernetes/helm/dns/Chart.yaml` — chart metadata
📄 `modules/dns/kubernetes/helm/dns/values.yaml` — baseline shared by dev and prod

### Why

`kubeDns.ip` is the address the cluster assigns to its own resolver. EKS takes it from
the service CIDR of the cluster (the tenth address of the range), so it is stable while
the VPC and cluster Terraform do not change, but it is cluster state, not chart logic.
Confirming it with `kubectl` turns an assumption into a checked value — a wrong IP would
not fail at install time, only at query time, several steps later.

The same applies to the image: a placeholder in `image.repository` is rejected by
Kubernetes only at Pod scheduling (`InvalidImageName`), several steps away from the mistake.

The Docker module had a fixed IP (`172.20.0.10` on `lab-net`) because clients had to know
where the DNS lived. In Kubernetes that job belongs to the Service name (`dns-dns`):
the Pod IP changes on every restart, the Service name does not. Same principle, different
mechanism.

The release name equals the module name (`dns`), following the convention already used in
`web-server` and `reverse-proxy`. Other modules that need to reach this Service write its
full name, `dns-dns`, never `{{ .Release.Name }}-dns`.

### Verification

```bash
helm lint modules/dns/kubernetes/helm/dns
# → 1 chart(s) linted, 0 chart(s) failed
# → "icon is recommended" is informational
```

---

## Step 3 — Zone and Resolver ConfigMap

### What was done

`templates/configmap.yaml` renders four files into one ConfigMap: `named.conf`,
`named.conf.options`, `named.conf.local` and the zone `db.lab.local`. Four things differ
from the Docker configs, each one deliberate:

- BIND9 listens on `5353` (from `values.yaml`), not `53`.
- `allow-recursion` and `allow-query-cache` use an ACL built from
  `recursion.allowedCIDRs` instead of `any`.
- `dns.lab.local` and `web.lab.local` are `CNAME` records pointing to the Kubernetes
  Services, and `named.conf.local` forwards `cluster.local` to kube-dns so those CNAMEs
  resolve to an IP.
- There is no reverse zone.
- DNSSEC validation is skipped for cluster.local only (validate-except).

```bash
helm template dns modules/dns/kubernetes/helm/dns -n full-infra-dev \
  -f modules/dns/kubernetes/helm/dns/values.yaml \
  -f modules/dns/kubernetes/helm/dns/values-dev.yaml \
  --show-only templates/configmap.yaml
# → ConfigMap dns-dns with named.conf, named.conf.options, named.conf.local, db.lab.local
```

📄 `modules/dns/kubernetes/helm/dns/templates/configmap.yaml`

### Why

The config differs from Docker in four places, each for a practical reason. BIND9 listens on 5353 and the Service publishes 53, so the container keeps `drop: [ALL]` without needing `NET_BIND_SERVICE`; clients never see the difference. Recursion is limited to RFC1918 ranges instead of `any`, so the resolver is not open to everyone — a lab-appropriate ACL, in production it would be the real pod and VPC CIDRs.

The host records are `CNAME`s to the Kubernetes Services instead of `A` records with IPs, because ClusterIPs change on every cluster rebuild. BIND9 follows each CNAME through the `cluster.local` forward zone, which hands those names to CoreDNS. For the same reason there is no reverse zone: PTR records need stable IPs. The NS record points to the Service FQDN, since an NS target cannot be a CNAME.
The `cluster.local` forward needs `validate-except`: CoreDNS does not serve DNSSEC data, and `.local` has no secure delegation, so BIND would otherwise answer SERVFAIL for every CNAME target.

`SOA serial` keeps the `YYYYMMDDNN` convention from build-your-infra.

The serial goes through `int64` in the template: Helm reads large integers from values files as floats and renders them in scientific notation, which `named` rejects as an invalid number.

### Verification

```bash
helm template dns modules/dns/kubernetes/helm/dns -n full-infra-dev \
  -f modules/dns/kubernetes/helm/dns/values.yaml \
  -f modules/dns/kubernetes/helm/dns/values-dev.yaml \
  --show-only templates/configmap.yaml | grep -E "listen-on|CNAME|forwarders"
# → listen-on port 5353 { any; };
# → listen-on-v6 port 5353 { any; };
# → forwarders { 172.20.0.10; };
# → dns  IN CNAME dns-dns.full-infra-dev.svc.cluster.local.
# → web  IN CNAME web-server-web-server.full-infra-dev.svc.cluster.local.

helm template dns modules/dns/kubernetes/helm/dns -n full-infra-dev \
  -f modules/dns/kubernetes/helm/dns/values.yaml \
  -f modules/dns/kubernetes/helm/dns/values-dev.yaml \
  --show-only templates/configmap.yaml | grep Serial
# → 2026093001 ; Serial (never 2.026093001e+09)

helm template dns modules/dns/kubernetes/helm/dns -n full-infra-prod \
  -f modules/dns/kubernetes/helm/dns/values.yaml \
  -f modules/dns/kubernetes/helm/dns/values-prod.yaml \
  --show-only templates/configmap.yaml | grep CNAME
# → same records with full-infra-prod in the target

helm template dns modules/dns/kubernetes/helm/dns -n full-infra-dev \
  -f modules/dns/kubernetes/helm/dns/values.yaml \
  -f modules/dns/kubernetes/helm/dns/values-dev.yaml \
  --show-only templates/configmap.yaml | grep validate-except
# → validate-except { "cluster.local"; };
```

---

## Step 4 — Deployment, Service and Environment Values

### What was done

Three files complete the chart: the Deployment that runs BIND9, the Service that exposes it, and the environment values that make dev and prod differ. The Deployment mounts the ConfigMap read-only at `/etc/bind`, reproduces the Docker hardening (non-root UID/GID 101, all capabilities dropped, read-only root filesystem) and uses `emptyDir` volumes for the writable paths. The Service publishes port 53 on TCP and UDP. `values-dev.yaml` and `values-prod.yaml` hold only real differences: lighter resources in dev, `replicaCount: 2` and higher resources in prod.

No cluster deployment yet: this step only writes and statically validates the manifests. The first `helm install` happens in Step 5.

📄 `modules/dns/kubernetes/helm/dns/templates/deployment.yaml`
📄 `modules/dns/kubernetes/helm/dns/templates/service.yaml`
📄 `modules/dns/kubernetes/helm/dns/values-dev.yaml`
📄 `modules/dns/kubernetes/helm/dns/values-prod.yaml`

### Why

Connect to known: `securityContext` plus `emptyDir` is the Kubernetes equivalent of `cap_drop`, `read_only` and `tmpfs` in Compose, and the values files are the Helm equivalent of `docker-compose.prod.yml` as an override layer.

Some choices are specific to this module:

- The `checksum/config` annotation makes Pods restart when the ConfigMap changes, because Kubernetes does not do it on its own.
- There is no PVC: the zone is static and comes from the ConfigMap, so there is nothing to persist.
- The probes run a `dig` SOA query instead of a port check, because a port check passes even when the zone failed to load.
- The Service is `ClusterIP` and publishes both UDP and TCP: DNS needs both, and a `LoadBalancer` would expose a recursive resolver to the Internet.
- Two replicas in prod is safe because the zone is stateless: both Pods read the same ConfigMap, so there is nothing to synchronize.

The image is the custom build from Step 1, tagged `v1`; tags are never reused.

### Verification

```bash
helm template dns modules/dns/kubernetes/helm/dns -n full-infra-dev \
  -f modules/dns/kubernetes/helm/dns/values.yaml \
  -f modules/dns/kubernetes/helm/dns/values-dev.yaml \
  --show-only templates/deployment.yaml | grep -E "image:|replicas|runAsUser|readOnlyRootFilesystem|containerPort|checksum"
# → image: "<real ECR URI>/containerize-your-infra/dns:v1"
# → replicas: 1
# → runAsUser: 101
# → readOnlyRootFilesystem: true
# → containerPort: 5353 (twice: UDP and TCP)
# → checksum/config: <64-char sha256>

helm template dns modules/dns/kubernetes/helm/dns -n full-infra-dev \
  -f modules/dns/kubernetes/helm/dns/values.yaml \
  --show-only templates/service.yaml | grep -E "type|port:|targetPort|protocol"
# → type: ClusterIP
# → port: 53 / targetPort: dns-udp / protocol: UDP
# → port: 53 / targetPort: dns-tcp / protocol: TCP

helm template dns modules/dns/kubernetes/helm/dns \
  -f modules/dns/kubernetes/helm/dns/values.yaml \
  -f modules/dns/kubernetes/helm/dns/values-prod.yaml \
  --show-only templates/deployment.yaml | grep replicas
# → replicas: 2

helm lint modules/dns/kubernetes/helm/dns \
  -f modules/dns/kubernetes/helm/dns/values.yaml -f modules/dns/kubernetes/helm/dns/values-dev.yaml
helm lint modules/dns/kubernetes/helm/dns \
  -f modules/dns/kubernetes/helm/dns/values.yaml -f modules/dns/kubernetes/helm/dns/values-prod.yaml
# → 1 chart(s) linted, 0 chart(s) failed (both)
```

---

## Step 5 — Deploy to full-infra-dev and Validate

### What was done

First real deployment. One release, `dns`, in `full-infra-dev`. Queries are run from a
temporary client Pod inside the cluster — the only context from which a `ClusterIP` Service
is reachable — using the module image from Step 1, which already contains `dig`.

```bash
REPO_URL=$(aws ecr describe-repositories --repository-names containerize-your-infra/dns \
  --region eu-west-1 --query 'repositories[0].repositoryUri' --output text)

helm install dns modules/dns/kubernetes/helm/dns -n full-infra-dev \
  -f modules/dns/kubernetes/helm/dns/values.yaml \
  -f modules/dns/kubernetes/helm/dns/values-dev.yaml
```

📄 `modules/dns/kubernetes/helm/dns/` — full chart

### Why

The client runs in the same namespace, so `dns-dns` resolves through the Pod's search
domain. Testing from a Pod and not with `kubectl port-forward` matters here: `port-forward`
only carries TCP, so it cannot validate UDP, which is the transport DNS uses by default.

Validating the workload, the authoritative zone, the CNAME chase and external forwarding
as separate checks means a failure points at one layer: Pod, zone, `cluster.local`
forward, or Internet egress.

### Verification

```bash
kubectl get pods -n full-infra-dev -l app.kubernetes.io/name=dns
# → 1/1 Running

kubectl get svc,endpoints dns-dns -n full-infra-dev
# → ClusterIP, 53/UDP,53/TCP; endpoints list one Pod IP on :5353

kubectl logs -n full-infra-dev deploy/dns-dns | grep -iwE "error|failed"
# → no output

kubectl exec -n full-infra-dev deploy/dns-dns -- id
# → uid=101(bind) gid=101(bind)

kubectl exec -n full-infra-dev deploy/dns-dns -- touch /etc/bind/test
# → touch: cannot touch '/etc/bind/test': Read-only file system

kubectl exec -n full-infra-dev deploy/dns-dns -- named-checkconf /etc/bind/named.conf
# → no output

kubectl exec -n full-infra-dev deploy/dns-dns -- named-checkzone lab.local /etc/bind/db.lab.local
# → zone lab.local/IN: loaded serial 2026093001
# → OK

# Client Pod: authoritative zone, CNAME chase, transport, external forwarding
kubectl run dns-client -n full-infra-dev --restart=Never \
  --image="$REPO_URL:v1" --command -- sleep 3600
kubectl wait -n full-infra-dev --for=condition=Ready pod/dns-client --timeout=60s
# → pod/dns-client condition met

kubectl exec -n full-infra-dev dns-client -- dig @dns-dns lab.local SOA +short
# → dns-dns.full-infra-dev.svc.cluster.local. admin.lab.local. 2026093001 3600 1800 604800 86400

kubectl exec -n full-infra-dev dns-client -- dig @dns-dns web.lab.local +short
# → web-server-web-server.full-infra-dev.svc.cluster.local.
# → <ClusterIP of web-server-web-server>

kubectl get svc web-server-web-server -n full-infra-dev -o jsonpath='{.spec.clusterIP}'; echo
# → same IP as the last line above

kubectl exec -n full-infra-dev dns-client -- dig @dns-dns +tcp dns.lab.local +short
# → dns-dns.full-infra-dev.svc.cluster.local.
# → <ClusterIP of dns-dns>

kubectl exec -n full-infra-dev dns-client -- dig @dns-dns google.com +short
# → one or more external IP addresses
```

---

## Step 6 — Config Rollout and Rollback

### What was done

The zone serial is incremented through `values` and rolled out with `helm upgrade`. The
new serial is observed from a client Pod, and the release is then reverted with
`helm rollback` to a revision confirmed as healthy.

```bash
helm upgrade dns modules/dns/kubernetes/helm/dns -n full-infra-dev \
  -f modules/dns/kubernetes/helm/dns/values.yaml \
  -f modules/dns/kubernetes/helm/dns/values-dev.yaml \
  --set zone.serial=2026093002

kubectl rollout status deploy/dns-dns -n full-infra-dev
# → successfully rolled out

kubectl exec -n full-infra-dev dns-client -- dig @dns-dns lab.local SOA +short
# → ... 2026093002 3600 1800 604800 86400

helm history dns -n full-infra-dev
# → revision 1 (superseded, first install), revision 2 (deployed, serial bump)

helm rollback dns <revision-with-serial-2026093001> -n full-infra-dev
kubectl rollout status deploy/dns-dns -n full-infra-dev
# → successfully rolled out

kubectl exec -n full-infra-dev dns-client -- dig @dns-dns lab.local SOA +short
# → ... 2026093001 3600 1800 604800 86400
```

### Why

This step validates the `checksum/config` annotation from Step 4: the only thing that
changed was a ConfigMap value, and the Pods were still replaced. It is the Kubernetes
version of the Docker doc's smoke-test step, but rollout is a first-class object here
(`helm history`, `kubectl rollout`) instead of a manual down/up cycle.

The rollback target is read from the real release history, never assumed as a fixed
number: revision numbers are consumed by failed upgrades and manual interventions without
guaranteeing a healthy state. Rolling back to a hardcoded revision is incorrect in any
context.

Note the serial goes down on rollback. With no secondary servers nothing is affected; with
secondaries, a lower serial would make them ignore the zone. It is one more reason the
serial should only move forward in a real environment.

### Verification

```bash
kubectl get pods -n full-infra-dev -l app.kubernetes.io/name=dns
# → 1/1 Running, no CrashLoopBackOff
```

---

## Production deployment

The same chart is installed in `full-infra-prod` with `values-prod.yaml`. The image, config
and hardening are identical; what changes is the operational layer.

| Parameter | dev | prod |
|---|---|---|
| Replicas | 1 | 2 |
| Resources | 25m / 64Mi requests, 100m / 96Mi limits | 100m / 96Mi requests, 300m / 192Mi limits |
| CNAME targets | `full-infra-dev` Services | `full-infra-prod` Services |
| Service type | `ClusterIP` | `ClusterIP` |

```bash
helm install dns modules/dns/kubernetes/helm/dns -n full-infra-prod \
  -f modules/dns/kubernetes/helm/dns/values.yaml \
  -f modules/dns/kubernetes/helm/dns/values-prod.yaml

kubectl delete pod dns-client -n full-infra-dev
```

📄 `modules/dns/kubernetes/helm/dns/values-prod.yaml`

### Verification

```bash
kubectl get pods -n full-infra-prod -l app.kubernetes.io/name=dns -o wide
# → 2/2 Running (check the NODE column: same node or different nodes)

kubectl get endpoints dns-dns -n full-infra-prod
# → two Pod IPs on :5353

kubectl run dns-client -n full-infra-prod --restart=Never \
  --image="$REPO_URL:v1" --command -- sleep 3600
kubectl wait -n full-infra-prod --for=condition=Ready pod/dns-client --timeout=60s
# → pod/dns-client condition met

kubectl exec -n full-infra-prod dns-client -- dig @dns-dns web.lab.local +short
# → web-server-web-server.full-infra-prod.svc.cluster.local.
# → <ClusterIP of web-server-web-server in prod>

kubectl exec -n full-infra-prod dns-client -- dig @dns-dns google.com +short
# → one or more external IP addresses

# Losing one replica does not interrupt resolution
kubectl delete -n full-infra-prod --wait=false \
  $(kubectl get pods -n full-infra-prod -l app.kubernetes.io/name=dns -o name | head -n 1)
kubectl exec -n full-infra-prod dns-client -- dig @dns-dns lab.local SOA +short
# → an answer from the remaining replica while the other one is replaced

kubectl get pods -n full-infra-prod -l app.kubernetes.io/name=dns
# → back to 2/2 Running after a few seconds
```

### Teardown

```bash
helm uninstall dns -n full-infra-dev
helm uninstall dns -n full-infra-prod

aws ecr delete-repository --repository-name containerize-your-infra/dns --region eu-west-1 --force
```

The releases create no resources outside the cluster: no load balancer, no volume, no
Secret. The ECR repository from Step 1 was created by hand, outside Terraform, so
`terraform destroy` does not remove it and it is deleted explicitly. The order with respect
to `terraform destroy` does not matter for this module, unlike `reverse-proxy`, whose
Service provisions an ELB. `bootstrap-down.sh` does not know about this release or
repository.

---
