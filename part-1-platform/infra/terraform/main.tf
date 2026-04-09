# =============================================================================
# Golden-Path Platform Infrastructure
# =============================================================================
# This Terraform configuration provisions the foundational AWS infrastructure
# for the golden-path delivery model. It is illustrative — a real deployment
# would split these resources across multiple state files and use a module
# registry, but this single file shows the full picture.
#
# Architecture:
#   VPC (3-tier) → EKS cluster → ALB + WAF → Application pods
#   Secrets Manager → External Secrets Operator → Pod env vars
#   Karpenter → autoscales nodes to match workload demand
# =============================================================================

terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
    }
  }

  # In production, use an S3 backend with DynamoDB locking.
  # backend "s3" {
  #   bucket         = "maltego-terraform-state"
  #   key            = "golden-path/terraform.tfstate"
  #   region         = "eu-central-1"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "golden-path"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}

# Data sources for account and availability zone information.
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  cluster_name = "${var.project_name}-${var.environment}"
  azs          = slice(data.aws_availability_zones.available.names, 0, 3)

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# =============================================================================
# 1. VPC — 3-tier subnet layout
# =============================================================================
# The VPC uses three tiers of subnets:
#   - Public:       NAT gateways, ALB listeners
#   - Private-App:  EKS worker nodes, application pods
#   - Private-Data: RDS, ElastiCache, and other data stores (future use)
#
# This separation enforces network-level blast-radius containment.
# =============================================================================

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.5"

  name = "${local.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs = local.azs

  # Public subnets — ALB, NAT gateways.
  public_subnets = [
    cidrsubnet(var.vpc_cidr, 4, 0),
    cidrsubnet(var.vpc_cidr, 4, 1),
    cidrsubnet(var.vpc_cidr, 4, 2),
  ]

  # Private app subnets — EKS nodes and pods.
  private_subnets = [
    cidrsubnet(var.vpc_cidr, 4, 4),
    cidrsubnet(var.vpc_cidr, 4, 5),
    cidrsubnet(var.vpc_cidr, 4, 6),
  ]

  # Private data subnets — databases, caches (isolated, no NAT egress).
  database_subnets = [
    cidrsubnet(var.vpc_cidr, 4, 8),
    cidrsubnet(var.vpc_cidr, 4, 9),
    cidrsubnet(var.vpc_cidr, 4, 10),
  ]

  # NAT gateway — single in dev, one-per-AZ in prod for HA.
  enable_nat_gateway     = true
  single_nat_gateway     = var.environment == "dev"
  one_nat_gateway_per_az = var.environment == "prod"

  # DNS support is required for EKS and VPC endpoints.
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Database subnets get their own route table (no internet egress).
  create_database_subnet_group       = true
  create_database_subnet_route_table = true

  # Tags required by the AWS Load Balancer Controller and Karpenter
  # to discover which subnets to use.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                        = 1
    "kubernetes.io/cluster/${local.cluster_name}"    = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"               = 1
    "kubernetes.io/cluster/${local.cluster_name}"    = "shared"
    "karpenter.sh/discovery"                         = local.cluster_name
  }

  tags = local.common_tags
}

# =============================================================================
# 2. EKS Cluster — Managed Kubernetes control plane + node groups
# =============================================================================
# Uses the official terraform-aws-modules/eks module. Key decisions:
#   - Managed node groups (not self-managed) for simpler patching
#   - Cluster endpoint is private+public so CI/CD can reach it via OIDC
#   - IRSA (IAM Roles for Service Accounts) is enabled by default
#   - Encryption of secrets at rest via a KMS key
# =============================================================================

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  cluster_name    = local.cluster_name
  cluster_version = var.eks_cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Allow both private (in-cluster) and public (CI/CD) access.
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # Enable IRSA — allows pods to assume IAM roles via service accounts.
  enable_irsa = true

  # Encrypt Kubernetes secrets at rest.
  cluster_encryption_config = {
    resources = ["secrets"]
  }

  # EKS-managed add-ons — ensures they stay in sync with the cluster version.
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"   # Native VPC-CNI network policy support
      })
    }
    aws-ebs-csi-driver = {
      most_recent = true
    }
  }

  # Managed node group — baseline capacity. Karpenter handles burst scaling.
  eks_managed_node_groups = {
    # General-purpose node group for platform workloads.
    general = {
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      labels = {
        role = "general"
      }

      tags = merge(local.common_tags, {
        "karpenter.sh/discovery" = local.cluster_name
      })
    }
  }

  # Allow the Karpenter controller to manage nodes.
  node_security_group_additional_rules = {
    ingress_karpenter_webhook = {
      description                   = "Karpenter webhook"
      protocol                      = "tcp"
      from_port                     = 8443
      to_port                       = 8443
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  tags = local.common_tags
}

# =============================================================================
# 3. ECR Repository — Private container registry
# =============================================================================
# Stores Docker images built by the CI/CD pipeline. Lifecycle policies
# keep the repo from growing unboundedly.
# =============================================================================

resource "aws_ecr_repository" "app" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "IMMUTABLE"   # Prevent tag overwriting for auditability

  image_scanning_configuration {
    scan_on_push = true                # Scan every pushed image for CVEs
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.common_tags
}

# Lifecycle policy: keep the last 30 tagged images, delete untagged after 7 days.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last 30 tagged images"
        selection = {
          tagStatus   = "tagged"
          tagPrefixList = [""]
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = { type = "expire" }
      }
    ]
  })
}

# =============================================================================
# 4. AWS WAF WebACL — Attached to ALB for edge protection
# =============================================================================
# Provides rate limiting and AWS Managed Rule Groups for common attack vectors
# (SQL injection, XSS, known bad inputs). The WebACL ARN is passed to the
# ALB Ingress Controller via a Kubernetes annotation.
# =============================================================================

resource "aws_wafv2_web_acl" "main" {
  name        = "${local.cluster_name}-waf"
  scope       = "REGIONAL"   # REGIONAL for ALB (CLOUDFRONT for CloudFront)
  description = "WAF WebACL for the golden-path ALB"

  default_action {
    allow {}
  }

  # Rate limiting — block IPs that exceed 2000 requests in 5 minutes.
  rule {
    name     = "rate-limit"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.cluster_name}-rate-limit"
    }
  }

  # AWS Managed Rules — Common Rule Set (covers OWASP Top 10 basics).
  rule {
    name     = "aws-managed-common"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.cluster_name}-common-rules"
    }
  }

  # AWS Managed Rules — Known Bad Inputs.
  rule {
    name     = "aws-managed-bad-inputs"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.cluster_name}-bad-inputs"
    }
  }

  # AWS Managed Rules — SQL Injection.
  rule {
    name     = "aws-managed-sqli"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesSQLiRuleSet"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.cluster_name}-sqli"
    }
  }

  visibility_config {
    sampled_requests_enabled   = true
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.cluster_name}-waf"
  }

  tags = local.common_tags
}

# =============================================================================
# 5. IAM Roles for Service Accounts (IRSA)
# =============================================================================
# IRSA allows Kubernetes pods to assume narrowly-scoped IAM roles without
# needing node-level permissions. Each controller/operator gets its own role.
# =============================================================================

# --- 5a. AWS Load Balancer Controller IRSA ---
# Allows the ALB controller to create/manage ALBs and Target Groups.

module "lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.37"

  role_name = "${local.cluster_name}-lb-controller"

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = local.common_tags
}

# --- 5b. External Secrets Operator IRSA ---
# Allows the ESO to read secrets from AWS Secrets Manager and SSM.

module "external_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.37"

  role_name = "${local.cluster_name}-external-secrets"

  attach_external_secrets_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }

  tags = local.common_tags
}

# --- 5c. Application IRSA ---
# Allows the golden-path demo app to access specific AWS resources.
# Scope this down to only the permissions the app actually needs.

module "app_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.37"

  role_name = "${local.cluster_name}-app"

  role_policy_arns = {
    secrets = aws_iam_policy.app_secrets_read.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["golden-path:golden-path-demo"]
    }
  }

  tags = local.common_tags
}

# Policy: allow the app to read its own secrets from Secrets Manager.
resource "aws_iam_policy" "app_secrets_read" {
  name        = "${local.cluster_name}-app-secrets-read"
  description = "Allow golden-path app to read its secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:golden-path/*"
      }
    ]
  })

  tags = local.common_tags
}

# =============================================================================
# 6. Karpenter — Just-in-time node provisioning
# =============================================================================
# Karpenter replaces the Cluster Autoscaler with faster, more flexible node
# provisioning. It watches for unschedulable pods and launches right-sized
# instances in seconds rather than minutes.
#
# The NodePool (v1beta1) and EC2NodeClass define what instances Karpenter can
# launch and how they are configured.
# =============================================================================

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.8"

  cluster_name = module.eks.cluster_name

  # Create the IAM role and instance profile for Karpenter-managed nodes.
  enable_irsa                     = true
  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["karpenter:karpenter"]

  # Allow Karpenter to manage node lifecycle.
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.common_tags
}

# Karpenter NodePool — defines scheduling constraints and limits.
resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1beta1"
    kind       = "NodePool"
    metadata = {
      name = "default"
    }
    spec = {
      template = {
        spec = {
          requirements = [
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "capacity-type"
              operator = "In"
              values   = var.environment == "prod" ? ["on-demand"] : ["on-demand", "spot"]
            },
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = ["c", "m", "r"]
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gte"
              values   = ["5"]
            },
          ]
          nodeClassRef = {
            apiVersion = "karpenter.k8s.aws/v1beta1"
            kind       = "EC2NodeClass"
            name       = "default"
          }
        }
      }
      limits = {
        cpu    = var.karpenter_cpu_limit
        memory = var.karpenter_memory_limit
      }
      disruption = {
        consolidationPolicy = "WhenUnderutilized"
        expireAfter         = "720h"   # Rotate nodes every 30 days
      }
    }
  })

  depends_on = [module.karpenter]
}

# Karpenter EC2NodeClass — defines AMI, security groups, subnets for nodes.
resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1beta1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "default"
    }
    spec = {
      amiFamily = "AL2"
      role      = module.karpenter.node_iam_role_name
      subnetSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.cluster_name
          }
        }
      ]
      securityGroupSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.cluster_name
          }
        }
      ]
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = "100Gi"
            volumeType          = "gp3"
            encrypted           = true
            deleteOnTermination = true
          }
        }
      ]
    }
  })

  depends_on = [module.karpenter]
}
