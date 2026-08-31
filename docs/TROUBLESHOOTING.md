# Troubleshooting Log — Phase 0

Every error hit while standing up `fraud-infra`, what actually caused it, and
the fix.

Twelve were real; one was a red herring. Read the red herring first so you don't
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

**Note:** this is easy to miss. A plan job with no `if` condition looks harmless
for months — it only bites the first time you dispatch a destroy.

---

## 10. `no matches for kind "ClusterSecretStore"` — Step B, script 01

**Symptom:**

```
error: resource mapping not found for name: "aws-secrets-manager" namespace: ""
from "STDIN": no matches for kind "ClusterSecretStore" in version
"external-secrets.io/v1beta1"
ensure CRDs are installed first
```

**The misleading part:** "ensure CRDs are installed first" sends you off to
reinstall External Secrets. The CRDs were installed and fine — all twenty-five
of them.

**Cause:** the script asked for API version `external-secrets.io/v1beta1`. The
chart installed was External Secrets **2.10.0**, which promoted the API to `v1`
and stopped serving the beta. The CRD still *lists* `v1beta1` as a historical
entry, but with `served: false` — which is exactly why the error says "no
matches for kind" rather than "CRD not found".

**The command that ends the guessing:**

```bash
kubectl api-resources --api-group=external-secrets.io
```

```
NAME                  SHORTNAMES   APIVERSION               NAMESPACED   KIND
clustersecretstores   css          external-secrets.io/v1   false        ClusterSecretStore
externalsecrets       es           external-secrets.io/v1   true         ExternalSecret
secretstores          ss           external-secrets.io/v1   true         SecretStore
```

Only `v1`. To see what a CRD serves versus merely remembers:

```bash
kubectl get crd clustersecretstores.external-secrets.io \
  -o jsonpath='{range .spec.versions[*]}{.name}{" served="}{.served}{"\n"}{end}'
```

```
v1        served=true
v1beta1   served=false
```

**Fix:** one word in `scripts/01-bootstrap-argocd-eso.sh`:

```yaml
apiVersion: external-secrets.io/v1
```

**Root cause behind the root cause:** the chart version was unpinned. The script
was written against ESO 0.x and the chart floated forward underneath it. A guard
now runs before the manifest is applied:

```bash
kubectl api-resources --api-group=external-secrets.io 2>/dev/null \
  | grep -q "ClusterSecretStore" \
  || die "ClusterSecretStore CRD is not present. Re-run Step 3 with --set crds.enabled=true"
```

**Related, found at the same time:** the chart also renamed `installCRDs` to
`crds.enabled` in 2.x. Helm **silently ignores** values it does not recognise —
no warning, no error — so `--set installCRDs=true` had been doing nothing. It
happened to work because the chart installs CRDs by default. That is luck, not
configuration.

---

## 11. ESO ServiceAccount holding an unusable role ARN

**Symptom:** none, initially. Nothing failed loudly. It would have surfaced as a
permanently `Invalid` ClusterSecretStore and sent us hunting the IAM trust
policy.

**Found with:**

```bash
kubectl get sa external-secrets -n external-secrets \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
```

```
arn:aws:iam::8662-5908-4078:role/fraud-dev-eso-role
```

**Cause:** the AWS console *displays* the account ID as `8662-5908-4078`. The
dashes are formatting, like the spaces in a credit card number. That string was
pasted into the script's prompt. AWS does not accept it — the ARN points at an
account that does not exist.

The correct value is always twelve bare digits:

```bash
aws sts get-caller-identity --query Account --output text
# 866259084078
```

**Fix — re-annotate and restart:**

```bash
kubectl annotate serviceaccount external-secrets -n external-secrets \
  eks.amazonaws.com/role-arn=arn:aws:iam::866259084078:role/fraud-dev-eso-role \
  --overwrite

kubectl rollout restart deployment external-secrets -n external-secrets
kubectl rollout status  deployment external-secrets -n external-secrets
```

The restart is mandatory. The pod reads its annotation once, at startup.

**Prevention — added to script 01, before the ARN is built:**

```bash
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID//[^0-9]/}"
[[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || die "AWS account ID must be 12 digits. Got: '$AWS_ACCOUNT_ID'"
```

The first line discards every non-digit, so a pasted `8662-5908-4078` silently
becomes correct. The second refuses to continue if what remains is not twelve
digits.

And a check *after* the Helm install, so a bad ARN fails in one second rather
than one hour:

```bash
ANNOTATED_ARN=$(kubectl get sa external-secrets -n external-secrets \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
if [[ "$ANNOTATED_ARN" != "$ESO_ROLE_ARN" ]]; then
  die "ServiceAccount annotation is '$ANNOTATED_ARN', expected '$ESO_ROLE_ARN'."
fi
```

**Lesson:** an IRSA failure is not always the trust policy. Check the annotation
the pod is actually holding before touching IAM. The trust policy here was
correct the entire time.

---

## 12. ArgoCD port-forward — `connection reset by peer`

**Symptom:**

```
Forwarding from 127.0.0.1:8080 -> 8080
Handling connection for 8080
E0831 22:16:24 "Unhandled Error" err="an error occurred forwarding 8080 -> 8080:
  ... read: connection reset by peer"
error: lost connection to pod
```

**Cause:** the browser was opening `https://localhost:8080`. The script had
installed ArgoCD with:

```bash
--set configs.params."server\.insecure"=true
```

That flag turns ArgoCD's own TLS **off** — it serves plain HTTP on 8080. A
browser sending an encrypted handshake to a plaintext listener gets the
connection dropped. Nothing was broken; two ends were speaking different
protocols.

**Two clues that were there all along:**

1. The forward reported `-> 8080`, never `-> 443`. Both service ports target
   the same container port:

   ```
   http   port=80   targetPort=8080
   https  port=443  targetPort=8080
   ```

   So `8080:443` and `8080:80` are identical. That was never the variable —
   both were tried repeatedly, and both failed for the same reason.

2. ArgoCD says which mode it is in, in its first ten log lines:

   ```bash
   kubectl logs -n argocd deploy/argocd-server | grep "tls:"
   ```

   ```
   argocd v3.5.2 serving on port 8080 (url: https://argocd.example.com, tls: false, ...)
   ```

   `tls: false` settles it in two seconds.

**Confirming without a browser** — takes the browser's opinions out of the
picture:

```bash
curl -I http://localhost:8080     # HTTP/1.1 200 OK
curl -I https://localhost:8080    # curl: (35) SSL routines ... alert protocol version
```

**Compounding problem — the browser cached the wrong scheme.**
`https://localhost:8080` had been used for months on the Infra-Zen project.
Chrome remembered "localhost:8080 means https" and silently upgraded `http` back
to `https`, so typing the correct URL still failed.

Workarounds, in order of preference:

1. Use `http://127.0.0.1:8080` — a different hostname, with no cached note
   against it. `localhost` also resolves to both `127.0.0.1` and `::1`, adding a
   second source of ambiguity.
2. `chrome://net-internals/#hsts` -> **Delete domain security policies** ->
   `localhost`.
3. `chrome://settings/security` -> turn off **Always use secure connections**.

**Resolution — the flag was removed entirely.** `server.insecure=true` is a
statement that *something in front of ArgoCD is terminating TLS*. No ingress
exists in this cluster, so the flag asserted something untrue. ArgoCD now runs at
its default: it self-signs and serves HTTPS end to end, matching Infra-Zen.

| Option | Encryption | Access | Verdict |
|---|---|---|---|
| ALB + ACM cert + Route53 | Real, trusted | `https://argocd.fraud-dev.piroo.online` | The target — Phase 4 |
| ArgoCD default, self-signed | Real, untrusted cert | `https://localhost:8080` + click through | **Chosen for Phase 0** |
| `server.insecure=true`, no ingress | None at ArgoCD | `http://127.0.0.1:8080` | Rejected — claims a proxy that does not exist |

Over `port-forward` the practical security difference between the last two is
near zero, because the tunnel is already encrypted by the Kubernetes API. The
reason to prefer the default is that the configuration stops describing
infrastructure that was never built. Turn the flag back on in Phase 4, when the
ALB is real.

**Note:** `scripts/03-verify-platform.sh` already printed `8080:443`. Script 01
was the only file in the repo out of step with the rest.

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
7. **"No matches for kind"?** `kubectl api-resources --api-group=<group>`. The
   CRD is usually present; the API version moved.
8. **IRSA not working?** Read the ServiceAccount annotation before touching IAM.
9. **Connection reset on port-forward?** `curl -I http://...` first. If curl
   works, the problem is the browser, not the cluster.

The recurring theme: **one generic error message can have several unrelated
causes.** Get the actual data — CloudTrail, access entries, lock info,
`api-resources`, the pod's own startup log — before changing anything.

A second theme, new in sections 10–12: **the component will tell you its own
state if you ask it.** `api-resources` names the served API version. The
ServiceAccount shows the ARN it holds. `argocd-server` prints `tls:` in its
first ten log lines. Three of tonight's errors were each two seconds of reading
away.
