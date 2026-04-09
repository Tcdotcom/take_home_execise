# Part 1 -- Golden-Path Platform for AWS EKS

A production-ready, opinionated delivery model that gives application teams a paved road from source code to a secured, observable, autoscaling deployment on AWS EKS.

---

## What Is Included

```
part-1-platform/
├── app/                          # Demo Go application
│   ├── main.go                   # HTTP service (/health, /ready, /)
│   ├── go.mod                    # Go module definition
│   └── Dockerfile                # Multi-stage build (distroless runtime)
│
├── ci/.github/workflows/
│   └── ci-cd.yaml                # GitHub Actions pipeline (lint, test, build, scan, deploy)
│
├── infra/
│   ├── terraform/
│   │   ├── main.tf               # VPC, EKS, ECR, WAF, IRSA, Karpenter
│   │   ├── variables.tf          # Input variables with defaults
│   │   └── outputs.tf            # Key outputs (cluster endpoint, ECR URL, etc.)
│   │
│   └── helm/golden-path/
│       ├── Chart.yaml            # Chart metadata
│       ├── values.yaml           # Default values
│       ├── values-dev.yaml       # Dev overrides
│       ├── values-staging.yaml   # Staging overrides
│       ├── values-prod.yaml      # Prod overrides
│       └── templates/
│           ├── _helpers.tpl      # Template helpers
│           ├── deployment.yaml   # Deployment with security context, probes, anti-affinity
│           ├── service.yaml      # ClusterIP service
│           ├── ingress.yaml      # ALB Ingress with WAF annotation
│           ├── hpa.yaml          # HorizontalPodAutoscaler
│           ├── networkpolicy.yaml # Deny-all + allow ingress controller
│           ├── serviceaccount.yaml # IRSA-annotated ServiceAccount
│           ├── external-secret.yaml # ExternalSecret (AWS Secrets Manager)
│           └── servicemonitor.yaml  # Prometheus ServiceMonitor
│
├── docs/
│   └── architecture.md           # Detailed architecture documentation
│
└── README.md                     # This file
```

---

## Key Design Decisions

| Area | Decision | Rationale |
|------|----------|-----------|
| **Base image** | `gcr.io/distroless/static-debian12:nonroot` | No shell, no package manager -- minimal attack surface |
| **Security** | Non-root UID 65532, read-only rootfs, all capabilities dropped | Defence in depth at the container level |
| **Networking** | 3-tier VPC (public, private-app, private-data) | Blast-radius containment via network isolation |
| **Secrets** | External Secrets Operator + AWS Secrets Manager | Secrets never stored in Git; automatic rotation |
| **IAM** | IRSA (IAM Roles for Service Accounts) | Least-privilege per pod, no node-level IAM blast radius |
| **Autoscaling** | HPA (pods) + Karpenter (nodes) | Fast, right-sized scaling at both layers |
| **Edge security** | AWS WAF on ALB | Rate limiting + OWASP managed rules without app changes |
| **CI/CD** | GitHub Actions with OIDC federation | No long-lived AWS credentials; reusable workflow pattern |
| **Scanning** | Trivy in pipeline + ECR scan-on-push | Catch CVEs before they reach any cluster |

---

## Prerequisites

- **AWS account** with permissions to create VPC, EKS, ECR, WAF, IAM resources
- **Terraform** >= 1.7
- **kubectl** configured for your cluster
- **Helm** >= 3.14
- **Docker** (for local image builds)
- **Go** >= 1.22 (for local development)
- **GitHub** repository with Environments configured (dev, staging, production)

---

## Getting Started

### 1. Provision Infrastructure

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # Edit with your values
terraform init
terraform plan
terraform apply
```

### 2. Build and Push the Container

```bash
cd app
docker build -t golden-path-demo:local .

# Tag and push to ECR (after terraform apply provides the ECR URL)
aws ecr get-login-password --region eu-central-1 | \
  docker login --username AWS --password-stdin <ECR_URL>
docker tag golden-path-demo:local <ECR_URL>:latest
docker push <ECR_URL>:latest
```

### 3. Deploy with Helm

```bash
cd infra/helm/golden-path

# Dev
helm upgrade --install golden-path-demo . \
  -f values.yaml -f values-dev.yaml \
  --namespace golden-path --create-namespace

# Prod
helm upgrade --install golden-path-demo . \
  -f values.yaml -f values-prod.yaml \
  --namespace golden-path --create-namespace
```

### 4. Verify

```bash
kubectl -n golden-path get pods
kubectl -n golden-path get ingress
curl https://app.dev.example.com/health
```

---

## CI/CD Pipeline

The pipeline runs automatically on push to `main`:

1. **Lint** -- golangci-lint static analysis
2. **Test** -- `go test -race` with coverage
3. **Build** -- Multi-stage Docker build, push to ECR
4. **Scan** -- Trivy blocks CRITICAL/HIGH CVEs
5. **Deploy Dev** -- Automatic
6. **Deploy Staging** -- Manual approval via GitHub Environment
7. **Deploy Prod** -- Manual approval via GitHub Environment

Teams can call this pipeline from their own repos using the `workflow_call` trigger.

---

## Environment Differences

| Setting | Dev | Staging | Prod |
|---------|-----|---------|------|
| Replicas | 1 | 2 | 3+ (HPA up to 20) |
| Log level | debug | info | warn |
| Resources | Relaxed | Moderate | Strict |
| WAF | Disabled | Enabled | Enabled |
| HPA | Disabled | Enabled | Enabled |
| Spot instances | Allowed | Allowed | On-demand only |

---

## Documentation

See [docs/architecture.md](docs/architecture.md) for:
- Network architecture diagrams
- Golden-path delivery flow
- Secret management approach
- Autoscaling strategy (HPA + Karpenter)
- WAF/Ingress pattern
- How teams adopt the golden path
- Assumptions, tradeoffs, and next steps
