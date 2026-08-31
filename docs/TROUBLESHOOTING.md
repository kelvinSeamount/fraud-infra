# Troubleshooting Log — Phase 0

Every error hit while standing up `fraud-infra`, what actually caused it, and
the fix.

Nine were real; one was a red herring. Read the red herring first so you don't
chase it.

---

## 0. The red herring — Node 20 deprecation warning

```
Node 20 is being deprecated. This workflow is running with Node 24 by default.
```

**Not an error.** It appears at the top of almost every step and is unrelated to
whatever actually failed. Scroll past it to the real `Error:` line.

It is a GitHub runner notice, not your workflow.

---

## 1. Workflow never ran — no Actions triggered at all

**Symptom:** PR opened, pushes made, nothing in the Actions tab. No failure, no
run, silence.

**Cause:** the repository root contained a single folder, and everything lived
inside it:

```
fraud-infra/                    ← the repo root
└── fraud-infra/                ← an extra nesting level
    ├── .github/workflows/terraform.yml
    ├── envs/
    └── modules/
```

GitHub only reads workflow definitions from `.github/workflows/` at the
**repository root**. A nested `.github` directory is ignored completely — as far
as GitHub was concerned, the repo had no workflows.

**Fix:**

```bash
git mv fraud-infra/.github    .
git mv fraud-infra/.gitignore .
git mv fraud-infra/envs       .
git mv fraud-infra/modules    .
git mv fraud-infra/scripts    .
rmdir fraud-infra
```

Dot-files are listed explicitly — a plain `git mv fraud-infra/* .` silently
skips `.github` and `.gitignore`, which is how the nesting survives a move.

**Lesson:** when Actions does nothing at all — no run, not even a failed one —
suspect file placement, not workflow syntax. A syntax error produces a visible
red run; a misplaced file produces nothing.

---

## 2. Terraform module not found

**Symptom:** `terraform init` fails with "Module not installed" for
`secrets-manager`.

**Cause:** directory on disk was `modules/secret-manager` (singular), while
`envs/dev/main.tf` referenced `../../modules/secrets-manager` (plural).

**Fix:**

```bash
git mv modules/secret-manager modules/secrets-manager
```

**Lesson:** Terraform module sources are literal paths. There is no fuzzy
matching.

---

## 3–5. `Not authorized to perform sts:AssumeRoleWithWebIdentity`

This one error message covered **three separate root causes**. Each fix was
correct, and each time the error stayed byte-for-byte identical — which made it
look like nothing was working.

**This is the key lesson of Phase 0:** AWS returns one generic message for every
trust-policy mismatch. It never tells you *which* condition failed.

### The tool that ends the guessing

CloudTrail logs every failed STS call with the full identity presented:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 5 --region eu-central-1
```

The `userIdentity.principalId` field contains the exact `sub` claim GitHub sent.
Compare it against the trust policy and the mismatch is obvious.

**Run this first, not fourth.**

### 3. Username casing

```
Trust policy : repo:kelvinseamount/fraud-infra:pull_request
GitHub sends : repo:kelvinSeamount/fraud-infra:pull_request
                       ↑ capital S
```

IAM `StringLike` is case-sensitive. The bootstrap script had taken whatever was
typed at its prompt.

Canonical casing comes from the GitHub API, not from the URL you typed — URLs
are case-insensitive and redirect:

```bash
curl -sS https://api.github.com/repos/OWNER/REPO | python3 -c \
  "import sys,json;print(json.load(sys.stdin)['full_name'])"
```

### 4. Missing `sts:TagSession`

The debug log gave this away:

```
##[debug]7 role session tags are being used.
```

`aws-actions/configure-aws-credentials@v4` attaches session tags (repo,
workflow, actor, branch) by default. Doing so requires `sts:TagSession`
permission in the **trust policy**. Ours allowed only
`sts:AssumeRoleWithWebIdentity`, so the whole request was denied.

**Fix — the Action must be a list:**

```json
"Action": ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"],
```

The alternative is `role-skip-session-tagging: true` in the workflow, but the
tags are worth keeping — they land in CloudTrail, so you can trace which
workflow run created which resource.

### 5. Immutable subject format — the actual root cause

CloudTrail finally showed what GitHub was really sending:

```
repo:kelvinSeamount@75308769/fraud-infra@1345287244:pull_request
                    ^^^^^^^^^            ^^^^^^^^^^
                    owner ID             repo ID
```

GitHub now issues **immutable subject claims** with numeric IDs appended. None
of the name-only patterns matched — including a `repo:owner/repo:*` wildcard,
because the `@id` segments sit between the name and the wildcard.

**Why GitHub does this:** names can be renamed and re-registered. If you renamed
your repo and someone else claimed `owner/repo`, a name-based trust policy would
let *their* workflows into *your* AWS account. Numeric IDs never change and
cannot be claimed by anyone else.

**Fix:**

```json
"StringLike": {
  "token.actions.githubusercontent.com:sub": [
    "repo:kelvinSeamount@75308769/fraud-infra@1345287244:*",
    "repo:kelvinSeamount/fraud-infra:*"
  ]
}
```

The second line is a fallback in case the plain format is ever used.

Look the IDs up like this:

```bash
curl -sS https://api.github.com/users/OWNER \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])"
curl -sS https://api.github.com/repos/OWNER/REPO \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])"
```

### The four `sub` shapes to know

| Trigger | sub |
|---|---|
| PR | `repo:owner@ID/repo@ID:pull_request` |
| push to main | `repo:owner@ID/repo@ID:ref:refs/heads/main` |
| push to a branch | `repo:owner@ID/repo@ID:ref:refs/heads/<branch>` |
| job with `environment:` | `repo:owner@ID/repo@ID:environment:<name>` |

A job declaring `environment:` produces the environment form **instead of** the
ref form. Miss any shape you use and that path fails.

---

## 6. Terraform state bucket did not exist

**Cause:** `backend.tf` and the CI IAM policy both said
`fraud-tf-state-kelvinseamount`. The bucket actually created was
`fraud-infra-tf-state-kelvinseamount`.

**Detect:**

```bash
aws s3api head-bucket --bucket <name>     # 404 means it does not exist
aws s3api list-buckets --query 'Buckets[].Name' --output table
```

**Fix:** correct the name in `envs/dev/backend.tf` and in the CI role's policy.
S3 buckets cannot be renamed, so the code moves to match reality.

**Lesson:** the backend bucket is referenced in **three** places —
`backend.tf`, the IAM policy, and the bootstrap script's prompt default. All
three must agree.

---

## 7. No "Run workflow" button in the Actions UI

**Cause:** GitHub only shows the button when the workflow file exists on the
**default branch**. Ours lived only on a feature branch; `main` held a single
`.gitignore`.

**Fix — put only the workflow file on main, not the Terraform code:**

```bash
git checkout main
git checkout feature/my-branch -- .github/workflows/terraform.yml
git commit -m "Add Terraform workflow to main [skip ci]"
git push origin main
git checkout feature/my-branch
```

`[skip ci]` prevents this push starting a run of its own — `main` has no
Terraform code yet, so that run would fail noisily.

The button then comes from `main`, while the **code that runs** comes from
whichever branch you select in "Use workflow from". That gives you
apply-from-branch without merging.

**Two related UI traps:**

- The button is hidden while a search filter is active in the runs list.
- The "All workflows" page never shows it — select the specific workflow in the
  left sidebar first.

---

## 8. `kubectl` — You must be logged in to the server

**Symptom:**

```
error: You must be logged in to the server
       (the server has asked for the client to provide credentials)
```

after a successful `aws eks update-kubeconfig`.

**Cause:** EKS grants cluster-admin to whoever **created** the cluster
(`bootstrap_cluster_creator_admin_permissions = true`). The cluster was created
by GitHub Actions, so `fraud-github-actions-infra-role` got admin. The local IAM
user was never added.

**Diagnose:**

```bash
aws eks list-access-entries --cluster-name fraud-dev-cluster --region eu-central-1
aws sts get-caller-identity --query Arn --output text
```

If your ARN is not in that list, that is the problem.

**Fix (immediate):**

```bash
aws eks create-access-entry \
  --cluster-name fraud-dev-cluster --region eu-central-1 \
  --principal-arn arn:aws:iam::<ACCOUNT>:user/<USER> --type STANDARD

aws eks associate-access-policy \
  --cluster-name fraud-dev-cluster --region eu-central-1 \
  --principal-arn arn:aws:iam::<ACCOUNT>:user/<USER> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

**Fix (permanent)** — otherwise it recurs on every rebuild. Add to
`envs/dev/main.tf`:

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

**Lesson:** this is the cost of building infrastructure from a pipeline — the
pipeline owns what it creates. Grant your own access explicitly, in code.

---

## 9. `Error acquiring the state lock` on destroy

**Symptom:**

```
Error: Error acquiring the state lock
api error PreconditionFailed
Lock Info:
  Operation: OperationTypePlan
  Who:       runner@runnervm...
```

Note `Operation: OperationTypePlan` — a *plan* held the lock while *destroy* was
trying to run.

**Cause:** the `plan` job had no `if:` condition, so on a `workflow_dispatch`
with `action=destroy` **both jobs started simultaneously**. Plan took the lock;
destroy could not get it.

**Fix — skip plan on destroy:**

```yaml
  plan:
    name: Terraform Plan (${{ github.event.inputs.environment || 'dev' }})
    runs-on: ubuntu-latest
    if: github.event.inputs.action != 'destroy'
```

On push and PR events `action` is empty, so plan still runs normally.

**Clearing a stale lock:**

```bash
aws s3 ls s3://<state-bucket>/envs/dev/
aws s3 rm s3://<state-bucket>/envs/dev/terraform.tfstate.tflock
```

Only remove a lock when you are certain no run is active. Deleting a live lock
while a job writes state is how state files get corrupted.

**Note:** Infra-Zen carries the same latent bug — its plan job has no `if`
either.

---

## Still outstanding

`fraud-github-actions-app-role` (used by `fraud-backend-CI`) was created by
Terraform with both faults from sections 3 and 5 — lowercase owner, name-only
subject:

```
repo:kelvinseamount/fraud-backend-CI:ref:refs/heads/main
```

It will fail exactly as sections 3–5 did. Two fixes needed before Part 3:

1. Repo variable `GH_ORG` → `kelvinSeamount` (capital S)
2. In `modules/iam/github-actions-oidc.tf`:

```hcl
      values = [
        "repo:${var.github_org}@*/${var.app_repo}@*:*",
        "repo:${var.github_org}/${var.app_repo}:*",
      ]
```

---

## Debugging order for next time

1. **Read past the Node 20 warning** to the real `Error:` line.
2. **Nothing ran at all?** File placement, not syntax.
3. **OIDC refused?** CloudTrail first — never guess at the `sub`.
4. **kubectl refused?** `aws eks list-access-entries`.
5. **State lock?** Check `Operation:` in the lock info — it names the culprit.
6. **UI element missing?** Check the default branch and clear any filter.

The recurring theme: **one generic error message can have several unrelated
causes.** Get the actual data — CloudTrail, access entries, lock info — before
changing anything.
