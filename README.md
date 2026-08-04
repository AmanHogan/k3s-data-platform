# k3s Data Platform

Bare-metal homelab running a 3-node k3s Kubernetes cluster on Proxmox VE, with a full CI/CD pipeline, public access via Cloudflare, and a growing Databricks-style data platform. Built as a learning project — every piece deployed from scratch, not managed services.
**Last updated:** 2026-08-03

## Screenshots

| Proxmox Dashboard | C4 Diagram |
|---|---|
| ![Proxmox Dashboard](docs/images/proxmox-dashboard.png) | ![C4 Diagram](docs/images/c4-diagram.png) |

## Architecture

### Physical → Cluster

```mermaid
graph TD
    subgraph Internet
        CF[Cloudflare Edge]
    end

    subgraph Home Network - 192.168.4.0/24
        ONT[Frontier ONT<br/>Fiber]
        EERO[eero Router<br/>192.168.4.1]
        SW[Netgear GS305<br/>Unmanaged Switch]

        subgraph pve1[pve1 · HP ProDesk · 192.168.4.210]
            VM1[k3s-server<br/>192.168.4.200<br/>control-plane]
        end

        subgraph pve2[pve2 · HP ProDesk · 192.168.4.211]
            VM2[k3s-agent<br/>192.168.4.201<br/>worker]
        end

        subgraph pve3[pve3 · HP EliteDesk · 192.168.4.212]
            VM3[k3s-agent-2<br/>192.168.4.202<br/>worker]
        end

        MAC[MacBook Air<br/>M-series · 24GB<br/>kubectl · Ollama · IDE]
    end

    ONT -->|WAN| EERO
    EERO -->|50ft Cat6| SW
    SW --> pve1
    SW --> pve2
    SW --> pve3
    EERO -.->|WiFi| MAC
    CF -->|Tunnel| VM1
```

### Kubernetes Services

```mermaid
graph LR
    subgraph cicd[CI/CD · cicd + argocd]
        JENKINS[Jenkins<br/>192.168.4.246]
        REG[Docker Registry<br/>192.168.4.245:5001]
        ARGO[ArgoCD]
    end

    subgraph apps[Applications]
        C4[c4-diagram<br/>Next.js + MongoDB]
        PROXVIZ[proxmox-visualizer<br/>Next.js]
    end

    subgraph data[Data Platform · data-platform]
        MINIO[MinIO<br/>S3 Object Store<br/>4 buckets · 20Gi]
    end

    subgraph infra[Infrastructure · kube-system + metallb]
        METALLB[MetalLB<br/>192.168.4.240–250]
        TRAEFIK[Traefik<br/>192.168.4.240]
        HEADLAMP[Headlamp]
        LONGHORN[Longhorn]
    end

    subgraph access[External Access]
        CFTUNNEL[Cloudflare Tunnel<br/>k3s-homelab]
        TAILSCALE[Tailscale<br/>100.x.x.x mesh]
    end

    CFTUNNEL --> C4
    CFTUNNEL --> PROXVIZ
    TAILSCALE --> JENKINS
    TAILSCALE --> ARGO
    TAILSCALE --> HEADLAMP
    TAILSCALE --> MINIO
```

### GitOps Pipeline

```mermaid
graph LR
    A[git push] --> B[Jenkins<br/>Kaniko build]
    B --> C[Push image →<br/>Registry :5001]
    C --> D[Update manifest<br/>image tag]
    D --> E[ArgoCD<br/>detects diff]
    E --> F[Pod deployed]

    style F fill:#22c55e,color:#fff,stroke:none
```

### External Access

```mermaid
graph TD
    subgraph Cloudflare[Cloudflare · Public HTTPS]
        P[proxmox.amanhogan.com]
        D[diagram.amanhogan.com]
    end

    subgraph Tunnel[cloudflared pod · outbound QUIC]
        CFD[cloudflared]
    end

    subgraph Cluster[k3s Cluster]
        PV[proxmox-visualizer:3000]
        C4D[c4-diagram:3000]
    end

    P --> CFD
    D --> CFD
    CFD --> PV
    CFD --> C4D

    subgraph Tailscale[Tailscale · Admin Only]
        TS_J[Jenkins :30300]
        TS_A[ArgoCD :30789]
        TS_H[Headlamp :32526]
        TS_M[MinIO :32000 / :32001]
    end
```

## Roadmap

```mermaid
gantt
    title Homelab Phases
    dateFormat YYYY-MM-DD
    axisFormat %b %Y

    section Foundation
    Proxmox (3 nodes)              :done, p0, 2026-06-10, 3d
    k3s cluster (3 VMs)            :done, p1, 2026-06-13, 3d
    CI/CD (Jenkins + ArgoCD)       :done, p2, 2026-06-16, 5d
    Cloudflare tunnel + domain     :done, p3, 2026-06-21, 3d

    section Applications
    tracker + c4-diagram           :done, p4a, 2026-06-24, 7d
    proxmox-visualizer             :done, p4b, 2026-07-01, 5d
    MinIO object store             :done, p5, 2026-07-06, 2d
    Network migration (apartment)  :done, nm, 2026-08-03, 1d

    section Data Platform (planned)
    Kafka (KRaft, 1 broker)        :p6, 2026-08-10, 7d
    PySpark + Delta Lake           :p7, after p6, 14d
    JupyterHub                     :p8, after p7, 7d
    MLflow + Postgres              :p9, after p8, 7d

    section AI / Learning (MacBook local)
    PySpark basics                 :active, a1, 2026-07-11, 14d
    RAG agent (LangChain/LangGraph):active, a2, 2026-07-11, 21d
    SQL assistant                  :a3, after a2, 14d
    Pipeline orchestrator agent    :a4, after a3, 14d
```

## IP Map

| Resource               | IP             | Notes                               |
| ---------------------- | -------------- | ----------------------------------- |
| eero Router            | 192.168.4.1    | Gateway + DHCP                      |
| pve1 (Proxmox)         | 192.168.4.210  | HP ProDesk, i5-7500T, 16GB          |
| pve2 (Proxmox)         | 192.168.4.211  | HP ProDesk, i5-7500T, 16GB          |
| pve3 (Proxmox)         | 192.168.4.212  | HP EliteDesk 800 G4, i5-8500T, 16GB |
| k3s-server             | 192.168.4.200  | control-plane (VM on pve1)          |
| k3s-agent              | 192.168.4.201  | worker (VM on pve2)                 |
| k3s-agent-2            | 192.168.4.202  | worker (VM on pve3)                 |
| Traefik                | 192.168.4.240  | MetalLB                             |
| Docker Registry        | 192.168.4.245  | MetalLB, HTTP (insecure, internal)  |
| Jenkins                | 192.168.4.246  | MetalLB                             |
| Tailscale (k3s-server) | 100.112.249.53 | kubectl + admin UIs                 |

## Admin Access (Tailscale only)

| Service        | URL                            |
| -------------- | ------------------------------ |
| Jenkins        | `http://100.112.249.53:30300`  |
| ArgoCD         | `https://100.112.249.53:30789` |
| Headlamp       | `http://100.112.249.53:32526`  |
| MinIO Console  | `http://100.112.249.53:32001`  |
| Proxmox (pve1) | `https://192.168.4.210:8006`   |
| Proxmox (pve2) | `https://192.168.4.211:8006`   |
| Proxmox (pve3) | `https://192.168.4.212:8006`   |

## Repo Structure

```
k3s-data-platform/
├── PLAN.md                    # detailed build plan with phases
├── docs/
│   ├── setup-log.md           # step-by-step record of everything done
│   ├── hp-node-3-thermal-fix.md
│   └── learning-path.md
├── platform/                  # infrastructure manifests
│   ├── cloudflare/
│   ├── jenkins/
│   ├── metallb/
│   ├── minio/
│   ├── mongodb/               # shared MongoDB template
│   └── registry/
├── manifests/                 # app deployment manifests (ArgoCD watches these)
│   ├── c4-diagram/
│   ├── commitments/
│   └── proxmox-visualizer/
└── argocd-apps/               # ArgoCD Application CRs
```

For the full build plan and phase details, see [PLAN.md](PLAN.md).
For the step-by-step setup log, see [docs/setup-log.md](docs/setup-log.md).
