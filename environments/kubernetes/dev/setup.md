# Kubernetes Environment Setup — Dev

This document provisions the shared Kubernetes foundation for this lab: a
single Amazon EKS cluster used by both logical environments, `full-infra-dev`
and `full-infra-prod`, separated by namespace rather than by separate
infrastructure.

> Unlike the Docker runtime — where `dev` (local Docker Engine) and `prod`
> (EC2 Docker Engine) are two independent hosts, each with its own complete
> setup doc — Kubernetes `dev` and `prod` share one cluster. This document is
> the only place the infrastructure is created. `environments/kubernetes/prod/setup.md`
> does not repeat these steps; it documents only the namespace-level delta
> (ResourceQuota, LimitRange, RBAC) that makes `full-infra-prod` behave like
> production inside the same cluster.

All resources in this document are created manually via AWS CLI, one
resource at a time, before any Terraform is written. This mirrors the
Docker automation pattern: manual first, automation only after the manual
process is fully understood and validated.

## Step 0 — Environment variables

### What was done

Defined the values that every subsequent AWS CLI command in this document
depends on, so no command below hardcodes a name, region, or CIDR block
inline.

```bash
export AWS_REGION=eu-west-1
export CLUSTER_NAME=full-infra
export VPC_CIDR=10.0.0.0/16
export SUBNET_PUB_A_CIDR=10.0.0.0/24
export SUBNET_PUB_B_CIDR=10.0.1.0/24
export SUBNET_PRIV_A_CIDR=10.0.10.0/24
export SUBNET_PRIV_B_CIDR=10.0.11.0/24
export AZ_A=${AWS_REGION}a
export AZ_B=${AWS_REGION}b
```

### Why

| Variable | Value | Reasoning |
|---|---|---|
| `AWS_REGION` | `eu-west-1` (adjust to your target region) | Every resource below is region-scoped; setting it once avoids a mismatched `--region` flag on a later command |
| `CLUSTER_NAME` | `full-infra` | One name reused as a prefix for every resource (`full-infra-vpc`, `full-infra-cluster-role`, etc.) so resources are identifiable and grep-able later during teardown |
| `VPC_CIDR` | `10.0.0.0/16` | Gives 65,536 addresses — far more than this lab needs, but a `/16` is the conventional starting block for a VPC so subnets below can be carved out without recalculating later |
| `SUBNET_PUB_A_CIDR` / `SUBNET_PUB_B_CIDR` | `10.0.0.0/24`, `10.0.1.0/24` | Public subnets host NAT Gateways only, one per AZ; a `/24` (256 addresses) is oversized for that but keeps subnet math simple and consistent across the pair |
| `SUBNET_PRIV_A_CIDR` / `SUBNET_PRIV_B_CIDR` | `10.0.10.0/24`, `10.0.11.0/24` | Private subnets host the worker nodes; the `.10`/`.11` offset (instead of `.2`/`.3`) leaves room to add more public subnets later without colliding with the private range |
| `AZ_A` / `AZ_B` | `${AWS_REGION}a`, `${AWS_REGION}b` | Two distinct AZs are the actual mechanism that gives this cluster real HA — the CIDR split above only matters because each pair maps to one of these two zones |

> The AZ suffixes `a`/`b` are not guaranteed to exist or be the first two
> zones in every region. Confirm before exporting:
> `aws ec2 describe-availability-zones --region $AWS_REGION --query 'AvailabilityZones[].ZoneName'`

### Verification

```bash
echo $AWS_REGION $CLUSTER_NAME $VPC_CIDR $AZ_A $AZ_B
# → all six values print, none empty
```

---

## Step 1 — VPC and subnets

### What was done

Created one VPC with two public subnets and two private subnets, spread
across two Availability Zones.

```bash
# Creates the VPC that contains every other network resource in this document
VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$CLUSTER_NAME-vpc}]" \
  --query 'Vpc.VpcId' --output text)

# Allows resources inside the VPC to resolve each other and AWS service endpoints by DNS name
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
# Required for EKS nodes and pods to resolve internal AWS service hostnames (e.g. the EKS API endpoint)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames

# Public subnet in AZ A — will host the NAT Gateway for that zone
SUBNET_PUB_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_PUB_A_CIDR \
  --availability-zone $AZ_A \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$CLUSTER_NAME-pub-a}]" \
  --query 'Subnet.SubnetId' --output text)

# Public subnet in AZ B — mirrors SUBNET_PUB_A for the second zone
SUBNET_PUB_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_PUB_B_CIDR \
  --availability-zone $AZ_B \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$CLUSTER_NAME-pub-b}]" \
  --query 'Subnet.SubnetId' --output text)

# Private subnet in AZ A — will host one EKS worker node
SUBNET_PRIV_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_PRIV_A_CIDR \
  --availability-zone $AZ_A \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$CLUSTER_NAME-priv-a}]" \
  --query 'Subnet.SubnetId' --output text)

# Private subnet in AZ B — will host the second EKS worker node
SUBNET_PRIV_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_PRIV_B_CIDR \
  --availability-zone $AZ_B \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$CLUSTER_NAME-priv-b}]" \
  --query 'Subnet.SubnetId' --output text)
```

### Why

Two Availability Zones is the minimum needed to demonstrate real high
availability — one node per AZ, not a simulated single-AZ setup. Public
subnets host NAT Gateways and any future internet-facing load balancer.
Private subnets host the worker nodes: this is the "correct for
production" pattern — workloads never receive a public IP directly, and
outbound internet access goes through NAT. Placing nodes in public subnets
would be a lab-only shortcut, and you've explicitly chosen to build the
production-correct pattern here.

### Verification

```bash
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{Id:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}' --output table

# → 4 rows: 2 public (AZ_A/AZ_B), 2 private (AZ_A/AZ_B)
```

---

## Step 2 — Internet Gateway, NAT Gateways and route tables

### What was done

Attached an Internet Gateway to the VPC, created one NAT Gateway per public
subnet (one per AZ), and configured route tables so private subnets route
outbound traffic through the NAT Gateway in their own AZ.

```bash
# Creates the Internet Gateway that gives the public subnets a route to the internet
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$CLUSTER_NAME-igw}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)

# Attaches the Internet Gateway to the VPC — without this, the IGW exists but routes nowhere
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID

# Route table that will be shared by both public subnets
RT_PUB=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$CLUSTER_NAME-rt-public}]" \
  --query 'RouteTable.RouteTableId' --output text)

# Sends all outbound traffic from public subnets to the Internet Gateway
aws ec2 create-route --route-table-id $RT_PUB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID

# Applies the public route table to subnet A
aws ec2 associate-route-table --route-table-id $RT_PUB --subnet-id $SUBNET_PUB_A
# Applies the public route table to subnet B
aws ec2 associate-route-table --route-table-id $RT_PUB --subnet-id $SUBNET_PUB_B

# Elastic IP that NAT Gateway A will use as its fixed outbound address
EIP_A=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
# Elastic IP that NAT Gateway B will use as its fixed outbound address
EIP_B=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)

# NAT Gateway for AZ A, placed in the public subnet so it can reach the Internet Gateway
NAT_A=$(aws ec2 create-nat-gateway --subnet-id $SUBNET_PUB_A --allocation-id $EIP_A \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=$CLUSTER_NAME-nat-a}]" \
  --query 'NatGateway.NatGatewayId' --output text)

# NAT Gateway for AZ B — keeps AZ B's outbound traffic independent from AZ A's
NAT_B=$(aws ec2 create-nat-gateway --subnet-id $SUBNET_PUB_B --allocation-id $EIP_B \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=$CLUSTER_NAME-nat-b}]" \
  --query 'NatGateway.NatGatewayId' --output text)

# Blocks until both NAT Gateways report State=available before routes are created against them
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_A $NAT_B

# Private route table for AZ A only — each AZ gets its own to route through its own NAT Gateway
RT_PRIV_A=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$CLUSTER_NAME-rt-private-a}]" \
  --query 'RouteTable.RouteTableId' --output text)

# Sends AZ A's outbound traffic through AZ A's own NAT Gateway
aws ec2 create-route --route-table-id $RT_PRIV_A --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_A
# Applies this route table to the private subnet in AZ A
aws ec2 associate-route-table --route-table-id $RT_PRIV_A --subnet-id $SUBNET_PRIV_A

# Private route table for AZ B — mirrors RT_PRIV_A for the second zone
RT_PRIV_B=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$CLUSTER_NAME-rt-private-b}]" \
  --query 'RouteTable.RouteTableId' --output text)
# Sends AZ B's outbound traffic through AZ B's own NAT Gateway
aws ec2 create-route --route-table-id $RT_PRIV_B --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_B
# Applies this route table to the private subnet in AZ B
aws ec2 associate-route-table --route-table-id $RT_PRIV_B --subnet-id $SUBNET_PRIV_B
```

### Why

One NAT Gateway per AZ avoids a single point of failure: if a NAT Gateway
in AZ A goes down, nodes in AZ B keep outbound connectivity. A single
shared NAT Gateway is cheaper but reintroduces the single-AZ risk you're
explicitly avoiding by running 2 nodes across 2 AZs. This costs roughly
$0.045/hour extra for the second NAT Gateway — negligible for a lab you
destroy after validation, and it is the pattern you'd defend as correct in
a real production review.

### Verification

```bash
aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" \
  --query 'NatGateways[].{Id:NatGatewayId,State:State,Subnet:SubnetId}' --output table

# → 2 rows, State: available
```

---

## Step 3 — IAM roles

### What was done

Created two IAM roles: one for the EKS cluster control plane, one for the
managed node group.

```bash
# IAM role that the EKS control plane assumes to manage the cluster on your behalf

CLUSTER_ROLE_ARN=$(aws iam create-role --role-name ${CLUSTER_NAME}-cluster-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Principal": {"Service": "eks.amazonaws.com"}, "Action": "sts:AssumeRole"}]
  }' --query 'Role.Arn' --output text)

# Grants the cluster role the permissions EKS needs to operate the control plane
aws iam attach-role-policy --role-name ${CLUSTER_NAME}-cluster-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

# IAM role that EC2 worker nodes assume to join the cluster
NODE_ROLE_ARN=$(aws iam create-role --role-name ${CLUSTER_NAME}-node-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}]
  }' --query 'Role.Arn' --output text)

# Lets nodes register with the cluster and report their status
aws iam attach-role-policy --role-name ${CLUSTER_NAME}-node-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy

# Lets the CNI plugin assign pod IP addresses from the VPC
aws iam attach-role-policy --role-name ${CLUSTER_NAME}-node-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy

# Lets nodes pull container images from ECR
aws iam attach-role-policy --role-name ${CLUSTER_NAME}-node-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
```

### Why

EKS separates control-plane permissions from node permissions by design:
the cluster role lets AWS manage the control plane on your behalf: the
node role lets EC2 instances join the cluster, use the CNI plugin for pod
networking, and pull container images. This is the same separation of
concerns as Terraform owning infrastructure and Compose owning services in
the Docker runtime — one identity per responsibility, nothing shared.

### Verification

```bash
aws iam get-role --role-name ${CLUSTER_NAME}-cluster-role --query 'Role.Arn' --output text
aws iam get-role --role-name ${CLUSTER_NAME}-node-role --query 'Role.Arn' --output text
# → both return a valid ARN
```

---

## Step 4 — EKS cluster (control plane)

### What was done

Created the EKS control plane across the two private subnets, with no
node group attached yet.

```bash
# Creates the EKS control plane across both private subnets, with no compute attached yet
aws eks create-cluster \
  --name $CLUSTER_NAME \
  --role-arn $CLUSTER_ROLE_ARN \
  --kubernetes-version 1.36 \
  --resources-vpc-config subnetIds=$SUBNET_PRIV_A,$SUBNET_PRIV_B

# Blocks until the control plane reports status ACTIVE
aws eks wait cluster-active --name $CLUSTER_NAME
```

> Check the latest EKS-supported Kubernetes version at execution time —
> `aws eks describe-addon-versions` or the AWS console — and pin it
> explicitly with `--kubernetes-version` if you want to avoid picking up
> an unplanned version bump.

### Why

The control plane is provisioned before any compute exists — this is
intentional and mirrors real EKS behavior: AWS manages the control plane
(API server, etcd, scheduler) as a managed service, billed at a flat
$0.10/hour regardless of workload. Only after this is `ACTIVE` does it
make sense to attach compute, because the node group needs a live cluster
endpoint to register against.

### Verification

```bash
aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.status' --output text
# → ACTIVE
```

---

## Step 5 — kubectl access

### What was done

Generated the local kubeconfig entry for this cluster.

```bash
# Writes a kubeconfig entry that authenticates kubectl against this cluster via your AWS session
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION

# Confirms the API server is reachable with the newly written context
kubectl cluster-info
```

### Why

`aws eks update-kubeconfig` writes a context that shells out to the AWS
CLI for authentication — there is no static credential stored, so access
is only as good as your current AWS session. This is the Kubernetes
equivalent of SSH-ing into the EC2 Docker host: before this step you can
create AWS resources, but you can't yet talk to Kubernetes itself.

### Verification

```bash
kubectl get svc
# → kubernetes ClusterIP service listed, confirming API server reachability
```

---

## Step 6 — Managed Node Group

### What was done

Attached a managed node group of 2 ARM64 (Graviton) nodes, one per private
subnet, to keep the two Availability Zones balanced.

```bash
# Attaches a managed node group of 2 ARM64 nodes, one per private subnet/AZ
aws eks create-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name ${CLUSTER_NAME}-nodes \
  --node-role $NODE_ROLE_ARN \
  --subnets $SUBNET_PRIV_A $SUBNET_PRIV_B \
  --instance-types t4g.medium \
  --ami-type AL2_ARM_64 \
  --scaling-config minSize=2,maxSize=2,desiredSize=2

# Blocks until both nodes have joined the cluster and report status ACTIVE
aws eks wait nodegroup-active --cluster-name $CLUSTER_NAME --nodegroup-name ${CLUSTER_NAME}-nodes
```

### Why

ARM64 (`t4g.medium`, Graviton) keeps this cluster architecture-consistent
with the rest of the repo, which already targets ARM64 for the EC2 Docker
host. `t4g.medium` (4 GiB RAM) is used instead of `t4g.small` (2 GiB)
because the EKS-optimized AMI, kube-proxy, CNI, and other system pods
already consume a meaningful share of a small node's memory before any lab
workload runs — `t4g.small` risks pods stuck in `Pending` due to
insufficient allocatable memory. `minSize=maxSize=desiredSize=2` keeps the
node count fixed and predictable for a lab: no autoscaling behavior to
reason about yet, and no unplanned cost from unexpected scale-out.

### Verification

```bash
kubectl get nodes -o wide
# → 2 nodes, STATUS Ready, one per AZ (check the AZ label to confirm distribution)
kubectl get nodes -L topology.kubernetes.io/zone
```

---

## Step 7 — Security groups

### What was done

Reviewed the cluster security group that EKS creates automatically for
control-plane-to-node communication. No additional custom security group
was created at this stage.

```bash
# Retrieves the security group ID that EKS created and attached automatically to every node
aws eks describe-cluster --name $CLUSTER_NAME \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text
```

### Why

EKS Managed Node Groups automatically attach the cluster security group to
every node, with the correct rules for node-to-control-plane and
control-plane-to-node traffic already in place — this is different from
Docker Compose, where you write every port mapping explicitly. Writing a
custom security group here without a concrete requirement would be
premature: it's the kind of unjustified complexity this project avoids.
Service-specific ingress rules (HTTP/HTTPS, DNS, SFTP) are deferred to
their own migration phases, once there's a real Service or Ingress
resource that needs them.

### Verification

```bash
CLUSTER_SG_ID=$(aws eks describe-cluster --name $CLUSTER_NAME \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

aws ec2 describe-security-groups --group-ids $CLUSTER_SG_ID \
  --query 'SecurityGroups[0].{Inbound:IpPermissions,Outbound:IpPermissionsEgress}'

# → rules scoped to the security group itself (node-to-control-plane), no 0.0.0.0/0 inbound
```

---

## Step 8 — Namespaces

### What was done

Created the three namespaces that separate this cluster logically: two
application environments and one system namespace for the future ingress
controller.

```bash
# Namespace for the development-facing logical environment
kubectl create namespace full-infra-dev

# Namespace for the production-facing logical environment
kubectl create namespace full-infra-prod

# Namespace reserved for the future shared ingress controller (Traefik)
kubectl create namespace ingress-system
```

### Why

This is the point where "dev" and "prod" stop being infrastructure
decisions and become Kubernetes-native isolation: a namespace scopes
Deployments, Services, Secrets, and RBAC without needing a second cluster.
`ingress-system` is separate from both because the ingress controller
(Traefik, in a later phase) is shared platform infrastructure, not part of
either application environment — the same reasoning that kept
`reverse-proxy` as an independent module in the Docker runtime.

### Verification

```bash
kubectl get namespaces
# → full-infra-dev, full-infra-prod, ingress-system all present, STATUS Active
```

---

## Step 9 — Manual teardown

### What was done

Destroyed every resource created in this document, in reverse dependency
order, and verified nothing billable remained.

```bash
# Removes the worker nodes first — the cluster must have no attached compute before it can be deleted
aws eks delete-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name ${CLUSTER_NAME}-nodes
aws eks wait nodegroup-deleted --cluster-name $CLUSTER_NAME --nodegroup-name ${CLUSTER_NAME}-nodes

# Removes the control plane once no node group depends on it
aws eks delete-cluster --name $CLUSTER_NAME
aws eks wait cluster-deleted --name $CLUSTER_NAME

# Removes both NAT Gateways — must happen before their subnets or EIPs can be released
aws ec2 delete-nat-gateway --nat-gateway-id $NAT_A
aws ec2 delete-nat-gateway --nat-gateway-id $NAT_B
aws ec2 wait nat-gateway-deleted --nat-gateway-ids $NAT_A $NAT_B

# Releases both Elastic IPs — NAT Gateway deletion does not release them automatically
aws ec2 release-address --allocation-id $EIP_A
aws ec2 release-address --allocation-id $EIP_B

# Retrieves the 4 route table associations created in this document, to disassociate them before deletion
ASSOC_IDS=$(aws ec2 describe-route-tables \
  --route-table-ids $RT_PUB $RT_PRIV_A $RT_PRIV_B \
  --query 'RouteTables[].Associations[?Main==`false`].RouteTableAssociationId' \
  --output text)

# Disassociates each route table from its subnet before the route table itself can be deleted
for ASSOC_ID in $ASSOC_IDS; do
  aws ec2 disassociate-route-table --association-id $ASSOC_ID
done

# Deletes the public route table
aws ec2 delete-route-table --route-table-id $RT_PUB
# Deletes the private route table for AZ A
aws ec2 delete-route-table --route-table-id $RT_PRIV_A
# Deletes the private route table for AZ B
aws ec2 delete-route-table --route-table-id $RT_PRIV_B


# Detaches the Internet Gateway from the VPC before it can be deleted
aws ec2 detach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID

# Deletes all four subnets now that nothing references them
aws ec2 delete-subnet --subnet-id $SUBNET_PUB_A
aws ec2 delete-subnet --subnet-id $SUBNET_PUB_B
aws ec2 delete-subnet --subnet-id $SUBNET_PRIV_A
aws ec2 delete-subnet --subnet-id $SUBNET_PRIV_B

# Deletes the VPC itself — the last networking resource, once it has no dependents left
aws ec2 delete-vpc --vpc-id $VPC_ID

# Detaches the policy from and deletes the cluster IAM role
aws iam detach-role-policy --role-name ${CLUSTER_NAME}-cluster-role --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
aws iam delete-role --role-name ${CLUSTER_NAME}-cluster-role

# Detaches all three policies from and deletes the node IAM role
aws iam detach-role-policy --role-name ${CLUSTER_NAME}-node-role --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
aws iam detach-role-policy --role-name ${CLUSTER_NAME}-node-role --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
aws iam detach-role-policy --role-name ${CLUSTER_NAME}-node-role --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
aws iam delete-role --role-name ${CLUSTER_NAME}-node-role
```

### Why

The node group and cluster must be deleted before the VPC, subnets, NAT
Gateways, and Internet Gateway — AWS refuses to delete networking
resources that still have dependent ENIs from EKS. Elastic IPs are
released explicitly because NAT Gateway deletion does not release its
associated EIP automatically, and an unreleased EIP keeps billing per
hour. This full teardown is run once the manual foundation is validated
and documented, and again after the Terraform-automated version (Step 7 of
the roadmap) is validated — the same "create, verify, destroy" discipline
used throughout this lab.

### Verification

```bash
# Confirms no EKS cluster remains
aws eks list-clusters --query 'clusters'
# → []

# Confirms the VPC itself is gone
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$CLUSTER_NAME-vpc" --query 'Vpcs'
# → []

# Confirms no orphaned Elastic IPs remain (NAT Gateway deletion doesn't release them automatically)
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null]'
# → []

# Confirms no NAT Gateways remain (some AWS accounts show deleted ones as "deleted" state briefly)
aws ec2 describe-nat-gateways --filter "Name=tag:Name,Values=$CLUSTER_NAME-nat-a,$CLUSTER_NAME-nat-b" \
  --query 'NatGateways[?State!=`deleted`]'
# → []

# Confirms no subnets tagged for this cluster remain
aws ec2 describe-subnets --filters "Name=tag:Name,Values=$CLUSTER_NAME-*" --query 'Subnets'
# → []

# Confirms no route tables tagged for this cluster remain
aws ec2 describe-route-tables --filters "Name=tag:Name,Values=$CLUSTER_NAME-*" --query 'RouteTables'
# → []

# Confirms no Internet Gateway tagged for this cluster remains
aws ec2 describe-internet-gateways --filters "Name=tag:Name,Values=$CLUSTER_NAME-igw" --query 'InternetGateways'
# → []

# Confirms both IAM roles are gone
aws iam get-role --role-name ${CLUSTER_NAME}-cluster-role >/dev/null 2>&1 \
  && echo "cluster-role: STILL EXISTS" || echo "cluster-role: gone"

aws iam get-role --role-name ${CLUSTER_NAME}-node-role >/dev/null 2>&1 \
  && echo "node-role: STILL EXISTS" || echo "node-role: gone"

# → both print "gone"
```
