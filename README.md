# fraud-infra — Phase 0 Implementation Guide

Terraform for the AWS layer of the **Real-Time Fraud Detection Platform with
Self-Healing MLOps**. This repo provisions AWS resources only. Everything that
runs *inside* Kubernetes is owned by ArgoCD from the `fraud-gitops` repo.

One of three repos:

| Repo | Owns |
|---|---|
| **`fraud-infra`** (this) | Terraform → VPC, EKS, IAM, ECR, Secrets Manager, S3 |
| `fraud-backend-CI` | Application and model code, Dockerfiles, CI pipelines |
| `fraud-gitops` | ArgoCD-watched manifests; model promotions land here |

---

## Contents

1. [Architecture](#1-architecture)
2. [Design Decisions](#2-design-decisions)
3. [Prerequisites](#3-prerequisites)
4. [Repository Structure](#4-repository-structure)
5. [Step 1 — Terraform State Bucket](#5-step-1--terraform-state-bucket)
6. [Step 2 — GitHub OIDC Bootstrap](#6-step-2--github-oidc-bootstrap)
7. [Step 3 — Configure for Your Account](#7-step-3--configure-for-your-account)
8. [Step 4 — GitHub Secrets, Variables, Environments](#8-step-4--github-secrets-variables-environments)
9. [Step 5 — Provision via the Pipeline](#9-step-5--provision-via-the-pipeline)
10. [Step 6 — Connect to the Cluster](#10-step-6--connect-to-the-cluster)
11. [Step 7 — Bootstrap ArgoCD and ESO](#11-step-7--bootstrap-argocd-and-eso)
12. [Day-2 Operations](#12-day-2-operations)
13. [Destroying the Platform](#13-destroying-the-platform)
14. [Cost](#14-cost)
15. [Troubleshooting](#15-troubleshooting)

---

## 1. Architecture

### What Terraform creates in Phase 0

```
AWS Account (eu-central-1)
│
├── S3 Bucket  ── created MANUALLY, not by Terraform ──
│   └── fraud-infra-tf-state-<username>
│       ├── envs/dev/terraform.tfstate
│       ├── envs/qa/terraform.tfstate
│       └── envs/prod/terraform.tfstate
│
├── VPC  (10.0.0.0/16)
│   ├── Public Subnets        10.0.1.0/24 (AZ-a)  ] NAT Gateway,
│   │                         10.0.2.0/24 (AZ-b)  ] load balancers
│   ├── Private EKS Subnets   10.0.3.0/24 (AZ-a)  ] both node pools,
│   │                         10.0.4.0/24 (AZ-b)  ] no public IPs
│   └── Private Data Subnets  10.0.5.0/24 (AZ-a)  ] RDS in Phase 1,
│                             10.0.6.0/24 (AZ-b)  ] ElastiCache if ever
│
├── EKS Cluster  (fraud-dev-cluster, Kubernetes 1.33)
│   ├── Node Group "general"    m5.large × 2    UNTAINTED
│   │     label: workload=general
│   │     hosts: scoring service, ArgoCD, Prometheus, Grafana, Jaeger,
│   │            OTel Collector, MLflow, KServe, Argo Workflows
│   │
│   ├── Node Group "memory"     r5.large × 2    TAINTED workload=memory:NoSchedule
│   │     label: workload=memory
│   │     hosts: Elasticsearch, Kafka (Strimzi) — and nothing else
│   │
│   ├── EBS CSI Driver (IRSA)   mandatory; every PVC depends on it
│   └── OIDC Provider           trust anchor for all IRSA roles
│
├── ECR Repositories (6 · immutable tags · scan-on-push · keep-last-10)
│     scoring-service · stream-producer · feature-pipeline
│     retraining-job · drift-monitor · hello-platform
│
├── S3 Buckets (Terraform-managed — NOT the state bucket)
│     fraud-dev-mlflow-artifacts-<account>   model binaries, ONNX exports
│     fraud-dev-dvc-data-<account>           DVC dataset remote
│
├── Secrets Manager  (all under /fraud/dev/*)
│     mlflow-db-credentials · kafka-credentials
│     grafana-admin · gitops-pat
│
└── IAM
    ├── IRSA — pods assume roles via the EKS OIDC provider
    │     fraud-dev-eso-role       secretsmanager:GetSecretValue on /fraud/*
    │     fraud-dev-argocd-role    trust only; no policy yet
    │     fraud-dev-mlflow-role    S3 on artifact + DVC buckets only
    │     fraud-dev-ebs-csi-role   AmazonEBSCSIDriverPolicy
    │
    └── GitHub OIDC — CI assumes roles, no static keys anywhere
          fraud-github-actions-infra-role   created by scripts/00
          fraud-github-actions-app-role     created by Terraform
```

### Deferred by design

| Module | Arrives in | Why not now |
|---|---|---|
| `rds` | Phase 1 | MLflow metadata backend — nothing consumes it yet |
| `redis` | Phase 2 | Feast online store — nothing consumes it yet |

Create infrastructure when something uses it. The exception is anything
irreversible in place — VPC CIDR ranges, for instance, which cannot be
renumbered without destroying the VPC.

### The ownership boundary

The single most important rule in this project.

```
   TERRAFORM                       │   ARGOCD
   (fraud-infra)                   │   (fraud-gitops)
─────────────────────────────────  │  ─────────────────────────────────
   VPC, subnets, NAT               │   Strimzi (Kafka)
   EKS cluster + node groups       │   Elasticsearch + Kibana
   IAM roles, OIDC providers       │   Jaeger, OpenTelemetry Collector
   ECR repositories                │   kube-prometheus-stack
   S3 buckets                      │   MLflow, Feast, Redis
   Secrets Manager entries         │   KServe, Argo Workflows
   RDS (Phase 1)                   │   scoring-service
                                   │
   ── the ONE exception: ArgoCD and ESO themselves, installed once by
      scripts/01, because something has to install the installer.
```

Break this and you get an infinite reconcile loop where Terraform reverts
ArgoCD and ArgoCD reverts Terraform.

---

## 2. Design Decisions

Every deliberate difference from the `Infra-Zen` pattern this repo is based on,
and the reasoning behind it.

### Split node groups, with the memory pool tainted

Infra-Zen runs a single node group. This runs two.

**The problem it solves:** Elasticsearch and Kafka are memory-hungry and bursty.
Sharing a pool with the scoring service means a JVM heap spike or a Kafka
rebalance can create node memory pressure that evicts the latency-critical
scoring pod.

**The mechanism has two halves and needs both:**

- **The taint** `workload=memory:NoSchedule` repels anything that does not
  explicitly tolerate it. This keeps general workloads *off* the memory nodes.
- **The labels** `workload=general` / `workload=memory` let Elasticsearch and
  Kafka *select* the memory pool with a `nodeSelector`, and everything else
  stay on general.

A taint alone means nothing pulls Elasticsearch onto the right nodes. A label
alone means nothing keeps other pods off.

**Sizing:** general is `m5.large` (2 vCPU / 8 GiB). Memory is `r5.large` — also
2 vCPU but **16 GiB**, at roughly the same price. The r-family is
memory-optimised, which is exactly what ES and Kafka want. Root volumes are
50 GiB because Kafka and ES image layers fill the 20 GiB default quickly.

### GitHub OIDC instead of static AWS keys

Infra-Zen's Terraform pipeline used `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` stored as repo secrets — long-lived credentials sitting
in GitHub indefinitely.

Here the pipeline federates: GitHub mints a short-lived signed token per run,
AWS validates it against a registered identity provider and the role's trust
policy, and returns credentials that **expire in one hour**. No long-lived AWS
credential exists in any repo.

This costs one extra bootstrap step (see [Step 2](#6-step-2--github-oidc-bootstrap))
and is the reason the app repos and the infra repo now authenticate the same way.

### Immutable ECR tags

Changed from Infra-Zen's `MUTABLE`.

The retraining loop promotes a model by committing an image tag into
`fraud-gitops`. If that tag could be overwritten, the commit would stop pointing
at a specific artifact — and *"which model is in production, and what data
trained it?"* becomes unanswerable. That destroys the lineage story.

**Practical consequence:** CI must tag with something unique. Use the commit
SHA, never `:latest`.

### `TF_VAR_*` instead of `-var` flags

Infra-Zen passes secrets as `-var="db_password=..."` on the command line.
Command-line arguments are visible in the process table and can surface in
debug output. Environment variables are the safer channel, and Terraform reads
`TF_VAR_x` into `var.x` automatically.

### No Kubernetes provider in Terraform

Infra-Zen declares one. This repo does not, because it creates zero Kubernetes
resources. Declaring a provider that authenticates to a cluster which does not
exist yet is how you get `Provider produced inconsistent result` on a fresh
apply. Dropping it is both a cleaner boundary statement and avoids the bug.

### Single NAT Gateway

Per-AZ NAT survives an AZ failure but doubles the ~$32/month NAT bill. For a
cluster destroyed nightly, single-NAT is correct. The point is that it was
priced, not defaulted.

### `env` drives safety, not just naming

Setting `env = "prod"` automatically flips S3 `force_destroy` off, ECR
`force_delete` off, and — in Phase 1 — RDS multi-AZ on with deletion protection
and 7-day backups. The modules read `var.env` and behave accordingly.

One word, environment-appropriate safety.

### Data-tier subnets, not "RDS subnets"

Infra-Zen names them `private_rds_*`. By Phase 2 this tier may also hold
ElastiCache, so naming it after its first tenant would become a lie. It carries
no `kubernetes.io/*` tags, which is what structurally prevents EKS from ever
placing a node or ENI there.

### ArgoCD installs the platform, not shell scripts

Infra-Zen has four scripts that install NGINX Ingress, ArgoCD, ESO and
metrics-server. Here two scripts install **only** ArgoCD and ESO; everything
else is an ArgoCD Application in `fraud-gitops`.

Adding Kafka in Phase 2 becomes a Git commit rather than a script edit.

### Scale-up alternatives — say these, don't build them

| Built here | At company scale | Why not here |
|---|---|---|
| Strimzi on EKS | Amazon MSK | Self-hosted Kafka is the stronger portfolio signal |
| Redis via Helm | ElastiCache | Cheaper to run and tear down |
| Self-hosted Evidently | Arize | No managed-service budget for a lab |
| DVC | LakeFS | DVC is Git-native and right at this data scale |

---

## 3. Prerequisites

### Tools

| Tool | Version | Needed for |
|---|---|---|
| Terraform | >= 1.10.0 | `use_lockfile` (S3-native locking) requires 1.10+ |
| AWS CLI | v2 | Bootstrap, kubeconfig |
| kubectl | matching 1.33 | Cluster access |
| Helm | v3 | ArgoCD + ESO bootstrap |

```bash
terraform version         # Terraform v1.10.x
aws --version             # aws-cli/2.x.x
kubectl version --client
helm version --short
```

### AWS

An IAM user with permission to create VPC, EKS, IAM, ECR, RDS, S3 and Secrets
Manager resources.

```bash
aws configure
aws sts get-caller-identity     # confirm the account you expect
```

### GitHub

Three repos under one owner: `fraud-infra`, `fraud-backend-CI`, `fraud-gitops`.
Plus a fine-grained PAT scoped to `fraud-gitops` with **Contents: Read and
write** — one token covers both ArgoCD (read) and the Phase 3 retraining job
(write).

---

## 4. Repository Structure

```
fraud-infra/
├── .github/
│   ├── dependabot.yml
│   └── workflows/terraform.yml       plan / apply / destroy, OIDC auth
├── .gitignore
├── README.md
├── docs/
│   └── TROUBLESHOOTING.md            every error hit, cause, and fix
├── envs/
│   └── dev/
│       ├── backend.tf                bucket name — cannot use variables
│       ├── backend.tfvars            region, committed on purpose
│       ├── providers.tf              aws + tls only, no kubernetes
│       ├── variables.tf              region, github_org, four secrets
│       ├── main.tf                   calls all six modules
│       └── outputs.tf                every value the scripts need
├── modules/
│   ├── vpc/                          2 AZs, single NAT, three subnet tiers
│   ├── eks/                          cluster + TWO node groups
│   ├── s3/                           MLflow artifacts + DVC data
│   ├── ecr/                          image repos, immutable tags
│   ├── secrets-manager/              platform secrets under /fraud/<env>/*
│   └── iam/                          IRSA roles + GitHub federation
└── scripts/
    ├── 00-bootstrap-github-oidc.sh   once per AWS account
    ├── 01-bootstrap-argocd-eso.sh    installs ONLY ArgoCD + ESO
    ├── 02-register-gitops.sh         hands ONE root app to ArgoCD
    └── 03-verify-platform.sh         asserts Phase 0 is healthy
```

`envs/qa` and `envs/prod` are added once dev works. An unused prod state file is
a liability, not a feature.

---

## 5. Step 1 — Terraform State Bucket

**One-time, manual, not Terraform.**

Terraform stores its state in S3. It cannot provision the bucket holding its own
state, because it would need somewhere to record having created it. So this one
bucket is created with the AWS CLI.

```bash
BUCKET=fraud-infra-tf-state-<your-github-username>
REGION=eu-central-1

aws s3api create-bucket \
  --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"

# Versioning — required for state rollback AND for S3-native locking
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

`us-east-1` rejects `--create-bucket-configuration`; drop that flag there.

**Do not confuse this with `fraud-dev-mlflow-artifacts-*`.** That bucket is
Terraform-managed, because nothing depends on it existing before Terraform runs.

The bucket name appears in **three** places and all three must agree:
`envs/dev/backend.tf`, the CI role's IAM policy, and the prompt default in
`scripts/00`.

---

## 6. Step 2 — GitHub OIDC Bootstrap

**One-time, per AWS account.**

The Terraform pipeline assumes `fraud-github-actions-infra-role`. If that role
lived inside Terraform, the pipeline could not run until Terraform had run, and
Terraform could not run until the pipeline ran.

So it gets the same treatment as the state bucket: created once by a script
issuing `aws iam` commands. **No local `terraform apply` is ever required.**

```bash
chmod +x scripts/*.sh
./scripts/00-bootstrap-github-oidc.sh
```

It creates three things and prints the role ARN at the end.

### Casing matters — twice

Type your GitHub username and repo name with **exact capitalisation**. IAM
compares these letter by letter. Canonical casing comes from the API, not from
the URL you typed (URLs are case-insensitive and redirect):

```bash
curl -sS https://api.github.com/repos/OWNER/REPO | python3 -c \
  "import sys,json;print(json.load(sys.stdin)['full_name'])"
```

### The subject claim format

GitHub issues **immutable** subject claims with numeric IDs appended:

```
repo:kelvinSeamount@75308769/fraud-infra@1345287244:pull_request
                    ^^^^^^^^^            ^^^^^^^^^^
                    owner ID             repo ID
```

Names can be renamed and re-registered by someone else; the IDs never change.
Binding to them means the trust cannot be hijacked via a repo rename.

The script looks these up automatically via the GitHub API.

### The four `sub` shapes

GitHub changes the claim depending on how the job was triggered:

| Trigger | sub |
|---|---|
| PR | `repo:owner@ID/repo@ID:pull_request` |
| push to main | `repo:owner@ID/repo@ID:ref:refs/heads/main` |
| push to a branch | `repo:owner@ID/repo@ID:ref:refs/heads/<branch>` |
| job with `environment:` | `repo:owner@ID/repo@ID:environment:<name>` |

A job declaring `environment:` produces the environment form **instead of** the
ref form. Miss any shape you use and that trigger path fails.

### `sts:TagSession` is required

`aws-actions/configure-aws-credentials@v4` attaches session tags by default,
which needs `sts:TagSession` in the trust policy alongside
`sts:AssumeRoleWithWebIdentity`. Keep the tags — they land in CloudTrail, so you
can trace which workflow run created which resource.

---

## 7. Step 3 — Configure for Your Account

Two files carry account-specific values.

**`envs/dev/backend.tf`** — cannot use variables; Terraform resolves the backend
before variables exist:

```hcl
bucket = "fraud-infra-tf-state-<your-username>"
region = "eu-central-1"
```

**`envs/dev/variables.tf`** — change the default:

```hcl
variable "github_org" { default = "<your-github-username>" }
```

---

## 8. Step 4 — GitHub Secrets, Variables, Environments

### Repository variables

Settings → Secrets and variables → Actions → **Variables**

| Name | Value |
|---|---|
| `AWS_TF_ROLE_ARN` | the ARN printed by `scripts/00` |
| `GH_ORG` | your GitHub username, **exact capitalisation** |
| `TF_STATE_BUCKET` | your state bucket name |

`GH_ORG` casing matters — it feeds the trust policy of the app CI role that
`fraud-backend-CI` uses in Part 3.

### Repository secrets

Same page, **Secrets** tab. Generate each with:

```bash
openssl rand -base64 24 | tr -d '/+=' | head -c 24; echo
```

| Name | Value |
|---|---|
| `DEV_MLFLOW_DB_PASSWORD` | generated |
| `DEV_KAFKA_PASSWORD` | generated |
| `DEV_GRAFANA_ADMIN_PASSWORD` | generated |
| `DEV_GITOPS_PAT` | your GitHub PAT with write access to `fraud-gitops` |

**If a secret is missing, Terraform receives an empty string rather than
failing.** The plan still passes, and you get AWS secrets containing empty
passwords — which breaks RDS in Phase 1 in a way that is annoying to trace.
Verify all four exist.

There is no `AWS_ACCESS_KEY_ID` secret. That absence is the point.

### Environments

Settings → Environments → create `dev`, `qa`, `prod`. Add yourself as a
required reviewer on `prod`. The apply job declares `environment:`, so the run
pauses for approval.

---

## 9. Step 5 — Provision via the Pipeline

Every `terraform` command runs in GitHub Actions. Nothing is applied locally.

### Via a Pull Request (recommended)

```bash
git checkout -b feature/my-change
# make changes
git push -u origin feature/my-change
# open a PR into main  →  plan runs and comments on the PR
# read the plan, then merge  →  apply runs behind the environment gate
```

### Via the Run workflow button

```
Actions → Terraform Infrastructure → Run workflow
  Use workflow from  : <any branch>
  Target environment : dev | qa | prod
  Terraform action   : plan | apply | destroy
```

**The button only appears if `terraform.yml` exists on the default branch.**
GitHub takes the button from `main` but runs the code from whichever branch you
select — which is how you apply from a feature branch without merging.

If `main` does not have it yet:

```bash
git checkout main
git checkout feature/my-branch -- .github/workflows/terraform.yml
git commit -m "Add Terraform workflow to main [skip ci]"
git push origin main
git checkout feature/my-branch
```

`[skip ci]` stops that push starting a run of its own.

Apply takes 15–20 minutes. The EKS control plane alone is about 10.

---

## 10. Step 6 — Connect to the Cluster

```bash
aws eks update-kubeconfig --region eu-central-1 --name fraud-dev-cluster
kubectl get nodes -L workload
```

Expect four nodes — two `general`, two `memory`.

### If you get "You must be logged in to the server"

EKS grants cluster-admin to whoever **created** the cluster. That was GitHub
Actions, so the CI role has admin and your local user does not.

```bash
aws eks list-access-entries --cluster-name fraud-dev-cluster --region eu-central-1
aws sts get-caller-identity --query Arn --output text
```

If your ARN is not in that list, add it — permanently, in `envs/dev/main.tf`,
so it survives rebuilds:

```hcl
resource "aws_eks_access_entry" "local_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/Fraud.ci"
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "local_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.local_admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
```

### Verify the taint actually landed

This is the check that matters — the taint is what stops Elasticsearch evicting
your scoring pod.

```bash
kubectl get nodes -l workload=memory \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints[*].key}={.spec.taints[*].value}:{.spec.taints[*].effect}{"\n"}{end}'
```

Prove it with a throwaway pod — one with no toleration must land on general:

```bash
kubectl run taint-test --image=busybox --restart=Never -- sleep 60
kubectl get node "$(kubectl get pod taint-test -o jsonpath='{.spec.nodeName}')" \
  -o jsonpath='{.metadata.labels.workload}{"\n"}'      # must print: general
kubectl delete pod taint-test
```

---

## 11. Step 7 — Bootstrap ArgoCD and ESO

```bash
./scripts/01-bootstrap-argocd-eso.sh
```

Installs **only** ArgoCD and External Secrets Operator. Save the ArgoCD admin
password it prints.

Then, once `fraud-gitops` exists:

```bash
./scripts/02-register-gitops.sh      # registers the repo, applies ONE root app
./scripts/03-verify-platform.sh      # six checks
```

`scripts/03` reports `WARN` rather than `FAIL` for components that arrive in
later phases, so run it as often as you like.

---

## 12. Day-2 Operations

```bash
# Format before pushing — the pipeline checks this
terraform fmt -recursive

# Check for drift: Actions → Run workflow → dev / plan, read the diff

# Scale a node pool: edit general_max_size in envs/dev/main.tf and merge.
# desired_size is under ignore_changes — the autoscaler owns it at runtime,
# so Terraform will not fight it.

# Add an ECR repository: append to the repositories list in envs/dev/main.tf.
# for_each means existing repos are untouched.
```

---

## 13. Destroying the Platform

**Order matters.** Kubernetes-created AWS resources — load balancers, EBS
volumes — are invisible to Terraform. Destroy the cluster contents first, or
`terraform destroy` hangs on a VPC that still has ENIs attached.

```bash
# 1. Stop ArgoCD recreating what you delete
kubectl patch app fraud-platform-root-dev -n argocd \
  --type merge -p '{"spec":{"syncPolicy":null}}'

# 2. Delete Applications — removes their load balancers and PVCs
kubectl delete applications --all -n argocd

# 3. Confirm nothing is orphaned
kubectl get svc -A | grep LoadBalancer
kubectl get pvc -A
```

Then:

```
Actions → Run workflow
  Target environment : dev
  Terraform action   : destroy
  Type "destroy"     : destroy
```

**Before ArgoCD is installed, steps 1–3 are unnecessary** — nothing is running
in the cluster, so destroy is clean.

**`force_destroy = true` outside prod deletes your model artifacts** along with
the buckets. Copy anything you want to keep first.

The state bucket survives; it is not Terraform-managed.

---

## 14. Cost

Rough `eu-central-1` figures, running 24/7:

| Resource | Qty | USD / month |
|---|---|---|
| EKS control plane | 1 | 73 |
| m5.large (general pool) | 2 | 140 |
| r5.large (memory pool) | 2 | 182 |
| NAT Gateway + data transfer | 1 | 35 |
| EBS root volumes (50 GiB × 4) | 4 | 20 |
| EBS PVCs (ES, Kafka, Prometheus) | — | 30 |
| S3 + ECR + Secrets Manager | — | 10 |
| CloudWatch control-plane logs | — | 5 |
| **Phase 0 total** | | **~495** |
| RDS db.t3.micro (Phase 1) | 1 | +18 |

About **$16/day**. Destroy at the end of each session — the whole platform is
code, so a rebuild is one pipeline run plus two scripts.

Running all three environments simultaneously costs roughly $1,500/month. Run
one at a time. The `qa` and `prod` directories are the portfolio artifact; you
do not need to pay to run them.

---

## 15. Troubleshooting

Every error encountered while building this, with root cause and fix, is in
[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

The two most useful diagnostic commands:

```bash
# OIDC refused? This prints the exact sub claim GitHub presented.
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 5 --region eu-central-1

# kubectl refused? This shows who actually has cluster access.
aws eks list-access-entries --cluster-name fraud-dev-cluster --region eu-central-1
```

---

## What's Next

**Phase 1 — Serving Loop:** add the `rds` module as the MLflow metadata backend,
train a first-cut XGBoost model, version the dataset with DVC against the bucket
this repo already created, and serve it behind KServe.

> **Interview talking point:** "Before a single model existed, I could ship a
> change by committing a manifest and watching ArgoCD reconcile it. The delivery
> mechanism was proven before the payload."
