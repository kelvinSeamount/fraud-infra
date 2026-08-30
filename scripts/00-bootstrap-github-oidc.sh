#!/usr/bin/env bash
# =============================================================================
# Step 0b — Bootstrap GitHub OIDC (run ONCE per AWS account)
#
# Idempotent — safe to re-run.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] OK  $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] !!  $*${NC}"; }
die()  { echo -e "${RED}[$(date +%H:%M:%S)] ERR $*${NC}" >&2; exit 1; }
info() { echo -e "${CYAN}[$(date +%H:%M:%S)]    $*${NC}"; }

prompt() {
  local var_name="$1" label="$2" example="$3" default="${4:-}"
  local current="${!var_name:-}"
  if [[ -n "$current" ]]; then
    info "Using $var_name=$current  (pre-set in environment, skipping prompt)"
    return
  fi
  echo ""
  echo -e "${CYAN}  $label${NC}"
  echo    "    Example : $example"
  if [[ -n "$default" ]]; then
    echo -ne "    Default : $default\n    Your value [press Enter to use default]: "
  else
    echo -ne "    Your value: "
  fi
  read -r input
  local value="${input:-$default}"
  [[ -z "$value" ]] && die "'$label' is required and cannot be empty."
  printf -v "$var_name" '%s' "$value"
  log "  $var_name = $value"
}

command -v aws >/dev/null 2>&1 || die "aws CLI not found."
aws sts get-caller-identity >/dev/null 2>&1 || die "AWS CLI not authenticated. Run 'aws configure'."

echo ""
echo "======================================================"
echo "  Fraud Platform -- GitHub OIDC Bootstrap (run once)"
echo "======================================================"
echo ""
echo "  Creates the IAM trust that lets GitHub Actions run Terraform"
echo "  with NO static AWS access keys."
echo ""
echo "  After this you never run Terraform locally — everything goes"
echo "  through the GitHub Actions UI."
echo ""

PROJECT=""; GITHUB_ORG=""; INFRA_REPO=""; TF_STATE_BUCKET=""; AWS_REGION=""

prompt PROJECT         "Project name (prefixes all resource names)" "fraud" "fraud"
prompt GITHUB_ORG      "Your GitHub username or org"                "kelvinSeamount" ""
prompt INFRA_REPO      "Infrastructure repo name"                   "fraud-infra" "fraud-infra"
prompt TF_STATE_BUCKET "Terraform state bucket (the one you created by hand)" \
                       "fraud-tf-state-kelvinseamount" ""
prompt AWS_REGION      "AWS region"                                  "eu-central-1" "eu-central-1"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_URL="token.actions.githubusercontent.com"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_URL}"
ROLE_NAME="${PROJECT}-github-actions-infra-role"
POLICY_NAME="${PROJECT}-github-actions-infra-policy"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

echo ""
echo "  ----- Configuration Summary -----"
echo "  AWS Account  : $ACCOUNT_ID"
echo "  Region       : $AWS_REGION"
echo "  GitHub repo  : ${GITHUB_ORG}/${INFRA_REPO}"
echo "  State bucket : $TF_STATE_BUCKET"
echo "  Role to make : $ROLE_NAME"
echo "  ---------------------------------"
echo ""
echo -ne "  Continue? [Y/n]: "
read -r confirm
[[ "${confirm:-Y}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo ""

# =============================================================================
# Step 1 of 3 — OIDC identity provider
#
# AWS registering "I trust GitHub as an issuer of identities".
# ONE per AWS account — that is why it is not per-environment.
# =============================================================================
echo "--------------------------------------------"
echo "  Step 1 of 3: OIDC identity provider"
echo "--------------------------------------------"

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  log "OIDC provider already exists — skipping."
else
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_URL}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list \
        "6938fd4d98bab03faadb97b34396831e3780aea1" \
        "1c58a3a8518e8759bf075b76b750d4f2df264fcd" \
    --tags "Key=Project,Value=${PROJECT}" "Key=ManagedBy,Value=bootstrap-script" \
    >/dev/null
  log "OIDC provider created: $OIDC_ARN"
fi

# =============================================================================
# Step 2 of 3 — the IAM role and its trust policy
#
# The five "sub" patterns are what make the environment dropdown work. GitHub
# changes the sub claim depending on how the job was triggered:
#   plan on a PR            -> repo:org/fraud-infra:pull_request
#   plan on push to main    -> repo:org/fraud-infra:ref:refs/heads/main
#   apply/destroy (any env) -> repo:org/fraud-infra:environment:<name>
# Miss any and that trigger path fails with "Not authorized".
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  Step 2 of 3: IAM role"
echo "--------------------------------------------"

TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${OIDC_ARN}" },
      "Action": ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"],
      "Condition": {
        "StringEquals": {
          "${OIDC_URL}:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "${OIDC_URL}:sub": [
            "repo:${GITHUB_ORG}/${INFRA_REPO}:ref:refs/heads/main",
            "repo:${GITHUB_ORG}/${INFRA_REPO}:pull_request",
            "repo:${GITHUB_ORG}/${INFRA_REPO}:environment:dev",
            "repo:${GITHUB_ORG}/${INFRA_REPO}:environment:qa",
            "repo:${GITHUB_ORG}/${INFRA_REPO}:environment:prod"
          ]
        }
      }
    }
  ]
}
EOF
)

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "$TRUST_POLICY"
  log "Role exists — trust policy updated."
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --max-session-duration 3600 \
    --description "Terraform pipeline role for ${GITHUB_ORG}/${INFRA_REPO} (all environments)" \
    --tags "Key=Project,Value=${PROJECT}" "Key=ManagedBy,Value=bootstrap-script" \
    >/dev/null
  log "Role created: $ROLE_NAME"
fi

# =============================================================================
# Step 3 of 3 — permissions
#
# Scoped to the services this stack actually uses, not AdministratorAccess.
# The state-bucket rule covers envs/dev, envs/qa and envs/prod with one
# statement — which is why ONE role serves all three environments.
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  Step 3 of 3: Permissions policy"
echo "--------------------------------------------"

PERMISSIONS_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformStateAccess",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetBucketVersioning"],
      "Resource": "arn:aws:s3:::${TF_STATE_BUCKET}"
    },
    {
      "Sid": "TerraformStateObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${TF_STATE_BUCKET}/*"
    },
    {
      "Sid": "PlatformServices",
      "Effect": "Allow",
      "Action": [
        "ec2:*", "eks:*", "ecr:*", "rds:*", "elasticache:*",
        "secretsmanager:*", "s3:*", "kms:*", "logs:*",
        "autoscaling:*", "cloudwatch:*", "elasticloadbalancing:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMManagement",
      "Effect": "Allow",
      "Action": ["iam:*"],
      "Resource": "*"
    },
    {
      "Sid": "ReadOnlyIdentity",
      "Effect": "Allow",
      "Action": ["sts:GetCallerIdentity", "tag:GetResources"],
      "Resource": "*"
    }
  ]
}
EOF
)

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  # Policies keep max 5 versions — prune non-default ones before adding
  for v in $(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
              --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$v" || true
  done
  aws iam create-policy-version \
    --policy-arn "$POLICY_ARN" \
    --policy-document "$PERMISSIONS_POLICY" \
    --set-as-default >/dev/null
  log "Policy exists — new version set as default."
else
  aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "$PERMISSIONS_POLICY" \
    --description "Permissions for the ${INFRA_REPO} Terraform pipeline" \
    >/dev/null
  log "Policy created: $POLICY_NAME"
fi

aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
log "Policy attached to role."

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

echo ""
echo "  ============================================================"
echo "  BOOTSTRAP COMPLETE"
echo "  ============================================================"
echo ""
echo "  Role ARN:"
echo ""
echo "      $ROLE_ARN"
echo ""
echo "  Now set it in GitHub:"
echo "    ${INFRA_REPO} -> Settings -> Secrets and variables -> Actions"
echo "      -> Variables tab -> New repository variable"
echo ""
echo "      Name  : AWS_TF_ROLE_ARN"
echo "      Value : $ROLE_ARN"
echo ""
echo "  Also add these two variables:"
echo "      GH_ORG          = $GITHUB_ORG"
echo "      TF_STATE_BUCKET = $TF_STATE_BUCKET"
echo ""
echo "  Then run everything from the Actions UI. No local Terraform."
echo "  ============================================================"
