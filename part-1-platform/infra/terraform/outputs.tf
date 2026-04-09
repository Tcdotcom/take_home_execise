# =============================================================================
# Outputs — Golden-Path Platform Infrastructure
# =============================================================================
# These outputs are consumed by the CI/CD pipeline and by downstream
# Terraform configurations (e.g. per-team app modules).
# =============================================================================

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority" {
  description = "Base64-encoded CA certificate for the EKS cluster"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA"
  value       = module.eks.oidc_provider_arn
}

output "ecr_repository_url" {
  description = "ECR repository URL for Docker images"
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_repository_arn" {
  description = "ECR repository ARN"
  value       = aws_ecr_repository.app.arn
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private (app-tier) subnet IDs"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnets
}

output "database_subnet_ids" {
  description = "Database (data-tier) subnet IDs"
  value       = module.vpc.database_subnets
}

output "waf_web_acl_arn" {
  description = "WAF WebACL ARN to attach to ALB via ingress annotation"
  value       = aws_wafv2_web_acl.main.arn
}

output "lb_controller_role_arn" {
  description = "IAM role ARN for the AWS Load Balancer Controller"
  value       = module.lb_controller_irsa.iam_role_arn
}

output "external_secrets_role_arn" {
  description = "IAM role ARN for the External Secrets Operator"
  value       = module.external_secrets_irsa.iam_role_arn
}

output "app_role_arn" {
  description = "IAM role ARN for the golden-path application"
  value       = module.app_irsa.iam_role_arn
}
