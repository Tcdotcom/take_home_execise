# Senior DevOps Engineer — Take-Home Exercise

## Repository Structure

```
.
├── README.md                    ← You are here
├── part-1-platform/             ← Platform implementation: golden-path delivery on K8s
├── part-2-system-design/        ← System design: Automated Canary Analysis at scale
├── part-3-python-cli/           ← Python CLI: application registry with env overrides
└── diagrams/                    ← Supplementary architecture diagrams
```

## Part 1 — Platform Implementation: Application Delivery on Kubernetes

**Goal:** Demonstrate a golden-path from source code to deployment on AWS EKS.

**What's included:**
- Demo Go HTTP service with distroless container image
- GitHub Actions CI/CD pipeline (lint → test → scan → build → deploy)
- Terraform for AWS infrastructure (VPC, EKS, WAF, ECR, IRSA)
- Helm chart as the reusable golden-path template
- External Secrets Operator integration for secret management
- HPA + Karpenter for pod/node autoscaling
- ALB Ingress with WAF protection
- 3-tier architecture (public ALB → private app → private data)

→ See [part-1-platform/README.md](part-1-platform/README.md)

## Part 2 — System Design: Centralized Automated Canary Analysis

**Goal:** Design a centralized ACA system for safe, progressive deployments across 500+ microservices in 3 global regions.

**What's included:**
- Control plane / data plane architecture
- Rollout policy engine with GitOps storage
- Canary traffic routing via Istio + Prometheus metrics
- Decision engine (continue/pause/rollback/abort)
- Multi-region deployment with failure isolation
- ELK stack observability integration
- Security, RBAC, and audit logging
- Phased rollout plan (MVP → scale)
- Optional AI/LLM-assisted capabilities

→ See [part-2-system-design/README.md](part-2-system-design/README.md)

## Part 3 — Python CLI: Application Registry and Environment Overrides

**Goal:** CLI tool for managing application configs with per-environment overrides.

**What's included:**
- `click`-based CLI with register, config set/get/diff, export, delete commands
- YAML-backed storage (one file per app)
- Defaults + environment override resolution
- Value coercion, validation, error handling
- 23 unit tests (all passing)

**Quick start:**
```bash
cd part-3-python-cli
pip install click pyyaml pytest
python -m appreg.cli register my-service --team platform --description "Demo service"
python -m appreg.cli config set my-service --key replicas --value 2
python -m appreg.cli config set my-service --key replicas --value 5 --env prod
python -m appreg.cli config get my-service --env prod
```

→ See [part-3-python-cli/README.md](part-3-python-cli/README.md)

---

## What I Implemented

| Area | Scope |
|------|-------|
| Part 1 | Full golden-path artifacts: app, Dockerfile, CI/CD, Terraform, Helm chart, docs |
| Part 2 | Comprehensive design document with architecture diagrams and phased rollout |
| Part 3 | Working CLI with tests, validation, env diff, export, and sample data |

## What I Intentionally Left Out

- **Running infrastructure** — Terraform and Helm are illustrative; no live AWS resources
- **Progressive delivery implementation** — Documented in Part 2 design; Part 1 shows standard Helm deploy
- **Deep-merge config** — Part 3 uses flat key override (simpler, more predictable)
- **Authentication/RBAC** — CLI is local-only; noted as production next step

## What I Would Do Next

- Add Argo Rollouts manifests to Part 1 for canary deployment demo
- Build a Backstage template wrapping the golden-path Helm chart
- Add `bulk import` and `render` commands to the CLI
- Create a live demo recording walking through each part
- Add integration tests for the CI/CD pipeline
- Implement cost tagging in Terraform resources
