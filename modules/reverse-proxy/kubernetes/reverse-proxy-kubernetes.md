# Reverse Proxy — containerize-your-infra

**Kubernetes · Helm chart on Amazon EKS (namespaces `full-infra-dev` / `full-infra-prod`)**

---

## Introduction

This document migrates the Traefik reverse proxy to Kubernetes as an Ingress Controller.
The Docker implementation (`modules/reverse-proxy/docker/reverse-proxy-docker.md`) remains
the functional baseline — Traefik's role does not change (TLS termination, host-based
routing, dashboard with BasicAuth), only the discovery mechanism and the deployment model.

> **Docker labels → Kubernetes CRDs.** In Docker, Traefik discovers backends via labels on
> containers (`traefik.enable=true`, router/service rules). In Kubernetes, the same
> dynamic-config model is expressed through the **IngressRoute** and **Middleware** CRDs
> that ship with Traefik's Helm chart. No standard `Ingress` + annotations layer is
> introduced, to avoid mixing two routing models on the same controller.

> **What this module is, in Kubernetes terms.** Traefik here is an *Ingress Controller*:
> an ordinary workload (a Deployment running Traefik pods) that watches custom resources
> and routes traffic accordingly. It is exposed through a Service (type `ClusterIP` in dev,
> `LoadBalancer` in prod). The `IngressRoute` and `Middleware` objects are configuration,
> not workloads. `web-server`, by contrast, is a Deployment plus a `ClusterIP` Service.

> **This module depends on `web-server`.** End-to-end routing requires the `web-server`
> Helm release already running in the target namespace
> (`modules/web-server/kubernetes/web-server-kubernetes.md`). This chart does not declare
> its own backend for isolated testing.

> **Chart files in `helm/reverse-proxy/`** contain only what this module adds on top of the
> official `traefik/traefik` chart, declared as a Helm dependency. Paths are referenced
> after each deploy block, following the same 📄 convention as every other module doc.

> **One release per environment namespace.** The same chart is installed once in
> `full-infra-dev` and once in `full-infra-prod`, each with its own Traefik instance.
> The `ingress-system` namespace created by the platform is not used by this module.
> Step 3 explains the two settings that make this safe.

---

## Environment

| Parameter            | Value                                                                 |
|----------------------|-----------------------------------------------------------------------|
| Chart dependency     | `traefik/traefik` `41.5.0` (appVersion `v3.7.13`), pinned             |
| Cluster              | Amazon EKS (foundation already provisioned)                           |
| Release name         | `reverse-proxy` in both namespaces                                    |
| Namespaces           | `full-infra-dev`, `full-infra-prod` — one Traefik instance each       |
| Container ports      | `web` 8000, `websecure` 8443 (non-root, chart defaults — not overridden) |
| Service ports        | 80 → `web`, 443 → `websecure`                                         |
| TLS                  | Self-signed cert, `kubernetes.io/tls` Secret `reverse-proxy-tls` (dev and prod) |
| Dashboard            | Enabled — BasicAuth Middleware, Secret `reverse-proxy-dashboard-auth` |
| Service type         | `ClusterIP` (dev, `kubectl port-forward`) / `LoadBalancer` (prod, AWS Classic ELB, auto-provisioned — no AWS Load Balancer Controller) |
| Hostname             | `web.local`, matched through the `Host` header — no Route53, no custom domain |
| Backend              | `web-server` release, Service `web-server-web-server:8080` in the same namespace |
| Packaging            | Helm chart with one dependency, added to the `full-infra` umbrella only after individual validation |

---

## Before You Start — Cluster and Dependency State (optional)

```bash
kubectl get ns full-infra-dev full-infra-prod
# → both namespaces Active

kubectl get pods,svc -n full-infra-dev -l app.kubernetes.io/name=web-server
# → web-server pod Running and Ready, Service web-server-web-server on 8080

kubectl get pods,svc -n full-infra-prod -l app.kubernetes.io/name=web-server
# → same in prod
```

---

## Step 1 — Chart Dependency and Repository

### What was done

`Chart.yaml` declares `traefik/traefik` as a dependency instead of writing Traefik's
Deployment, Service and RBAC from scratch. The upstream repository is added once, then the
dependency is resolved locally before any install.

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update

helm search repo traefik/traefik --versions | head -3
# → confirm 41.5.0 (appVersion v3.7.13) exists in the catalog

cd modules/reverse-proxy/kubernetes/helm/reverse-proxy
helm dependency build
# → Saving 1 charts
# → Deleting outdated charts
```

📄 `modules/reverse-proxy/kubernetes/helm/reverse-proxy/Chart.yaml` — declares the `traefik` dependency
📄 `modules/reverse-proxy/kubernetes/helm/reverse-proxy/charts/` — resolved dependency archive (not committed — add to `.gitignore`)

### Why

Traefik's maintainers publish and version their chart. Rewriting a Deployment, RBAC and
CRD set for Traefik would duplicate maintenance that upstream already does correctly. This
module adds only what upstream does not provide: the TLS Secret, the dashboard Middleware
and the IngressRoute pointing at `web-server`. It is the same "official artefact by
default" posture used in Docker, applied to charts instead of images.

The chart already ships its CRDs (`IngressRoute`, `Middleware` and the rest — 25 in this
version), so the separate `traefik-crds` chart is **not** declared. Declaring both risks
two owners for the same CRDs. Helm installs a chart's CRDs only on first install and skips
existing ones, which is why a second release in another namespace does not conflict.

The version is pinned to the exact value found in the catalog. A range such as `^33.0.0`
would let a later `helm dependency build` pull a different chart silently.

The `charts/` directory is build output, not source — the same category as `node_modules`
or `.terraform/`. It must not be committed; `helm dependency build` regenerates it from
`Chart.yaml`.

### Verification

```bash
cd "$(git rev-parse --show-toplevel)"

ls modules/reverse-proxy/kubernetes/helm/reverse-proxy/charts/
# → traefik-41.5.0.tgz

helm show crds traefik/traefik --version 41.5.0 | grep -c "kind: CustomResourceDefinition"
# → 25
```

`helm lint` is deferred to Step 3, once the values it validates exist.

---

## Step 2 — TLS Certificate and Secret

### What was done

Same self-signed approach as Docker, generated with `openssl`, but loaded into Kubernetes
as a `kubernetes.io/tls` Secret instead of a bind-mounted file, because Traefik's
Kubernetes CRD provider reads TLS material from Secrets. The certificate is issued for the
routing hostname `web.local` and the same certificate is loaded into both namespaces.

```bash
mkdir -p /tmp/reverse-proxy-certs

openssl req -x509 -newkey rsa:4096 -nodes \
  -keyout /tmp/reverse-proxy-certs/lab.key \
  -out /tmp/reverse-proxy-certs/lab.crt \
  -days 365 \
  -subj "/CN=web.local" \
  -addext "subjectAltName=DNS:web.local"

kubectl create secret tls reverse-proxy-tls \
  --cert=/tmp/reverse-proxy-certs/lab.crt \
  --key=/tmp/reverse-proxy-certs/lab.key \
  -n full-infra-dev

kubectl create secret tls reverse-proxy-tls \
  --cert=/tmp/reverse-proxy-certs/lab.crt \
  --key=/tmp/reverse-proxy-certs/lab.key \
  -n full-infra-prod
```

> **Do not commit `/tmp/reverse-proxy-certs/`.** The Secret is created imperatively with
> `kubectl`, not templated in the chart — same principle as never putting credentials in
> `docker-compose.yml`: key material never enters Git.

> **Secrets live and die with the cluster.** A `helm uninstall` does not remove them, but
> destroying the cluster does. On a fresh cluster this step must be repeated before the
> install in Step 6.

📄 `modules/reverse-proxy/kubernetes/helm/reverse-proxy/templates/ingressroute-dashboard.yaml` — references `secretName: reverse-proxy-tls`
📄 `modules/reverse-proxy/kubernetes/helm/reverse-proxy/templates/ingressroute-web-server.yaml` — references the same Secret

### Why

The Secret is created imperatively for the same reason the Docker cert is generated before
`docker compose up`: it is infrastructure state that must exist before the workload starts,
and it must not be reproducible from Git history. Templating a TLS Secret in a chart
committed to a public repository would version the private key — incorrect in any context.

Routing is done by the `Host: web.local` header, not by the ELB's DNS name. The ELB is only
the address the traffic is sent to. That is why the certificate's subject is `web.local`
and never needs to be reissued when the ELB hostname changes between cluster rebuilds.

`cert-manager` would automate issuance and rotation against a real CA, but it is out of
scope here (no extra controllers beyond Traefik). This Secret-based approach is a
lab-appropriate pattern, not a production one — noted so it is not mistaken for a
production TLS strategy.

### Verification

```bash
kubectl get secret reverse-proxy-tls -n full-infra-dev -o jsonpath='{.type}{"\n"}'
# → kubernetes.io/tls

kubectl get secret reverse-proxy-tls -n full-infra-prod -o jsonpath='{.type}{"\n"}'
# → kubernetes.io/tls

openssl x509 -noout -subject -in /tmp/reverse-proxy-certs/lab.crt
# → subject=CN=web.local
```

---

## Step 3 — Values: Exposure, Namespace Scope and Dashboard

### What was done

`values.yaml` holds the baseline shared by both environments: dashboard exposure handled by
this chart's own IngressRoute, Service type `ClusterIP`, and the `reverseProxy` block (routing
hostname, Secret names, backend Service). Port settings are deliberately not overridden.

`values-dev.yaml` and `values-prod.yaml` carry the real environment differences: the
namespace each Traefik instance is allowed to watch, the disabled IngressClass, and — in prod
only — Service type `LoadBalancer`.

📄 `modules/reverse-proxy/kubernetes/helm/reverse-proxy/values.yaml`
📄 `modules/reverse-proxy/kubernetes/helm/reverse-proxy/values-dev.yaml`
📄 `modules/reverse-proxy/kubernetes/helm/reverse-proxy/values-prod.yaml`

### Why

**Ports are left at the chart defaults.** In this chart `port` is the container port (8000
and 8443) and `exposedPort` is the Service port (80 and 443). The chart runs Traefik as
non-root, which cannot bind ports below 1024. Overriding `websecure.port` to 443 would pass
`helm lint` and fail at runtime.

**Each Traefik instance only watches its own namespace.** With one release per environment,
two controllers would otherwise both watch every namespace and both process every
IngressRoute. `providers.kubernetesCRD.namespaces` restricts each instance to its own.

**The IngressClass is disabled.** An `IngressClass` is cluster-scoped. Two releases of the
same chart would try to own the same cluster-wide object, and the second install would fail
with an ownership conflict. This module uses `IngressRoute` CRDs, not `Ingress`, so it does
not need one.

`ClusterIP` in dev keeps validation free of AWS cost: routing is confirmed through
`kubectl port-forward` before anything is exposed. `LoadBalancer` in prod is what provisions
the AWS Classic ELB, automatically, through the in-tree AWS cloud provider — no AWS Load
Balancer Controller is installed. It is the same relaxed-dev, enforced-prod posture as Docker,
applied to the exposure layer.

> **The chart schema is strict.** Unknown keys fail `helm lint` (for example, a `tls` key
> directly under `ports.websecure`). TLS on `websecure` is already enabled by the chart's
> default, so no setting is needed.

### Verification

```bash
cd modules/reverse-proxy/kubernetes/helm/reverse-proxy

helm lint .
# → 1 chart(s) linted, 0 chart(s) failed
# → "icon is recommended" is informational

helm template reverse-proxy . -f values.yaml -f values-dev.yaml | grep -A2 "kind: Service$" | grep "type:"
# → type: ClusterIP

helm template reverse-proxy . -f values.yaml -f values-prod.yaml | grep -A2 "kind: Service$" | grep "type:"
# → type: LoadBalancer

helm template reverse-proxy . -f values.yaml -f values-dev.yaml | grep -i "kubernetescrd.namespaces"
# → --providers.kubernetescrd.namespaces=full-infra-dev

helm template reverse-proxy . -f values.yaml -f values-prod.yaml | grep -i "kubernetescrd.namespaces"
# → --providers.kubernetescrd.namespaces=full-infra-prod

helm template reverse-proxy . -f values.yaml -f values-dev.yaml | grep -c "kind: IngressClass"
# → 0
```

---

## Step 4 — Dashboard Credentials, Middleware and IngressRoute

### What was done

The BasicAuth credentials are generated with `htpasswd` (same tool as Docker) and stored in a
Kubernetes Secret named `reverse-proxy-dashboard-auth`, in **each** namespace. The
`Middleware` object does not contain the hash — it only references that Secret. An
`IngressRoute` exposes the dashboard on the `websecure` entrypoint, protected by the
Middleware and served with the TLS Secret from Step 2.

```bash
HASH=$(htpasswd -nB admin)
# → prompts for the password; HASH now holds admin:$2y$05$...

kubectl create secret generic reverse-proxy-dashboard-auth \
  --from-literal=users="$HASH" \
  -n full-infra-dev

kubectl create secret generic reverse-proxy-dashboard-auth \
  --from-literal=users="$HASH" \
  -n full-infra-prod

unset HASH
```

> **The Secret key must be named `users`.** It is the key Traefik's `basicAuth.secret`
> reads in the Kubernetes CRD provider.

> **The Secret must exist before the install in Step 6.** The Middleware references it by
> name; without it the dashboard router cannot authenticate anyone.

📄 `modules/reverse-proxy/kubernetes/helm/reverse-proxy/templates/middleware-basicauth.yaml`
📄 `modules/reverse-proxy/kubernetes/helm/reverse-proxy/templates/ingressroute-dashboard.yaml`

### Why

This reproduces the dashboard step of the Docker doc, changing only the mechanism: a
`dynamic.yml` middleware block becomes a `Middleware` object, and the label-based router
becomes an `IngressRoute`. The relationship — the router matches the host, the middleware
challenges for credentials, only success reaches the backend — is unchanged.

The hash lives in a Secret and never in `values.yaml` or a template, for the same reason as
the TLS key: chart manifests are committed to a public repository, and a hash in Git defeats
the point of hashing. Bcrypt (`-B`) is the production-correct choice regardless of
environment.

The dashboard router matches `Host(web.local)` **and** `PathPrefix(/dashboard)`. A request
without the matching `Host` header matches no router and returns a Traefik 404, not a 401.

### Verification

Runtime checks (Middleware, IngressRoute, HTTP codes) need the release from Step 6. Here
only the rendered manifests and the Secret are verified.

```bash
cd modules/reverse-proxy/kubernetes/helm/reverse-proxy

helm template reverse-proxy . -f values.yaml -f values-dev.yaml | grep -A6 "kind: Middleware"
# → name: reverse-proxy-auth-dashboard
# → secret: reverse-proxy-dashboard-auth

kubectl get secret reverse-proxy-dashboard-auth -n full-infra-dev \
  -o jsonpath='{.data.users}' | base64 -d | cut -d: -f1
# → admin

kubectl get secret reverse-proxy-dashboard-auth -n full-infra-prod \
  -o jsonpath='{.data.users}' | base64 -d | cut -d: -f1
# → admin
```

---

## Step 5 — Backend Routing to web-server

### What was done

An `IngressRoute` matches `Host(web.local)` on the `websecure` entrypoint and forwards to the
`web-server` Service in the same namespace, on port 8080. The full Service name comes from
`reverseProxy.backendServiceName` in `values.yaml` (`web-server-web-server`) and is used
as-is by the template.

📄 `modules/reverse-proxy/kubernetes/helm/reverse-proxy/templates/ingressroute-web-server.yaml`
📄 `modules/reverse-proxy/kubernetes/helm/reverse-proxy/values.yaml` — `reverseProxy.backendServiceName`

### Why

This step makes the dependency on `web-server` concrete: `services[].name` must match the
exact Service the `web-server` chart produces. That name is `<release>-web-server` where the
release is **`web-server`'s** release, not this chart's. Building the name from
`.Release.Name` here would resolve to `reverse-proxy-web-server` and never match — the
release name convention (release = module name) is what makes `web-server-web-server`
predictable.

A wrong Service name does not fail at deploy time. The IngressRoute applies cleanly, Traefik
drops the router, and the only symptom is a 404 at request time. The Traefik log shows the
cause.

> **A 404 with a 19-byte body (`404 page not found`) means no router matched.** Check, in
> order: the `Host: web.local` header is present; the backend Service name exists in that
> namespace; and `kubectl logs deploy/reverse-proxy-traefik | grep ERR` — a line such as
> `kubernetes service not found: <namespace>/<name>` names the exact mismatch.

### Verification

```bash
cd modules/reverse-proxy/kubernetes/helm/reverse-proxy

helm template reverse-proxy . -f values.yaml -f values-dev.yaml | grep -B1 -A2 "port: 8080"
# → name: web-server-web-server

kubectl get svc web-server-web-server -n full-infra-dev
# → ClusterIP, 8080/TCP

kubectl get svc web-server-web-server -n full-infra-prod
# → ClusterIP, 8080/TCP
```

---

## Step 6 — Deploy and Verify (dev)

### What was done

First install in `full-infra-dev`, with the Service kept at `ClusterIP` and access through
`kubectl port-forward` — no AWS cost. Before installing, the two Secrets and the
`web-server` release must already exist.

```bash
kubectl get secret reverse-proxy-tls reverse-proxy-dashboard-auth -n full-infra-dev
# → both listed

cd modules/reverse-proxy/kubernetes/helm/reverse-proxy

helm install reverse-proxy . -n full-infra-dev \
  -f values.yaml -f values-dev.yaml
```

In a **separate terminal**, keep the port-forward running:

```bash
kubectl port-forward -n full-infra-dev svc/reverse-proxy-traefik 8443:443
```

> **`helm install` only works the first time.** If the release name is already in use
> (`cannot reuse a name that is still in use`), list it with `helm list -a -n full-infra-dev`
> — `-a` also shows failed releases, which still hold the name. Apply changes with
> `helm upgrade reverse-proxy . -n full-infra-dev -f values.yaml -f values-dev.yaml`, or run
> `helm uninstall` and install again.

> **`address already in use` on 8443** means an earlier port-forward is still running.
> Find it with `lsof -nP -iTCP:8443 -sTCP:LISTEN` and stop it with `kill <PID>` using the
> PID it prints, or use another local port (`8444:443`) and adjust the `curl` commands.

📄 `modules/reverse-proxy/kubernetes/helm/reverse-proxy/` — full chart, dependency resolved in Step 1

### Why

Validating in dev with `ClusterIP` and a port-forward confirms the whole chain — TLS,
Middleware, IngressRoute, backend — before creating a `LoadBalancer` Service. It is the same
"manual before automated, cheap before expensive" posture used for the EKS foundation.

The port-forward targets the Service, so it binds to one pod at connection time. After a
`helm upgrade` replaces the pod, restart the port-forward.

Traefik prints several `WRN` lines at startup (`aliasHeadersStrategy`, `SafeNaming`, data
collection). They are informational, not errors; they are hardening candidates that stay out
of scope for this module.

### Verification

```bash
helm list -n full-infra-dev
# → reverse-proxy   deployed

kubectl get pods -n full-infra-dev -l app.kubernetes.io/name=traefik
# → 1/1 Running

kubectl get crd ingressroutes.traefik.io middlewares.traefik.io
# → both listed

kubectl get ingressroute,middleware -n full-infra-dev
# → reverse-proxy-dashboard, reverse-proxy-web-server, reverse-proxy-auth-dashboard

kubectl logs -n full-infra-dev deploy/reverse-proxy-traefik | grep ERR
# → (no output)

curl -sk -o /dev/null -w "%{http_code}\n" -H "Host: web.local" https://localhost:8443/
# → 200

curl -sk -o /dev/null -w "%{http_code}\n" -H "Host: web.local" https://localhost:8443/dashboard/
# → 401

read -rs PW
curl -sk -o /dev/null -w "%{http_code}\n" -H "Host: web.local" -u "admin:$PW" https://localhost:8443/dashboard/
# → 200

curl -sk -o /dev/null -w "%{http_code}\n" -H "Host: web.local" -u "admin:wrong" https://localhost:8443/dashboard/
# → 401
unset PW
```

---

## Production deployment

In production the release is installed with `values-prod.yaml`, switching the Service type to
`LoadBalancer`. This is the point where a real AWS Classic ELB is provisioned.

```bash
cd modules/reverse-proxy/kubernetes/helm/reverse-proxy

helm install reverse-proxy . -n full-infra-prod \
  -f values.yaml -f values-prod.yaml
```

Read the ELB hostname from the Service and keep it in a variable:

```bash
kubectl get svc -n full-infra-prod reverse-proxy-traefik
# → TYPE LoadBalancer, EXTERNAL-IP <pending> and then a hostname

ELB=$(kubectl get svc -n full-infra-prod reverse-proxy-traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "$ELB"
```

> **A new ELB needs one to three minutes** before its DNS name resolves and its nodes are
> registered. `curl` printing `000` means no HTTP response yet, not a wrong address. Check
> resolution with `nslookup "$ELB"` and node registration with:
>
> ```bash
> REGION=eu-west-1
> aws elb describe-instance-health --load-balancer-name "${ELB%%-*}" --region "$REGION"
> # → State: InService (OutOfService with "registration in progress" is transient)
> ```

> **Teardown order — do not destroy the cluster before this Service.** The ELB is created by
> the AWS cloud provider as a side effect of this `Service`, not by Terraform. It does not
> live in Terraform state and `terraform destroy` does not remove it. Deleting the cluster
> first leaves an orphaned, billable ELB in the VPC and can block deletion of dependent
> network resources.

📄 `modules/reverse-proxy/kubernetes/helm/reverse-proxy/values-prod.yaml`

### Verification

```bash
curl -sk -o /dev/null -w "%{http_code}\n" -H "Host: web.local" "https://$ELB/"
# → 200

curl -sk -o /dev/null -w "%{http_code}\n" -H "Host: web.local" "https://$ELB/dashboard/"
# → 401

read -rs PW
curl -sk -o /dev/null -w "%{http_code}\n" -H "Host: web.local" -u "admin:$PW" "https://$ELB/dashboard/"
# → 200
unset PW

kubectl logs -n full-infra-prod deploy/reverse-proxy-traefik | grep ERR
# → (no output)
```

### Teardown

```bash
# Step 1 — remove the releases; deleting the prod Service deletes the ELB
helm uninstall reverse-proxy -n full-infra-dev
helm uninstall reverse-proxy -n full-infra-prod

# Step 2 — wait until the ELB is gone

REGION=eu-west-1

aws elb describe-load-balancers --region "$REGION" \
  --query 'LoadBalancerDescriptions[*].LoadBalancerName' --output text
# → must not list the ELB whose name is the prefix of the hostname in $ELB

# Step 3 — only now is it safe to run terraform destroy on the EKS foundation
```

`helm uninstall` removes neither the Secrets nor the CRDs. Both disappear with the cluster,
so a rebuilt cluster needs Steps 2 and 4 repeated before the next install.

---
