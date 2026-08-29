# Kubernetes Environment Setup — Prod

The infrastructure this environment runs on — VPC, IAM roles, EKS control plane, managed node group, security groups, and the `full-infra-prod` namespace itself — is created once in
[`environments/kubernetes/dev/setup.md`](../dev/setup.md). This document does not repeat those steps. It documents only the delta that makes `full-infra-prod` behave like a production environment inside the same shared cluster.

> This mirrors the `## Production deployment` pattern already used across
> this repo's module docs (`web-server.md`, `dns.md`, etc.): one canonical
> document for the shared implementation, and a delta block for what
> changes in production — never a duplicated copy of the same steps.

## Prerequisite

Complete every step in `environments/kubernetes/dev/setup.md` first. The `full-infra-prod` namespace must already exist before continuing.

```bash
kubectl get namespace full-infra-prod
# → STATUS Active
```

---

## Step 1 — Resource quota

### What was done

Applied a `ResourceQuota` to `full-infra-prod`, capping the total CPU,
memory, and object count that namespace can consume across the shared
node group.

📄 [`environments/kubernetes/prod/resource-quota.yaml`](resource-quota.yaml)

```bash
kubectl apply -f resource-quota.yaml
```

### Why

`full-infra-dev` has no quota — it needs the flexibility to iterate without hitting an artificial ceiling while you're still learning the platform. `full-infra-prod` gets an explicit quota because both namespaces share the same 2-node pool: without a cap, a runaway dev workload could starve production pods of schedulable capacity. This is the direct Kubernetes equivalent of the `restart: unless-stopped` and healthcheck enforcement already applied to `docker-compose.prod.yml` — production gets guardrails that development intentionally skips for iteration speed.

`ResourceQuota` is a namespace-scoped object: it doesn't limit any single pod, only the namespace's total footprint. Pod-level ceilings are set with `LimitRange`, in the next step.

### Verification

```bash
kubectl describe resourcequota full-infra-prod-quota -n full-infra-prod
# → Used column populated once workloads are deployed in later phases
```

---

## Step 2 — Limit range

### What was done

Applied a `LimitRange` to `full-infra-prod` so every pod gets an explicit default request/limit even if a manifest omits them.

📄 [`environments/kubernetes/prod/limit-range.yaml`](limit-range.yaml)

```bash
kubectl apply -f limit-range.yaml
```

### Why

Without a `LimitRange`, a container with no resources block defined is
scheduled with no request at all, which defeats the point of having a
quota. In `full-infra-dev` this is acceptable — you want to see a pod fail loudly if it's genuinely misconfigured, so you learn to write correct manifests. In `full-infra-prod`, silent under-provisioning is a bigger risk than a slightly conservative default, so every container gets a safe baseline whether or not its manifest sets one explicitly.

### Verification

```bash
kubectl describe limitrange full-infra-prod-limits -n full-infra-prod
```

---

## Step 3 — RBAC

### What was done

Created a `Role` and `RoleBinding` scoped to `full-infra-prod`, granting read-only access by default instead of the full access implicitly available in `full-infra-dev`.

📄 [`environments/kubernetes/prod/rbac-prod-viewer.yaml`](rbac-prod-viewer.yaml)

```bash
aws sts get-caller-identity --query Arn --output text
# → arn:aws:iam::<account-id>:user/your-user

kubectl apply -f rbac-prod-viewer.yaml
```

> This is a lab-scope RBAC pattern: one role, one binding, read-only by
> default. It is correct for a single-operator lab. It is not sufficient
> for a real multi-team production cluster, where you'd define distinct
> roles per team and per responsibility (deploy vs. view vs. debug). That
> level of RBAC design is explicitly out of scope for this milestone.

### Why

`full-infra-dev` relies on your own IAM principal having implicit
cluster-admin access via the EKS access entry created in Step 4 of
`dev/setup.md` — appropriate for a namespace you're actively iterating in.
`full-infra-prod` gets an explicit, narrower `Role`: by default you can
observe it, not silently mutate it, which forces any change to production to be a deliberate `kubectl apply` against a specific manifest rather than an ad hoc `kubectl edit` or `kubectl delete`. This is the same discipline already applied to the Docker prod host, where changes are made via tracked Compose files, not manual container edits.

### Verification

```bash
kubectl auth can-i delete deployments -n full-infra-prod --as=<your-iam-principal-arn>
# → no
kubectl auth can-i get pods -n full-infra-prod --as=<your-iam-principal-arn>
# → yes
```

---

## Teardown

No separate teardown is needed here: deleting the `full-infra-prod`
namespace during the cluster-wide teardown in `dev/setup.md` Step 9
removes the `ResourceQuota`, `LimitRange`, `Role`, and `RoleBinding`
created in this document automatically, since all four are namespace-scoped objects with no resources outside it.
