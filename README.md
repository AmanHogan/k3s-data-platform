# k3s Data Platform

Bare-metal homelab running a 3-node k3s Kubernetes cluster on Proxmox VE, with a full CI/CD pipeline, public access via Cloudflare, and a growing Databricks-style data platform. Built as a learning project — every piece deployed from scratch, not managed services.
**Last updated:** 2026-08-14

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
        SPARK[Spark 3.5 Cluster<br/>master + worker]
        THRIFT[Spark Thrift Server<br/>SQL endpoint :30100]
        JUPYTER[JupyterHub<br/>PySpark notebooks]
        PG[PostgreSQL 16<br/>metastore + airflow + mlflow]
        AIRFLOW[Airflow 2.10<br/>orchestration]
    end

    THRIFT --> SPARK
    JUPYTER --> SPARK
    THRIFT --> PG
    AIRFLOW --> PG
    SPARK --> MINIO

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

    section Data Platform
    Spark cluster + JupyterHub     :done, p6, 2026-08-10, 3d
    Postgres + Thrift SQL endpoint :done, p7, 2026-08-13, 2d
    Airflow orchestration          :done, p8, 2026-08-13, 2d
    Databricks-style UI (Next.js)  :active, p9, 2026-08-15, 14d
    MLflow model registry          :p10, after p9, 7d
    Kafka (KRaft, 1 broker)        :p11, after p10, 7d

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
| JupyterHub     | `http://100.112.249.53:30888`  |
| Spark UI       | `http://100.112.249.53:30808`  |
| Spark SQL JDBC | `jdbc:hive2://100.112.249.53:30100` |
| Airflow        | `http://100.112.249.53:30880`  |
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
│   ├── airflow/               # orchestration (LocalExecutor + Postgres)
│   ├── cloudflare/
│   ├── jenkins/
│   ├── jupyterhub/            # PySpark notebooks
│   ├── metallb/
│   ├── minio/
│   ├── mongodb/               # shared MongoDB template
│   ├── postgres/              # shared DB: hive_metastore, airflow, mlflow
│   ├── registry/
│   ├── spark/                 # Spark master + worker
│   └── spark-thrift/          # HiveServer2-compatible SQL endpoint
├── manifests/                 # app deployment manifests (ArgoCD watches these)
│   ├── c4-diagram/
│   ├── commitments/
│   └── proxmox-visualizer/
└── argocd-apps/               # ArgoCD Application CRs
```

## Cloud Equivalent — "What This Would Look Like in Production"

This homelab maps directly to a production AWS architecture. The diagram below shows how each homelab component translates to its cloud-native equivalent, with the security and networking layers you'd add in a real enterprise deployment.

### Homelab → AWS Mapping

| Homelab Component | AWS Equivalent | Why |
|---|---|---|
| Proxmox VE (hypervisor) | EC2 / EKS managed nodes | AWS manages the hypervisor layer |
| k3s cluster | **EKS** (Elastic Kubernetes Service) | Managed control plane, no etcd to maintain |
| MetalLB | **AWS Load Balancer Controller** + ALB/NLB | Cloud-native L4/L7 load balancing |
| Traefik ingress | **ALB Ingress Controller** or **NGINX Ingress** | ALB handles TLS termination, path routing |
| Cloudflare Tunnel | **CloudFront** (CDN) + **WAF** | Edge caching + DDoS/bot protection |
| Cloudflare Access (email gate) | **Cognito** or **ALB + OIDC** | Identity-aware access control |
| Tailscale (admin access) | **Systems Manager Session Manager** or VPN | No inbound ports needed for admin |
| Docker Registry (in-cluster) | **ECR** (Elastic Container Registry) | Managed, no storage to maintain |
| Jenkins + Kaniko | **CodePipeline + CodeBuild** (or keep Jenkins on EKS) | Managed CI/CD, pay-per-build |
| ArgoCD | **ArgoCD on EKS** or **Flux** | GitOps works the same in cloud |
| MinIO | **S3** | MinIO is literally an S3-compatible API |
| MongoDB (local) | **DocumentDB** or **MongoDB Atlas** | Managed backups, replicas, patching |
| Longhorn (storage) | **EBS** (block) / **EFS** (shared) | CSI drivers, no local-path provisioner |
| local-path-provisioner | **EBS CSI Driver** | Dynamic PV provisioning |

### AWS Production Architecture

```mermaid
graph TD
    subgraph Internet
        USER[Users]
    end

    subgraph Edge[AWS Edge / Global]
        R53[Route 53<br/>DNS]
        CF[CloudFront<br/>CDN + Cache]
        WAF[AWS WAF<br/>Rate limiting · Bot protection<br/>SQL injection · XSS filtering]
    end

    subgraph VPC["VPC · 10.0.0.0/16"]

        subgraph Public["Public Subnets · 10.0.1.0/24, 10.0.2.0/24"]
            ALB[Application Load Balancer<br/>TLS termination · Path routing]
            NAT[NAT Gateway<br/>Outbound for private subnets]
            BASTION[Bastion / SSM<br/>Admin access]
        end

        subgraph Private["Private Subnets · 10.0.10.0/24, 10.0.11.0/24"]
            subgraph EKS[EKS Cluster]
                ING[NGINX Ingress Controller<br/>or ALB Ingress Controller]
                APP1[proxmox-visualizer<br/>Pod]
                APP2[c4-diagram<br/>Pod]
                ARGO[ArgoCD<br/>Pod]
                JENKINS[Jenkins<br/>Pod]
            end
        end

        subgraph Data["Data Subnets · 10.0.20.0/24, 10.0.21.0/24"]
            RDS[(DocumentDB / RDS<br/>Multi-AZ)]
            REDIS[(ElastiCache Redis<br/>Session + Query cache)]
        end

        NACL_PUB[NACL: Allow 80,443 in<br/>Deny known bad CIDRs]
        NACL_PRIV[NACL: Allow from public<br/>subnets only]
        NACL_DATA[NACL: Allow from private<br/>subnets only on DB ports]

        SG_ALB[SG: 80,443 from 0.0.0.0/0]
        SG_EKS[SG: traffic from ALB SG only]
        SG_DB[SG: 27017,6379 from EKS SG only]
    end

    subgraph AWSServices[AWS Managed Services]
        ECR[ECR<br/>Container Registry]
        S3[S3<br/>Object Storage]
        CW[CloudWatch<br/>Logs + Metrics]
        CODEP[CodePipeline<br/>CI/CD]
        COG[Cognito<br/>Auth / OIDC]
    end

    USER --> R53
    R53 --> CF
    CF --> WAF
    WAF --> ALB
    ALB --> ING
    ING --> APP1
    ING --> APP2
    BASTION -.->|SSM / kubectl| EKS
    EKS --> RDS
    EKS --> REDIS
    CODEP --> ECR
    ECR --> EKS
    ARGO -.->|GitOps sync| EKS
    EKS --> S3
    EKS --> CW
    NAT -->|Outbound| Internet
```

### Security Layers (Interview Talking Points)

```
Request flow and where each security layer applies:

User → Route 53 (DNS)
  → CloudFront (CDN, edge caching, geographic restrictions)
    → WAF (rate limiting, bot detection, OWASP rules, IP allowlists)
      → ALB (TLS termination, OIDC/Cognito auth)
        → Security Group (allow only ALB → EKS node ports)
          → NACL (stateless subnet-level firewall, deny known bad CIDRs)
            → NGINX Ingress (path routing, rate limiting, request validation)
              → Pod (Network Policy: namespace isolation, deny-all default)
                → Database (Security Group: only EKS SG on port 27017)
```

**Key concepts to mention in interviews:**
- **Defense in depth** — every layer adds a check, no single point of failure
- **Least privilege** — security groups reference other SGs, not CIDRs; pods can't talk cross-namespace by default
- **Public vs private subnets** — only ALB and NAT Gateway have public IPs; EKS nodes and databases are never internet-facing
- **NACLs vs Security Groups** — NACLs are stateless (need explicit allow for return traffic), SGs are stateful (return traffic auto-allowed). NACLs are the subnet-level coarse filter, SGs are the instance-level fine filter
- **NAT Gateway** — pods can pull images and call AWS APIs outbound, but nothing inbound reaches them except through the ALB
- **Zero-trust admin access** — no SSH. Use SSM Session Manager or `kubectl` via IAM auth, all actions logged to CloudTrail

For the full build plan and phase details, see [PLAN.md](PLAN.md).
For the step-by-step setup log, see [docs/setup-log.md](docs/setup-log.md).
