#!/usr/bin/env bash
#
# One-time AWS bootstrap for interview-prep-infra.
#
# Run this ONCE in AWS CloudShell (region ap-south-1) as an admin of the AWS account.
# It creates only what Terraform needs before Terraform can run:
#
#   1. S3 bucket for Terraform state   interview-prep-tfstate-<account-id>
#   2. GitHub OIDC identity provider   token.actions.githubusercontent.com
#   3. IAM role for `terraform plan`   interview-prep-terraform-plan   (read-only)
#   4. IAM role for `terraform apply`  interview-prep-terraform-apply  (main branch only)
#
# Everything else (Lightsail VM, disk, backup bucket, backup IAM user) is Terraform.
#
# The script is idempotent: re-running it updates policies and skips what exists.
# It never creates access keys and prints no secrets.
#
# Usage (in CloudShell, from a checkout of this repo):
#   bash bootstrap/bootstrap.sh            # asks for confirmation
#   bash bootstrap/bootstrap.sh --yes      # no prompt
#
set -euo pipefail

REGION="${REGION:-ap-south-1}"
GITHUB_OWNER="${GITHUB_OWNER:-prudhvitej47}"
INFRA_REPO="${INFRA_REPO:-interview-prep-infra}"
PLAN_ROLE="${PLAN_ROLE:-interview-prep-terraform-plan}"
APPLY_ROLE="${APPLY_ROLE:-interview-prep-terraform-apply}"
OIDC_HOST="token.actions.githubusercontent.com"
# GitHub's published thumbprints. IAM no longer relies on them for GitHub, but the
# CreateOpenIDConnectProvider API still accepts them, so we pass them for older CLIs.
GITHUB_THUMBPRINTS=(6938fd4d98bab03faadb97b34396831e3780aea1 1c58a3a8518e8759bf075b76b750d4f2df264fcd)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null || die "aws CLI not found (run this in AWS CloudShell)"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
STATE_BUCKET="interview-prep-tfstate-${ACCOUNT_ID}"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
REPO_SLUG="${GITHUB_OWNER}/${INFRA_REPO}"

# GitHub puts numeric ids in the OIDC token subject of repos created after 15 July 2026:
#   repo:<owner>@<owner-id>/<repo>@<repo-id>:ref:refs/heads/main
# The ids never change, so a renamed or re-created repo cannot reuse these roles.
# They are read from GitHub's public API; for a private repo pass GITHUB_OWNER_ID and GITHUB_REPO_ID.
if [[ -z "${GITHUB_OWNER_ID:-}" || -z "${GITHUB_REPO_ID:-}" ]]; then
  REPO_JSON="$(curl -fsS "https://api.github.com/repos/${REPO_SLUG}")" \
    || die "could not read ${REPO_SLUG} from api.github.com (private repo? set GITHUB_OWNER_ID and GITHUB_REPO_ID)"
  GITHUB_OWNER_ID="$(python3 -c 'import json, sys; print(json.load(sys.stdin)["owner"]["id"])' <<<"${REPO_JSON}")"
  GITHUB_REPO_ID="$(python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])' <<<"${REPO_JSON}")"
fi
[[ "${GITHUB_OWNER_ID}" =~ ^[0-9]+$ && "${GITHUB_REPO_ID}" =~ ^[0-9]+$ ]] || die "GitHub owner and repo ids must be numbers"
TOKEN_SUBJECT="repo:${GITHUB_OWNER}@${GITHUB_OWNER_ID}/${INFRA_REPO}@${GITHUB_REPO_ID}"

cat <<EOF

About to bootstrap:
  AWS account     : ${ACCOUNT_ID}
  Signed in as    : ${CALLER_ARN}
  Region          : ${REGION}
  GitHub repo     : ${REPO_SLUG}
  Token subject   : ${TOKEN_SUBJECT}:...
  State bucket    : ${STATE_BUCKET}
  Plan role       : ${PLAN_ROLE}   (any branch or PR of ${REPO_SLUG}, read-only)
  Apply role      : ${APPLY_ROLE}  (only the main branch of ${REPO_SLUG})
EOF

if [[ "${1:-}" != "--yes" ]]; then
  read -r -p "Continue? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || die "aborted"
fi

# Replace __PLACEHOLDERS__ in a policy template and write it to the work dir.
render() {
  local template="$1" out="$2"
  sed -e "s|__ACCOUNT_ID__|${ACCOUNT_ID}|g" \
      -e "s|__REGION__|${REGION}|g" \
      -e "s|__REPO_SLUG__|${REPO_SLUG}|g" \
      -e "s|__TOKEN_SUBJECT__|${TOKEN_SUBJECT}|g" \
      -e "s|__STATE_BUCKET__|${STATE_BUCKET}|g" \
      "${SCRIPT_DIR}/${template}" > "${WORK_DIR}/${out}"
}

# ---------------------------------------------------------------------------
log "1/5 Terraform state bucket: ${STATE_BUCKET}"
if aws s3api head-bucket --bucket "${STATE_BUCKET}" 2>/dev/null; then
  echo "exists"
else
  aws s3api create-bucket \
    --bucket "${STATE_BUCKET}" \
    --region "${REGION}" \
    --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
  echo "created"
fi
aws s3api put-public-access-block --bucket "${STATE_BUCKET}" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-ownership-controls --bucket "${STATE_BUCKET}" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
aws s3api put-bucket-versioning --bucket "${STATE_BUCKET}" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "${STATE_BUCKET}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
render state-bucket-policy.json state-bucket-policy.json
aws s3api put-bucket-policy --bucket "${STATE_BUCKET}" \
  --policy "file://${WORK_DIR}/state-bucket-policy.json"
echo "private, versioned, encrypted, TLS-only"

# ---------------------------------------------------------------------------
log "2/5 GitHub OIDC identity provider"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_ARN}" >/dev/null 2>&1; then
  echo "exists"
  if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_ARN}" \
       --query 'ClientIDList' --output text | tr '\t' '\n' | grep -qx 'sts.amazonaws.com'; then
    aws iam add-client-id-to-open-id-connect-provider \
      --open-id-connect-provider-arn "${OIDC_ARN}" --client-id sts.amazonaws.com
    echo "added audience sts.amazonaws.com"
  fi
else
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_HOST}" \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list "${GITHUB_THUMBPRINTS[@]}" >/dev/null
  echo "created"
fi

# ---------------------------------------------------------------------------
# upsert_role <role-name> <trust-template> <permissions-template> <description>
upsert_role() {
  local role="$1" trust="$2" perms="$3" description="$4"
  render "${trust}" "${role}-trust.json"
  render "${perms}" "${role}-permissions.json"
  if aws iam get-role --role-name "${role}" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "${role}" \
      --policy-document "file://${WORK_DIR}/${role}-trust.json"
    echo "exists, trust policy updated"
  else
    aws iam create-role --role-name "${role}" \
      --description "${description}" \
      --max-session-duration 3600 \
      --assume-role-policy-document "file://${WORK_DIR}/${role}-trust.json" \
      --tags Key=project,Value=interview-prep Key=managed-by,Value=bootstrap >/dev/null
    echo "created"
  fi
  aws iam put-role-policy --role-name "${role}" \
    --policy-name "${role}" \
    --policy-document "file://${WORK_DIR}/${role}-permissions.json"
  echo "permissions policy set"
}

log "3/5 Plan role: ${PLAN_ROLE}"
upsert_role "${PLAN_ROLE}" plan-role-trust.json plan-role-permissions.json \
  "Read-only terraform plan for ${REPO_SLUG} (GitHub Actions OIDC)"

log "4/5 Apply role: ${APPLY_ROLE}"
upsert_role "${APPLY_ROLE}" apply-role-trust.json apply-role-permissions.json \
  "terraform apply for ${REPO_SLUG}, main branch only (GitHub Actions OIDC)"

# ---------------------------------------------------------------------------
log "5/5 Lightsail plans with 2 GB RAM in ${REGION} (confirm the \$12 bundle id)"
# JMESPath literals use backticks, which must not expand.
# shellcheck disable=SC2016
aws lightsail get-bundles --region "${REGION}" \
  --query 'bundles[?ramSizeInGb==`2.0` && isActive].{bundleId:bundleId,usdPerMonth:price,vcpu:cpuCount,ramGb:ramSizeInGb,diskGb:diskSizeInGb,transferGb:transferPerMonthInGb,platforms:join(`,`, supportedPlatforms)}' \
  --output table || echo "(could not list bundles; not fatal)"

cat <<EOF

Done. Now add these as repository VARIABLES (not secrets) in GitHub:
  ${REPO_SLUG} -> Settings -> Secrets and variables -> Actions -> Variables

  AWS_REGION            = ${REGION}
  TF_STATE_BUCKET       = ${STATE_BUCKET}
  AWS_PLAN_ROLE_ARN     = arn:aws:iam::${ACCOUNT_ID}:role/${PLAN_ROLE}
  AWS_APPLY_ROLE_ARN    = arn:aws:iam::${ACCOUNT_ID}:role/${APPLY_ROLE}

and this repository SECRET (Settings -> Secrets and variables -> Actions -> Secrets):

  TAILSCALE_AUTH_KEY    = a one-off, pre-approved Tailscale auth key tagged tag:interview-prep
                          (see docs/runbook.md; only used when the VM is first created)

Nothing in this output is secret.
EOF
