# Full Infrastructure Stack — Kubernetes

**Amazon EKS · Helm umbrella chart · web-server · reverse-proxy · dns · containerize-your-infra**

---

## Introduction

This document covers the deployment of the three Kubernetes modules — web-server, reverse-proxy and dns — as a single unit through the `full-infra` umbrella chart, in both `full-infra-dev` and `full-infra-prod`. Each module was already implemented and verified on its own (`modules/*/kubernetes/*-kubernetes.md`); this stack is the integration layer that connects them, as `stacks/full-infra/docker/full-infra-docker.md` does for Compose.

The Docker implementation is the functional baseline: Traefik as the single entry point, web-server as the backend and BIND9 as the resolver. Kubernetes reproduces the same topology. `file-transfer` is not part of this stack — it is not migrated to Kubernetes.

| Parameter | Value |
|---|---|
| Umbrella chart | `stacks/full-infra/kubernetes/helm/full-infra/` |
| Dependencies | `web-server`, `reverse-proxy` (which carries `traefik/traefik 41.5.0`) and `dns`, all `file://` |
| Release name | `full-infra` in both namespaces |
| Namespaces | `full-infra-dev`, `full-infra-prod` |
| Images | `containerize-your-infra/web-server` (`v1`, `dev`, `prod`), `containerize-your-infra/dns` (`v1`, arm64) |
| Exposure | Traefik `ClusterIP` in dev (`kubectl port-forward`), `LoadBalancer` (Classic ELB) in prod |
| Hostname | `web.local` through the Host header — no Route53, no custom domain |
| Environment delta | Helm values only: replicas, resources, image tags, Service type, watched namespace |

> **The release name differs from the module docs.** Each module doc installed its chart with release name = module name. Under the umbrella there is a single release, `full-infra`, so the resource names derived from `.Release.Name` change: the web-server Service is `full-infra-web-server` and the dns Service is `full-infra-dns`. The two cross-module references are reconciled in the umbrella values (Step 4), without modifying the module charts.

> **Prerequisites:** the three modules implemented and verified individually. AWS CLI configured with permissions for EKS and ECR, `kubectl`, `helm`, Docker, `openssl`, `htpasswd` (`apache2-utils`) and `jq`.

---

## Before You Start

The platform — VPC, EKS cluster, node group and namespaces — is provisioned by Terraform as described in [`automation.md`](automation.md). This document does not create it; Step 1 only checks that it exists.

Everything else this stack needs lives in the registry or inside the cluster and is created in Steps 2 and 3:

| Created in this document | Step | Lifetime |
|---|---|---|
| ECR repositories and container images | 2 | Registry, separate Terraform state for web-server |
| `ResourceQuota` and `LimitRange` (prod) | 3 | Namespace-scoped, lost with the cluster |
| TLS and dashboard-auth Secrets | 3 | Namespace-scoped, lost with the cluster |

Set the session variables once. Every later step reuses them; if you open a new shell, run this block again.

```bash
REGION=eu-west-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) || return 1
REGISTRY=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
WS_REPO=$REGISTRY/containerize-your-infra/web-server
DNS_REPO=$REGISTRY/containerize-your-infra/dns
REPO_ROOT=$(git rev-parse --show-toplevel)
```

---

## Step 1 — Verify the platform

### What was done

The cluster and the namespaces are checked before anything is built or deployed.

📄 [`automation.md`](automation.md) — provisions the EKS platform

### Why

Same pattern as the module docs: a deployment starts from a confirmed state, not an assumed one. If a check fails, provision the platform first with [`automation.md`](automation.md).

The `kube-dns` ClusterIP matters because the dns chart forwards `cluster.local` to it (`kubeDns.ip`, default `172.20.0.10`). EKS takes it from the cluster service CIDR, so it is stable while the Terraform does not change, but it is cluster state, not chart logic. A wrong value does not fail at install; it fails at query time.

### Verification

```bash
kubectl get nodes -L kubernetes.io/arch
# → 2 nodes, STATUS Ready, ARCH arm64

kubectl get ns full-infra-dev full-infra-prod ingress-system
# → all three Active

helm list -A
# → no releases

kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}{"\n"}'
# → 172.20.0.10
```

> If the `kube-dns` address differs from `172.20.0.10`, add `--set dns.kubeDns.ip=<address>` to every `helm install` and `helm upgrade` in this document.

---

## Step 2 — Container registries and images

### What was done

Both ECR repositories are created with Terraform, then both images are built and pushed.

```bash
# ECR repositories (web-server and dns) — Terraform, isolated state
terraform -chdir=stacks/full-infra/kubernetes/automation/terraform/registry init
terraform -chdir=stacks/full-infra/kubernetes/automation/terraform/registry apply

# Authenticate Docker against the registry
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REGISTRY

# web-server image
docker build -t $WS_REPO:v1 -f modules/web-server/docker/Dockerfile modules/web-server/docker
for TAG in v1 dev prod; do docker tag $WS_REPO:v1 $WS_REPO:$TAG; docker push $WS_REPO:$TAG; done

# dns image
docker build --platform linux/arm64 -t $DNS_REPO:v1 -f modules/dns/kubernetes/Dockerfile modules/dns/kubernetes
docker push $DNS_REPO:v1
```

📄 `automation/terraform/registry/ecr.tf` — `aws_ecr_repository` and lifecycle policy for `web-server` and `dns`
📄 `modules/web-server/docker/Dockerfile` — build context reused as-is
📄 `modules/dns/kubernetes/Dockerfile` — custom BIND9 image on Ubuntu 24.04

### Why

Kubernetes does not build images, it pulls them: the repository and the image must exist before any Pod can start. The registry URI is computed from the AWS account, so the same commands work for anyone who clones the repository.

Both repositories come from the registry Terraform, whose state is isolated from the cluster's: a cluster teardown never removes build artifacts. Terraform owns the repositories only — images are built and pushed here, and tags stay immutable. A repository per image keeps tags and lifecycle independent.

The `dns` image is custom because the official ISC image is published for amd64 only and the EKS nodes are arm64. Tags are never reused: `dev` and `prod` are aliases of the same `v1` build today, and a floating `latest` would remove the ability to roll back (Step 7).

### Verification

```bash
terraform -chdir=stacks/full-infra/kubernetes/automation/terraform/registry output
# → repository_url     = "<account-id>.dkr.ecr.eu-west-1.amazonaws.com/containerize-your-infra/web-server"
# → dns_repository_url = "<account-id>.dkr.ecr.eu-west-1.amazonaws.com/containerize-your-infra/dns"

aws ecr describe-repositories --region $REGION --query 'repositories[].[repositoryName,imageTagMutability]' --output text
# → containerize-your-infra/web-server  IMMUTABLE
# → containerize-your-infra/dns         IMMUTABLE

aws ecr describe-images --repository-name containerize-your-infra/web-server --region $REGION --query 'imageDetails[].imageTags[]' --output text
# → v1  dev  prod

aws ecr describe-images --repository-name containerize-your-infra/dns --region $REGION --query 'imageDetails[].imageTags[]' --output text
# → v1

docker image inspect $DNS_REPO:v1 --format '{{.Architecture}}'
# → arm64
```

---

## Step 3 — Cluster prerequisites

### What was done

Production guardrails and the two Secrets Traefik needs are created before the chart is installed.

```bash
# Production guardrails (see environments/kubernetes/prod/setup.md)
kubectl apply -f environments/kubernetes/prod/resource-quota.yaml
kubectl apply -f environments/kubernetes/prod/limit-range.yaml

# Self-signed certificate
mkdir -p tmp/reverse-proxy-certs
openssl req -x509 -newkey rsa:4096 -nodes \
  -keyout tmp/reverse-proxy-certs/lab.key -out tmp/reverse-proxy-certs/lab.crt \
  -days 365 -subj "/CN=web.local" -addext "subjectAltName=DNS:web.local"

for NS in full-infra-dev full-infra-prod; do
  kubectl create secret tls reverse-proxy-tls \
    --cert=tmp/reverse-proxy-certs/lab.crt --key=tmp/reverse-proxy-certs/lab.key -n $NS
done

# Dashboard BasicAuth (prompts for the password)
HASH=$(htpasswd -nB admin)
for NS in full-infra-dev full-infra-prod; do
  kubectl create secret generic reverse-proxy-dashboard-auth --from-literal=users="$HASH" -n $NS
done
unset HASH
```

📄 `environments/kubernetes/prod/resource-quota.yaml` — namespace aggregate cap
📄 `environments/kubernetes/prod/limit-range.yaml` — per-container defaults and maximum

> **Do not commit `tmp/reverse-proxy-certs/`.** Key material and password hashes never enter Git. The RBAC from `prod/setup.md` Step 3 is applied after the production deployment (Step 6), not here.

### Why

These objects are cluster state, not chart content, and must exist before `helm install`. A missing Secret does not fail at install: Traefik reads TLS material from a `kubernetes.io/tls` Secret and the Middleware references the auth Secret by name, so the failure shows up at request time. The Secret key must be named `users`, which is what Traefik's CRD provider reads. Neither Secret name depends on the release name, so both are unchanged under the umbrella.

The quota and the LimitRange are applied first so that the production deployment is tested under the real constraints. The LimitRange caps every container at 500m CPU and 512Mi memory; the quota caps the namespace at 1500m CPU, 3Gi memory (requests) and 20 Pods. Containers with no `resources` block — Traefik's, by default — receive the LimitRange defaults (requests 100m / 128Mi, limits 250m / 256Mi). Prod then requests 500m CPU and 576Mi memory in total, with limits of 1450m and 1152Mi, well inside the quota.

The self-signed certificate is a lab-appropriate pattern, not a production one: production would use cert-manager against a real CA. It is issued for `web.local` because routing is by Host header, so it never has to be reissued when the ELB name changes.

### Verification

```bash
kubectl describe resourcequota full-infra-prod-quota -n full-infra-prod
# → Hard: requests.cpu 1500m, requests.memory 3Gi, limits.cpu 3, limits.memory 6Gi, pods 20

kubectl describe limitrange full-infra-prod-limits -n full-infra-prod
# → Container: Max cpu 500m memory 512Mi, Default cpu 250m memory 256Mi

for NS in full-infra-dev full-infra-prod; do
  kubectl get secret reverse-proxy-tls -n $NS -o jsonpath='{.type}{"\n"}'
  kubectl get secret reverse-proxy-dashboard-auth -n $NS -o jsonpath='{.data.users}' | base64 -d | cut -d: -f1
done
# → kubernetes.io/tls
# → admin
# (repeated for the second namespace)
```

---

## Step 4 — Umbrella chart

### What was done

The umbrella chart composes the three module charts and overrides, from a single place, what changes when they run as one release. Resolve the dependencies bottom-up: first the Traefik dependency of `reverse-proxy`, then the umbrella.

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm dependency build modules/reverse-proxy/kubernetes/helm/reverse-proxy

cd stacks/full-infra/kubernetes/helm/full-infra
helm dependency build
```

Validate both environments:

```bash
for ENV in dev prod; do
  helm lint . -f values.yaml -f values-$ENV.yaml \
    --set web-server.image.repository=$WS_REPO --set dns.image.repository=$DNS_REPO
done
```

📄 `helm/full-infra/Chart.yaml` — three `file://` dependencies
📄 `helm/full-infra/values.yaml` — cross-module Service names
📄 `helm/full-infra/values-dev.yaml` — dev deltas for the three modules
📄 `helm/full-infra/values-prod.yaml` — prod deltas for the three modules

> `charts/` is build output, not source. Add `stacks/full-infra/kubernetes/helm/full-infra/charts/` and `modules/reverse-proxy/kubernetes/helm/reverse-proxy/charts/` to `.gitignore`.

### Why

An umbrella chart has no templates of its own: it composes subcharts and overrides their values from one place. `file://` dependencies keep each module chart as the single source of truth.

- **Build order.** `helm dependency build` on the umbrella packages `reverse-proxy` as it is on disk and does not resolve its own dependencies. Building `reverse-proxy` first puts Traefik inside it; skipping that renders an umbrella without Traefik.
- **Values scope.** A subchart reads only the values nested under its own name. The module `values-dev.yaml` and `values-prod.yaml` files are not loaded by the umbrella, so their deltas are reproduced under `web-server:`, `reverse-proxy:` and `dns:` in the umbrella environment files. Helm merges maps deeply, so unrepeated module defaults are preserved.
- **Names.** Modules name resources `<release>-<chart>`, so under release `full-infra` the web-server Service is `full-infra-web-server` and the dns Service `full-infra-dns`. Three values referenced the old names and are overridden in `values.yaml`:

| Value | Module default | Umbrella value |
|---|---|---|
| `reverse-proxy.reverseProxy.backendServiceName` | `web-server-web-server` | `full-infra-web-server` |
| `dns.zone.hosts.web` | `web-server-web-server` | `full-infra-web-server` |
| `dns.zone.hosts.dns` | `dns-dns` | `full-infra-dns` |

A wrong name does not fail at install: Traefik drops the router (`404`) and the CNAMEs resolve to NXDOMAIN only at query time. Image repositories are not stored in the values because they depend on the AWS account; they are passed with `--set`.

### Verification

```bash
helm dependency list
# → web-server, reverse-proxy, dns — STATUS ok

tar -tzf charts/reverse-proxy-0.1.0.tgz | grep -m1 'charts/traefik/Chart.yaml'
# → reverse-proxy/charts/traefik/Chart.yaml

for ENV in dev prod; do
  helm lint . -f values.yaml -f values-$ENV.yaml --set web-server.image.repository=$WS_REPO --set dns.image.repository=$DNS_REPO
done
# → 1 chart(s) linted, 0 chart(s) failed   (twice)

helm template full-infra . -n full-infra-dev -f values.yaml -f values-dev.yaml \
  --set web-server.image.repository=$WS_REPO --set dns.image.repository=$DNS_REPO > /tmp/full-infra-dev.yaml

helm template full-infra . -n full-infra-prod -f values.yaml -f values-prod.yaml \
  --set web-server.image.repository=$WS_REPO --set dns.image.repository=$DNS_REPO > /tmp/full-infra-prod.yaml

grep -c 'web-server-web-server\|dns-dns' /tmp/full-infra-dev.yaml
# → 0   (no reference to the old names)

grep -E 'name: full-infra-(web-server|dns)$' /tmp/full-infra-dev.yaml | sort | uniq -c
# → resources named full-infra-web-server and full-infra-dns

grep -E 'CNAME' /tmp/full-infra-prod.yaml
# → dns IN CNAME full-infra-dns.full-infra-prod.svc.cluster.local.
# → web IN CNAME full-infra-web-server.full-infra-prod.svc.cluster.local.

grep -c '^kind: Deployment' /tmp/full-infra-dev.yaml
# → 3   (web-server, dns, traefik)

grep -n -B6 'type: LoadBalancer' /tmp/full-infra-dev.yaml
# → type: LoadBalancer

for ENV in dev prod; do
  echo "== $ENV"
  awk '/^kind: Service$/{s=1} s&&/^  type:/{print; s=0}' /tmp/full-infra-$ENV.yaml
done
# → == dev
# →  type: ClusterIP
# →  type: ClusterIP
# →  type: ClusterIP
# → == prod
# →  type: ClusterIP
# →  type: ClusterIP
# →  type: LoadBalancer

grep -E 'replicas:' /tmp/full-infra-prod.yaml
# → replicas: 2 (web-server), replicas: 2 (dns), replicas: 1 (traefik)

grep -E 'image: ' /tmp/full-infra-dev.yaml
# → $WS_REPO:dev, $DNS_REPO:v1, docker.io/traefik:v3.7.13
```

---

## Step 5 — Deploy and validate full-infra-dev

### What was done

A single release installs the three modules in `full-infra-dev`, and the stack is validated from the outside in: Traefik routing, the dashboard, then DNS from a client Pod.

```bash
helm install full-infra . -n full-infra-dev \
  -f values.yaml -f values-dev.yaml \
  --set web-server.image.repository=$WS_REPO --set dns.image.repository=$DNS_REPO

kubectl rollout status deploy/full-infra-web-server deploy/full-infra-dns -n full-infra-dev
kubectl get pods -n full-infra-dev

# Traefik through port-forward (kept open until the end of the verification)
kubectl port-forward -n full-infra-dev $(kubectl get svc -n full-infra-dev -l app.kubernetes.io/name=traefik -o name) 8443:443 &
sleep 3

# DNS client Pod
kubectl run dns-client -n full-infra-dev --restart=Never --image=$DNS_REPO:v1 --command -- sleep 3600
kubectl wait -n full-infra-dev --for=condition=Ready pod/dns-client --timeout=60s
```

### Why

One release means one revision history for the whole stack: `helm rollback full-infra` reverts web-server, reverse-proxy and dns together. The trade-off is that a single failing subchart fails the whole install. Helm installs the CRDs of the nested Traefik chart first, so the IngressRoute and Middleware objects in the same release apply cleanly.

`ClusterIP` in dev keeps validation free of AWS cost, and `port-forward` reaches Traefik from the workstation. Routing is by `Host: web.local`, not by address. The Traefik Service is selected by label because its generated name is not part of this stack's contract.

DNS is tested from a Pod, not with `port-forward`, which only carries TCP and cannot validate UDP, the default DNS transport. Each check isolates one layer: Traefik to web-server (routing), the Middleware (authentication), BIND9 (zone), the `cluster.local` forward (CNAME chase) and egress (forwarders).

### Verification

```bash
kubectl get pods -n full-infra-dev
# → full-infra-web-server 1/1 Running, full-infra-dns 1/1 Running, traefik 1/1 Running

kubectl get endpoints full-infra-web-server full-infra-dns -n full-infra-dev
# → web-server 8080, dns 5353 — one Pod IP each

curl -k -I -H 'Host: web.local' https://localhost:8443/
# → HTTP/2 200

curl -k -I -H 'Host: web.local' https://localhost:8443/dashboard/
# → HTTP/2 401

curl -k -I -u admin -H 'Host: web.local' https://localhost:8443/dashboard/
# → HTTP/2 200 (prompts for the password)

curl -k -I https://localhost:8443/
# → HTTP/2 404   (no Host header matches no router)

kubectl exec -n full-infra-dev dns-client -- dig @full-infra-dns lab.local SOA +short
# → full-infra-dns.full-infra-dev.svc.cluster.local. admin.lab.local. 2026093001 3600 1800 604800 86400

kubectl exec -n full-infra-dev dns-client -- dig @full-infra-dns web.lab.local +short
# → full-infra-web-server.full-infra-dev.svc.cluster.local.
# → <ClusterIP of full-infra-web-server>

kubectl get svc full-infra-web-server -n full-infra-dev -o jsonpath='{.spec.clusterIP}{"\n"}'
# → same IP as the last line above

kubectl exec -n full-infra-dev dns-client -- dig @full-infra-dns +tcp dns.lab.local +short
# → full-infra-dns.full-infra-dev.svc.cluster.local.
# → <ClusterIP of full-infra-dns>

kubectl exec -n full-infra-dev dns-client -- dig @full-infra-dns google.com +short
# → one or more external IP addresses

kill %1

kubectl delete pod dns-client -n full-infra-dev
```

---

## Step 6 — Deploy and validate full-infra-prod

### What was done

The same chart is installed in `full-infra-prod` with the production values. Traefik is exposed through a Classic ELB.

```bash
helm install full-infra . -n full-infra-prod \
  -f values.yaml -f values-prod.yaml \
  --set web-server.image.repository=$WS_REPO --set dns.image.repository=$DNS_REPO

kubectl rollout status deploy/full-infra-web-server deploy/full-infra-dns -n full-infra-prod

# Wait for the ELB hostname and for its DNS record to resolve
until ELB=$(kubectl get svc -n full-infra-prod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}') && [ -n "$ELB" ]; do sleep 10; done
until ELB_IP=$(dig +short $ELB | head -1) && [ -n "$ELB_IP" ]; do sleep 10; done

curl -k -I --resolve web.local:443:$ELB_IP https://web.local/
curl -k -I --resolve web.local:443:$ELB_IP -u admin https://web.local/dashboard/

kubectl run dns-client -n full-infra-prod --restart=Never --image=$DNS_REPO:v1 --command -- sleep 3600
kubectl wait -n full-infra-prod --for=condition=Ready pod/dns-client --timeout=60s
kubectl exec -n full-infra-prod dns-client -- dig @full-infra-dns web.lab.local +short
kubectl exec -n full-infra-prod dns-client -- dig @full-infra-dns google.com +short

# Losing one dns replica does not interrupt resolution
kubectl delete -n full-infra-prod $(kubectl get pods -n full-infra-prod -l app.kubernetes.io/name=dns -o name | head -1) --wait=false
kubectl exec -n full-infra-prod dns-client -- dig @full-infra-dns lab.local SOA +short
```

Then apply the read-only RBAC for the namespace, as documented in `prod/setup.md` Step 3, and remove the client Pod:

```bash
kubectl delete pod dns-client -n full-infra-prod
kubectl apply -f environments/kubernetes/prod/rbac-prod-viewer.yaml
```

📄 `environments/kubernetes/prod/rbac-prod-viewer.yaml` — read-only access for the namespace

### Why

Same chart, same images and same templates: prod differs only in values — replicas, resources, Service type and watched namespace. The ELB is provisioned automatically by the in-tree AWS cloud provider when the Service is `type: LoadBalancer`; no AWS Load Balancer Controller is installed. It is a billable resource that Terraform does not track, which is why the release must be uninstalled before the cluster is destroyed (Teardown).

`--resolve` sends the request to the ELB address while keeping `web.local` as Host and SNI, so the certificate issued for `web.local` is accepted without DNS or a custom domain. The ELB hostname can take a few minutes to resolve after it is created, hence the wait loops.

RBAC is applied last because the read-only role restricts the namespace by design; applying it earlier would block the Helm operations of this document.

### Verification

```bash
kubectl get pods -n full-infra-prod -o wide
# → full-infra-web-server 2/2, full-infra-dns 2/2, traefik 1/1 Running

kubectl describe resourcequota full-infra-prod-quota -n full-infra-prod
# → Used within Hard: requests.cpu <= 1500m, requests.memory <= 3Gi, pods <= 20

curl -k -I --resolve web.local:443:$ELB_IP https://web.local/
# → HTTP/2 200

curl -k -I --resolve web.local:443:$ELB_IP -u admin https://web.local/dashboard/
# → HTTP/2 200

kubectl get endpoints full-infra-web-server full-infra-dns -n full-infra-prod
# → two Pod IPs each
```

---

## Step 7 — Rolling update and rollback

### What was done

A new web-server image is rolled out through the umbrella release and reverted with `helm rollback`, in `full-infra-dev`.

```bash
docker build -t $WS_REPO:v2 -f $(git rev-parse --show-toplevel)/modules/web-server/docker/Dockerfile $(git rev-parse --show-toplevel)/modules/web-server/docker
docker push $WS_REPO:v2

helm upgrade full-infra . -n full-infra-dev \
  -f values.yaml -f values-dev.yaml \
  --set web-server.image.repository=$WS_REPO --set dns.image.repository=$DNS_REPO \
  --set web-server.image.tag=v2
kubectl rollout status deploy/full-infra-web-server -n full-infra-dev

helm history full-infra -n full-infra-dev

# Identify the previous revision and confirm its image before rolling back
PREV=$(helm history full-infra -n full-infra-dev --max 2 -o json | jq -r '.[0].revision')
helm get manifest full-infra -n full-infra-dev --revision $PREV | grep 'image:.*web-server'

helm rollback full-infra $PREV -n full-infra-dev
kubectl rollout status deploy/full-infra-web-server -n full-infra-dev
```

### Why

One release, one history: the upgrade changes only web-server, but the revision belongs to the stack. The rollback target is read from the release history and its image is confirmed in the stored manifest before use — never assumed as a fixed number, because failed upgrades and manual interventions consume revision numbers without guaranteeing a healthy state.

The `--set` flags are repeated on every `upgrade`: values passed with `--set` at install are not kept unless `--reuse-values` is used, and an upgrade without them falls back to the repository stored in the module defaults. Tags are never reused — `v2` is a new tag, not an overwrite of `dev`.

### Verification

```bash
kubectl get deploy full-infra-web-server -n full-infra-dev -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# → .../containerize-your-infra/web-server:v2   (after the upgrade)
# → .../containerize-your-infra/web-server:dev  (after the rollback)

kubectl get pods -n full-infra-dev
# → all Running, no InvalidImageName or ImagePullBackOff

helm history full-infra -n full-infra-dev
# → revision 1 superseded, revision 2 superseded, revision 3 deployed (Rollback to 1)
```

---

## Teardown

### What was done

The release is removed first, so the Traefik `LoadBalancer` Service releases its ELB; only then are the platform and the registry destroyed.

```bash
helm uninstall full-infra -n full-infra-dev
helm uninstall full-infra -n full-infra-prod

# Repeat until the list is empty
aws elb describe-load-balancers --region $REGION --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text

terraform -chdir=stacks/full-infra/kubernetes/automation/terraform/cluster destroy
terraform -chdir=stacks/full-infra/kubernetes/automation/terraform/registry destroy
```

📄 `automation/terraform/cluster/` — EKS platform state
📄 `automation/terraform/registry/` — ECR repositories state

### Why

The ELB is created by Kubernetes, not by Terraform. If the cluster is destroyed first, the ELB is orphaned: it keeps billing and blocks deletion of the VPC subnets, and Terraform cannot see it to clean it up.

The registry is destroyed last and separately because it has its own state. Both repositories are removed in the same `destroy`, together with their images (`force_delete`), so the next cycle starts from zero: Step 2 recreates the repositories and rebuilds both images.

Secrets, the quota, the LimitRange and the RBAC objects are namespace-scoped and disappear with the cluster, as do the CRDs installed by Traefik.

### Verification

```bash
# Before destroying the cluster
helm list -A
# → no releases

# After both destroys
aws elb describe-load-balancers --region $REGION --query 'LoadBalancerDescriptions[]'
# → []

aws eks list-clusters --region $REGION --query 'clusters'
# → []

aws ecr describe-repositories --region $REGION --query 'repositories[].repositoryName'
# → []
```
