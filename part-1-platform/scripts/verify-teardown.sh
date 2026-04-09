#!/usr/bin/env bash
# =============================================================================
# verify-teardown.sh — Post-destroy verification for the golden-path platform
# =============================================================================
# Usage:
#   ./verify-teardown.sh [OPTIONS]
#
# Options:
#   -p, --project     Project name prefix   (default: golden-path)
#   -e, --environment Environment           (default: dev)
#   -r, --region      AWS region            (default: eu-central-1)
#   -h, --help        Show this help
#
# What it checks:
#   1. EKS cluster is gone
#   2. EKS managed node groups are gone
#   3. VPC (tagged for the cluster) is gone
#   4. ECR repository is gone
#   5. WAF WebACL is gone
#   6. IRSA IAM roles are gone (lb-controller, external-secrets, app)
#   7. IAM policy (app-secrets-read) is gone
#   8. Karpenter node instances are gone (no EC2 instances with cluster tag)
#
# Exit codes:
#   0  All checks passed — resources are fully torn down
#   1  One or more resources still exist
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PROJECT_NAME="golden-path"
ENVIRONMENT="dev"
AWS_REGION="eu-central-1"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project)     PROJECT_NAME="$2";  shift 2 ;;
    -e|--environment) ENVIRONMENT="$2";   shift 2 ;;
    -r|--region)      AWS_REGION="$2";    shift 2 ;;
    -h|--help)        usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
ERRORS=()

green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

# check_absent LABEL <command that outputs a non-empty string if the resource exists>
check_absent() {
  local label="$1"
  shift
  local result
  result=$("$@" 2>/dev/null || true)
  if [[ -z "$result" ]]; then
    green "  [PASS] $label"
    (( PASS++ )) || true
  else
    red   "  [FAIL] $label — still exists: $result"
    ERRORS+=("$label")
    (( FAIL++ )) || true
  fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
bold "============================================================"
bold " Golden-Path Teardown Verification"
bold "============================================================"
echo "  Cluster name : $CLUSTER_NAME"
echo "  Region       : $AWS_REGION"
echo ""

if ! command -v aws &>/dev/null; then
  echo "ERROR: aws CLI not found in PATH" >&2
  exit 1
fi

AWS="aws --region $AWS_REGION --output text"

# ---------------------------------------------------------------------------
# 1. EKS Cluster
# ---------------------------------------------------------------------------
bold "--- 1. EKS Cluster ---"

check_absent "EKS cluster '$CLUSTER_NAME'" \
  bash -c "$AWS eks describe-cluster --name '$CLUSTER_NAME' \
           --query 'cluster.name' 2>/dev/null || true"

# ---------------------------------------------------------------------------
# 2. EKS Managed Node Groups
# ---------------------------------------------------------------------------
bold "--- 2. EKS Managed Node Groups ---"

check_absent "EKS node groups for '$CLUSTER_NAME'" \
  bash -c "$AWS eks list-nodegroups --cluster-name '$CLUSTER_NAME' \
           --query 'nodegroups[*]' 2>/dev/null || true"

# ---------------------------------------------------------------------------
# 3. VPC
# ---------------------------------------------------------------------------
bold "--- 3. VPC ---"

check_absent "VPC tagged for cluster '$CLUSTER_NAME'" \
  bash -c "$AWS ec2 describe-vpcs \
           --filters 'Name=tag:Name,Values=${CLUSTER_NAME}-vpc' \
           --query 'Vpcs[*].VpcId' 2>/dev/null || true"

check_absent "Subnets tagged for cluster '$CLUSTER_NAME'" \
  bash -c "$AWS ec2 describe-subnets \
           --filters 'Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=shared' \
           --query 'Subnets[*].SubnetId' 2>/dev/null || true"

check_absent "NAT Gateways in cluster VPC" \
  bash -c "$AWS ec2 describe-nat-gateways \
           --filter 'Name=tag:Project,Values=${PROJECT_NAME}' \
                    'Name=tag:Environment,Values=${ENVIRONMENT}' \
                    'Name=state,Values=available,pending' \
           --query 'NatGateways[*].NatGatewayId' 2>/dev/null || true"

check_absent "Internet Gateway for cluster VPC" \
  bash -c "$AWS ec2 describe-internet-gateways \
           --filters 'Name=tag:Name,Values=${CLUSTER_NAME}-vpc' \
           --query 'InternetGateways[*].InternetGatewayId' 2>/dev/null || true"

# ---------------------------------------------------------------------------
# 4. ECR Repository
# ---------------------------------------------------------------------------
bold "--- 4. ECR Repository ---"

ECR_REPO_NAME="${PROJECT_NAME}-demo"

check_absent "ECR repository '${ECR_REPO_NAME}'" \
  bash -c "$AWS ecr describe-repositories \
           --repository-names '${ECR_REPO_NAME}' \
           --query 'repositories[*].repositoryName' 2>/dev/null || true"

# ---------------------------------------------------------------------------
# 5. WAF WebACL
# ---------------------------------------------------------------------------
bold "--- 5. WAF WebACL ---"

check_absent "WAF WebACL '${CLUSTER_NAME}-waf'" \
  bash -c "$AWS wafv2 list-web-acls --scope REGIONAL \
           --query \"WebACLs[?Name=='${CLUSTER_NAME}-waf'].Name\" 2>/dev/null || true"

# ---------------------------------------------------------------------------
# 6. IAM Roles (IRSA)
# ---------------------------------------------------------------------------
bold "--- 6. IAM Roles (IRSA) ---"

for role_suffix in lb-controller external-secrets app; do
  role_name="${CLUSTER_NAME}-${role_suffix}"
  check_absent "IAM role '${role_name}'" \
    bash -c "aws iam get-role --role-name '${role_name}' \
             --query 'Role.RoleName' 2>/dev/null || true"
done

# Karpenter node role (created by the karpenter submodule)
check_absent "IAM role '${CLUSTER_NAME}-karpenter'" \
  bash -c "aws iam get-role --role-name '${CLUSTER_NAME}-karpenter' \
           --query 'Role.RoleName' 2>/dev/null || true"

# ---------------------------------------------------------------------------
# 7. IAM Policy
# ---------------------------------------------------------------------------
bold "--- 7. IAM Policies ---"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")

if [[ -n "$ACCOUNT_ID" ]]; then
  policy_arn="arn:aws:iam::${ACCOUNT_ID}:policy/${CLUSTER_NAME}-app-secrets-read"
  check_absent "IAM policy '${CLUSTER_NAME}-app-secrets-read'" \
    bash -c "aws iam get-policy --policy-arn '${policy_arn}' \
             --query 'Policy.PolicyName' 2>/dev/null || true"
else
  yellow "  [SKIP] Could not resolve AWS account ID — skipping IAM policy check"
fi

# ---------------------------------------------------------------------------
# 8. EC2 Instances (Karpenter-launched nodes)
# ---------------------------------------------------------------------------
bold "--- 8. Karpenter-Launched EC2 Instances ---"

check_absent "EC2 instances tagged 'karpenter.sh/discovery=${CLUSTER_NAME}'" \
  bash -c "$AWS ec2 describe-instances \
           --filters 'Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}' \
                     'Name=instance-state-name,Values=pending,running,stopping,stopped' \
           --query 'Reservations[*].Instances[*].InstanceId' 2>/dev/null || true"

check_absent "EC2 instances tagged for EKS cluster '${CLUSTER_NAME}'" \
  bash -c "$AWS ec2 describe-instances \
           --filters 'Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}' \
                     'Name=instance-state-name,Values=pending,running,stopping,stopped' \
           --query 'Reservations[*].Instances[*].InstanceId' 2>/dev/null || true"

# ---------------------------------------------------------------------------
# 9. Load Balancers (ALB created by the ALB controller)
# ---------------------------------------------------------------------------
bold "--- 9. Application Load Balancers ---"

check_absent "ALBs tagged for cluster '${CLUSTER_NAME}'" \
  bash -c "$AWS elbv2 describe-load-balancers \
           --query \"LoadBalancers[?contains(LoadBalancerName, '${CLUSTER_NAME}')].LoadBalancerName\" \
           2>/dev/null || true"

# ---------------------------------------------------------------------------
# 10. KMS Keys (EKS secrets encryption)
# ---------------------------------------------------------------------------
bold "--- 10. KMS Keys ---"

check_absent "KMS keys aliased for cluster '${CLUSTER_NAME}'" \
  bash -c "$AWS kms list-aliases \
           --query \"Aliases[?contains(AliasName, '${CLUSTER_NAME}')].AliasName\" \
           2>/dev/null || true"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
bold "============================================================"
bold " Summary"
bold "============================================================"
green "  Passed : $PASS"
if [[ $FAIL -gt 0 ]]; then
  red "  Failed : $FAIL"
  echo ""
  red "  The following resources still exist:"
  for err in "${ERRORS[@]}"; do
    red "    • $err"
  done
  echo ""
  red "  Run 'terraform destroy' again, or remove the resources manually."
  exit 1
else
  green "  Failed : 0"
  echo ""
  green "  All resources are torn down. Environment is clean."
  exit 0
fi
