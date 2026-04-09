# =============================================================================
# Variables — Golden-Path Platform Infrastructure
# =============================================================================
# Sensible defaults are provided for a dev environment. Override via
# terraform.tfvars or -var flags for staging/production.
# =============================================================================

# --- General ---

variable "project_name" {
  description = "Project name used as a prefix for all resources"
  type        = string
  default     = "golden-path"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-central-1"
}

# --- VPC ---

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

# --- EKS ---

variable "eks_cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.29"
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group"
  type        = list(string)
  default     = ["m6i.large", "m6i.xlarge"]
}

variable "node_min_size" {
  description = "Minimum number of nodes in the managed node group"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of nodes in the managed node group"
  type        = number
  default     = 10
}

variable "node_desired_size" {
  description = "Desired number of nodes in the managed node group"
  type        = number
  default     = 3
}

# --- ECR ---

variable "ecr_repository_name" {
  description = "Name of the ECR repository for the application image"
  type        = string
  default     = "golden-path-demo"
}

# --- Karpenter ---

variable "karpenter_cpu_limit" {
  description = "Maximum total vCPUs Karpenter can provision"
  type        = string
  default     = "100"
}

variable "karpenter_memory_limit" {
  description = "Maximum total memory Karpenter can provision"
  type        = string
  default     = "400Gi"
}
