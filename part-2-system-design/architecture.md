# ACA System Architecture Diagrams

This document contains the key Mermaid diagrams for the Centralized Automated Canary Analysis (ACA) system. Each diagram is accompanied by a brief description of what it illustrates.

---

## 1. High-Level Architecture Diagram

This diagram shows the overall system architecture with the Control Plane (management cluster) and three regional Data Planes. The Control Plane houses the Policy Engine, Analysis Engine, and Decision Engine. Each Data Plane contains a Rollout Controller, Metrics Collector, and Gateway Controller (Istio). Communication between planes uses gRPC with mTLS.

```mermaid
graph TB
    subgraph "Control Plane (Management Cluster)"
        API[ACA API Server]
        PE[Policy Engine]
        AE[Analysis Engine]
        DE[Decision Engine]
        DB[(Policy Store<br/>PostgreSQL)]
        ES[(Elasticsearch<br/>Audit & Events)]
        Dashboard[Web Dashboard]
        GitSync[GitOps Sync<br/>Controller]

        API --> PE
        API --> DE
        PE --> DB
        AE --> DE
        DE --> API
        API --> ES
        Dashboard --> API
        GitSync --> PE
    end

    subgraph "Data Plane — US Region"
        RC_US[Rollout Controller]
        MC_US[Metrics Collector]
        GW_US[Gateway Controller<br/>Istio]
        PROM_US[(Prometheus)]
        K8S_US[Kubernetes Cluster]

        RC_US --> GW_US
        MC_US --> PROM_US
        GW_US --> K8S_US
    end

    subgraph "Data Plane — EU Region"
        RC_EU[Rollout Controller]
        MC_EU[Metrics Collector]
        GW_EU[Gateway Controller<br/>Istio]
        PROM_EU[(Prometheus)]
        K8S_EU[Kubernetes Cluster]

        RC_EU --> GW_EU
        MC_EU --> PROM_EU
        GW_EU --> K8S_EU
    end

    subgraph "Data Plane — Asia Region"
        RC_ASIA[Rollout Controller]
        MC_ASIA[Metrics Collector]
        GW_ASIA[Gateway Controller<br/>Istio]
        PROM_ASIA[(Prometheus)]
        K8S_ASIA[Kubernetes Cluster]

        RC_ASIA --> GW_ASIA
        MC_ASIA --> PROM_ASIA
        GW_ASIA --> K8S_ASIA
    end

    Git[(Git Repository<br/>Rollout Policies)] --> GitSync

    DE -- "gRPC + mTLS" --> RC_US
    DE -- "gRPC + mTLS" --> RC_EU
    DE -- "gRPC + mTLS" --> RC_ASIA

    MC_US -- "gRPC + mTLS" --> AE
    MC_EU -- "gRPC + mTLS" --> AE
    MC_ASIA -- "gRPC + mTLS" --> AE
```

---

## 2. Rollout Sequence Diagram

This diagram traces the lifecycle of a single canary deployment from the developer pushing a new image tag through to either promotion or rollback. It shows how the Control Plane orchestrates the process while the Data Plane executes traffic shifts and metric collection.

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant Git as Git Repo
    participant CP as Control Plane
    participant PE as Policy Engine
    participant RC as Rollout Controller
    participant Istio as Istio Gateway
    participant Prom as Prometheus
    participant AE as Analysis Engine
    participant DE as Decision Engine
    participant Slack as Slack

    Dev->>Git: Push new image tag
    Git->>CP: GitOps webhook triggers sync
    CP->>PE: Validate rollout policy
    PE-->>CP: Policy valid

    CP->>Slack: Notify: "Rollout started for payments-service v2.3.1"
    CP->>RC: Initiate canary rollout (Step 1: 5%)

    RC->>Istio: Update VirtualService weights (95/5)
    Istio-->>RC: Weights applied

    loop Every analysis interval (60s)
        RC->>Prom: Scrape canary metrics
        RC->>Prom: Scrape baseline metrics
        Prom-->>AE: Canary metrics (error rate, latency, throughput)
        Prom-->>AE: Baseline metrics
        AE->>AE: Statistical comparison (Mann-Whitney U, Fisher's exact)
        AE->>DE: Analysis result (pass/fail/inconclusive)
    end

    alt Analysis passes for Step 1
        DE->>CP: Decision: advance to Step 2
        CP->>RC: Set weight to 20%
        RC->>Istio: Update VirtualService weights (80/20)
        CP->>Slack: Notify: "Canary at 20%, metrics healthy"
    else Analysis fails (3 consecutive failures)
        DE->>CP: Decision: rollback
        CP->>RC: Rollback to stable
        RC->>Istio: Set weight to 0% canary
        CP->>Slack: Alert: "Rollback triggered — p99 latency exceeded threshold"
    end

    Note over CP,RC: Steps repeat: 20% → 50% → 100%

    CP->>RC: Final promotion (100% traffic to new version)
    RC->>Istio: Remove canary, promote stable
    CP->>Slack: Notify: "Rollout complete for payments-service v2.3.1"
    CP->>DE: Log rollout decision history to Elasticsearch
```

---

## 3. Decision Engine Flowchart

This diagram details the logic the Decision Engine follows at each analysis interval. Starting from metric collection, it evaluates metric availability, runs statistical comparisons, and determines the appropriate action: advance, wait, pause, or rollback.

```mermaid
flowchart TD
    A[New Analysis Interval] --> B{Collect Metrics<br/>Canary & Baseline}
    B --> C{All Metrics<br/>Available?}
    C -- No --> D{Missing for<br/>> 5 min?}
    D -- Yes --> E[PAUSE Rollout<br/>Alert: Missing Metrics]
    D -- No --> A
    C -- Yes --> F[Run Statistical<br/>Comparison]
    F --> G{Any Critical<br/>Metric FAIL?}
    G -- Yes --> H[Increment Failure<br/>Counter]
    H --> I{Failure Count<br/>>= maxFailed?}
    I -- Yes --> J[ROLLBACK<br/>Restore 100% to stable]
    I -- No --> K[WAIT<br/>Retry next interval]
    G -- No --> L{All Metrics<br/>PASS?}
    L -- Yes --> M[Reset Failure Counter]
    M --> N{Current Step =<br/>Final Step?}
    N -- Yes --> O{Approval Gate<br/>Required?}
    O -- Yes --> P[PAUSE<br/>Await Manual Approval]
    O -- No --> Q[PROMOTE<br/>100% traffic to canary]
    N -- No --> R[ADVANCE<br/>to next weight step]
    L -- No --> S[INCONCLUSIVE<br/>Wait, retry next interval]

    J --> T[Log Decision +<br/>Notify Team]
    Q --> T
    R --> T
    E --> T
    P --> T

    style J fill:#f55,stroke:#333,color:#fff
    style Q fill:#5b5,stroke:#333,color:#fff
    style R fill:#59f,stroke:#333,color:#fff
    style E fill:#fa0,stroke:#333,color:#fff
    style P fill:#fa0,stroke:#333,color:#fff
```

---

## 4. Multi-Region Topology

This diagram shows how deployments flow sequentially across regions (us-dev first, then eu-prod, us-prod, and asia-prod). Each region has its own Rollout Controller and Prometheus instance as independent failure domains. The Control Plane orchestrates the sequence and collects metrics from all regions.

```mermaid
graph TB
    subgraph "Control Plane (Management Cluster — US-Central)"
        CP_API[ACA API Server<br/>Leader + 2 Replicas]
        CP_DE[Decision Engine]
        CP_AE[Analysis Engine]
        CP_DB[(PostgreSQL<br/>Multi-AZ)]
        CP_ES[(Elasticsearch<br/>Cluster)]

        CP_API --> CP_DE
        CP_API --> CP_AE
        CP_API --> CP_DB
        CP_API --> CP_ES
    end

    subgraph "US Region"
        subgraph "us-dev (Non-Prod)"
            US_DEV_RC[Rollout Controller]
            US_DEV_K8S[K8s Cluster]
            US_DEV_RC --> US_DEV_K8S
        end
        subgraph "us-prod (Production)"
            US_PROD_RC[Rollout Controller]
            US_PROD_K8S[K8s Cluster]
            US_PROD_PROM[(Prometheus)]
            US_PROD_RC --> US_PROD_K8S
            US_PROD_K8S --> US_PROD_PROM
        end
    end

    subgraph "EU Region"
        subgraph "eu-prod (Production)"
            EU_PROD_RC[Rollout Controller]
            EU_PROD_K8S[K8s Cluster]
            EU_PROD_PROM[(Prometheus)]
            EU_PROD_RC --> EU_PROD_K8S
            EU_PROD_K8S --> EU_PROD_PROM
        end
    end

    subgraph "Asia Region"
        subgraph "asia-prod (Production)"
            ASIA_PROD_RC[Rollout Controller]
            ASIA_PROD_K8S[K8s Cluster]
            ASIA_PROD_PROM[(Prometheus)]
            ASIA_PROD_RC --> ASIA_PROD_K8S
            ASIA_PROD_K8S --> ASIA_PROD_PROM
        end
    end

    CP_DE -- "1. Deploy to us-dev" --> US_DEV_RC
    CP_DE -- "2. Deploy to eu-prod" --> EU_PROD_RC
    CP_DE -- "3. Deploy to us-prod" --> US_PROD_RC
    CP_DE -- "4. Deploy to asia-prod" --> ASIA_PROD_RC

    US_PROD_PROM -- "Metrics" --> CP_AE
    EU_PROD_PROM -- "Metrics" --> CP_AE
    ASIA_PROD_PROM -- "Metrics" --> CP_AE

    style CP_API fill:#36f,stroke:#333,color:#fff
    style CP_DE fill:#36f,stroke:#333,color:#fff
```
