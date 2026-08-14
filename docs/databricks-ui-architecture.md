# Databricks-at-Home — UI Architecture

## Overview

A unified Next.js frontend (`data.amanhogan.com`) that replaces all individual tool UIs
(Spark UI, Airflow UI, JupyterHub, MinIO Console) with one Databricks-style interface.

## Pages & Backend Mapping

### 1. Workspace (File Browser)
Browse and manage notebooks, scripts, and data files.

| Feature | Backend | API |
|---|---|---|
| Browse files/folders | MinIO S3 API | `GET /api/workspace?path=/notebooks` |
| Upload notebook | MinIO S3 API | `POST /api/workspace/upload` |
| Delete/rename file | MinIO S3 API | `DELETE /api/workspace/:path` |
| Create folder | MinIO S3 API | `POST /api/workspace/mkdir` |

**MinIO bucket layout:**
```
notebooks/          ← .ipynb files organized by project
scripts/            ← .py Spark scripts for batch jobs
uploads/            ← user-uploaded CSVs, JSON, etc.
```

### 2. Notebook Editor
Write and execute Python/PySpark code interactively.

| Feature | Backend | API |
|---|---|---|
| Open notebook | MinIO (fetch .ipynb) | `GET /api/notebooks/:path` |
| Run cell | Jupyter Kernel Gateway / Spark | `POST /api/notebooks/execute` |
| Save notebook | MinIO (write .ipynb) | `PUT /api/notebooks/:path` |
| Autocomplete | Jupyter Kernel | WebSocket |
| View output (table/chart) | Frontend renders | — |

**Options for notebook execution:**
- **Option A: Embed JupyterHub** in an iframe (quick, ugly)
- **Option B: Jupyter Kernel Gateway** — headless kernel, your UI sends code and renders output (Databricks approach)
- **Option C: Custom execution API** — your backend sends code to Spark via `spark-submit` or PySpark subprocess

**Recommended: Option B** — deploy Jupyter Kernel Gateway on k3s, your frontend sends code cells via REST/WebSocket, renders output with your UI kit.

### 3. SQL Editor
Write SQL queries against Delta Lake / Parquet tables.

| Feature | Backend | API |
|---|---|---|
| Run SQL query | Spark Thrift Server (JDBC) | `POST /api/sql/execute` |
| View results as table | Frontend renders | — |
| Browse query history | MongoDB | `GET /api/sql/history` |
| Save query | MongoDB | `POST /api/sql/queries` |
| Export results (CSV) | Backend generates | `GET /api/sql/export/:id` |

**Backend component:** Spark Thrift Server (HiveServer2-compatible) — exposes Spark SQL over JDBC.
Your Next.js API route connects via JDBC, runs the query, returns results as JSON.

### 4. Data Catalog
Browse databases, tables, columns, and preview data.

| Feature | Backend | API |
|---|---|---|
| List databases | Spark Thrift / Hive Metastore | `GET /api/catalog/databases` |
| List tables in DB | Spark Thrift / Hive Metastore | `GET /api/catalog/:db/tables` |
| View table schema | Spark Thrift | `GET /api/catalog/:db/:table/schema` |
| Preview rows (LIMIT 100) | Spark Thrift | `GET /api/catalog/:db/:table/preview` |
| Table stats (row count, size) | Spark / MinIO | `GET /api/catalog/:db/:table/stats` |
| View table history (Delta) | Delta Lake API | `GET /api/catalog/:db/:table/history` |

**Backend component:** Hive Metastore (backed by PostgreSQL) — stores table definitions pointing to Parquet/Delta files on MinIO.

### 5. Jobs & Workflows
Create, schedule, and monitor data pipelines.

| Feature | Backend | API |
|---|---|---|
| List DAGs | Airflow REST API | `GET /api/jobs` |
| View DAG graph | Airflow REST API | `GET /api/jobs/:id/graph` |
| Trigger DAG run | Airflow REST API | `POST /api/jobs/:id/run` |
| View run history | Airflow REST API | `GET /api/jobs/:id/runs` |
| View task logs | Airflow REST API | `GET /api/jobs/:id/runs/:runId/logs` |
| Create new job | Airflow REST API | `POST /api/jobs` |
| Schedule (cron) | Airflow REST API | `PUT /api/jobs/:id/schedule` |

**Backend component:** Airflow REST API (enabled by default in Airflow 2.x).

### 6. Compute
Manage Spark cluster and view resource usage.

| Feature | Backend | API |
|---|---|---|
| Cluster status | Spark Master REST API | `GET /api/compute/cluster` |
| Worker list | Spark Master REST API | `GET /api/compute/workers` |
| Running applications | Spark Master REST API | `GET /api/compute/apps` |
| Node health | Kubernetes API (your MCP server) | `GET /api/compute/nodes` |
| Pod list | Kubernetes API | `GET /api/compute/pods` |
| Resource usage (CPU/mem) | Kubernetes metrics API | `GET /api/compute/metrics` |

### 7. Models & Experiments (Phase 3)
Track ML experiments and manage model registry.

| Feature | Backend | API |
|---|---|---|
| List experiments | MLflow REST API | `GET /api/models/experiments` |
| View runs in experiment | MLflow REST API | `GET /api/models/experiments/:id/runs` |
| Compare runs | MLflow REST API | `GET /api/models/compare` |
| Model registry | MLflow REST API | `GET /api/models/registry` |
| Deploy model | Custom (k8s deployment) | `POST /api/models/deploy` |

## Backend API Architecture

```
Next.js App (data.amanhogan.com)
├── /app                    ← Frontend pages (React + your UI kit)
│   ├── /workspace          ← File browser
│   ├── /notebooks          ← Notebook editor
│   ├── /sql                ← SQL editor
│   ├── /catalog            ← Data catalog
│   ├── /jobs               ← Airflow DAG viewer
│   ├── /compute            ← Cluster management
│   └── /models             ← MLflow experiments
│
├── /app/api                ← Next.js API routes (BFF layer)
│   ├── /workspace/[...path] → MinIO S3 API
│   ├── /notebooks/execute   → Jupyter Kernel Gateway
│   ├── /sql/execute         → Spark Thrift Server (JDBC)
│   ├── /catalog/            → Hive Metastore / Spark Thrift
│   ├── /jobs/               → Airflow REST API
│   ├── /compute/            → Spark Master + k8s API
│   └── /models/             → MLflow REST API
│
└── MongoDB                 ← App state: saved queries, user prefs, query history
```

## Required Backend Services (Deploy Order)

| # | Service | Purpose | Status |
|---|---|---|---|
| 1 | MinIO | Object storage / data lake | ✅ Running |
| 2 | Spark Master + Worker | Distributed compute | ✅ Running |
| 3 | JupyterHub | Notebook execution (temporary) | ✅ Running |
| 4 | **PostgreSQL** | Metastore for Airflow + Hive + MLflow | 🔜 Next |
| 5 | **Hive Metastore** | Table catalog pointing to MinIO | 🔜 |
| 6 | **Spark Thrift Server** | SQL over JDBC | 🔜 |
| 7 | **Airflow** | Job orchestration | 🔜 |
| 8 | **Jupyter Kernel Gateway** | Headless notebook execution for UI | 🔜 |
| 9 | **MLflow** | Experiment tracking | Later |
| 10 | **Next.js App** | Unified frontend | Later |

## UI Kit — What's Ready vs. What Needs Building

The data platform frontend uses the **homelab-ui-kit** (`/dev/homelab-ui-kit`) —
copy-from reference, not an npm dependency. See its DESIGN.md for color tokens,
radius, motion rules, and coding standards.

### Already built in the kit (copy and use)

| Component | Kit file | Data platform usage |
|---|---|---|
| Sidebar nav | `sidebar-nav.tsx` | Main app nav: workspace/sql/catalog/jobs/compute/models |
| Data table | `data-table.tsx` | SQL results, catalog preview, job runs, pod list, worker list |
| Tab bar | `tab-bar.tsx` | Open notebooks, query tabs, catalog db/table tabs |
| Status badge | `status-badge.tsx` | Running/Succeeded/Failed for jobs, pods, workers |
| Log viewer | `log-viewer.tsx` | Job task logs, Spark logs, executor logs |
| Stat tile | `stat-tile.tsx` | Cluster metrics (CPU, memory, disk, executor count) |
| Filter chips | `filter-chips.tsx` | Filter jobs by status, tables by database |
| Resource card | `resource-card.tsx` | Spark worker cards, node status, bucket overview |
| Button/Input/Select | `ui/*.tsx` | All forms (query input, config editors, dropdowns) |

### Needs building (add to kit, then copy)

| Component | Priority | Notes |
|---|---|---|
| **Code editor block** | P0 | Monaco wrapper — needed for notebook cells + SQL editor. Decision: Monaco (IntelliSense for SQL) |
| **File browser** | P1 | MinIO workspace tree. Kit ROADMAP says reuse `data-table.tsx` for list view |
| **Chart builder** | P1 | Visualize query results. Kit ROADMAP needs library decision (Recharts vs visx) |
| **Schema viewer** | P1 | Tree: database → table → columns with type badges |
| **Pipeline DAG** | P2 | Airflow DAG graph visualization |
| **Notebook cell** | P2 | Code editor + output renderer (table/chart/error/image) below |
| **Query results panel** | P2 | Wraps data-table + row count + execution time + export |
| **Resource gauge** | P2 | CPU%/mem%/disk% circular/bar gauge for compute page |
| **Terminal** | P3 | Embedded interactive command component |

### Kit setup for the data platform app

```bash
# From /dev/k3s-data-platform/frontend (once we scaffold it)
npx create-next-app@latest . --typescript --tailwind --app
npx shadcn@latest init

# Kit deps
npm install clsx tailwind-merge lucide-react react-icons geist tw-animate-css \
  sonner class-variance-authority radix-ui @monaco-editor/react
npm install -D @tailwindcss/typography

# Copy kit foundations
cp ../homelab-ui-kit/src/app/globals.css src/app/globals.css
cp ../homelab-ui-kit/src/components/ui/*.tsx src/components/ui/
cp ../homelab-ui-kit/src/lib/*.ts src/lib/
cp ../homelab-ui-kit/eslint.config.mjs eslint.config.mjs

# Copy the components this app needs
for f in sidebar-nav data-table tab-bar status-badge log-viewer \
         stat-tile filter-chips resource-card; do
  cp ../homelab-ui-kit/src/components/${f}.tsx src/components/
done
```

## Phased Build Plan

### Phase 1 — Foundation ✅
- MinIO, Spark, JupyterHub deployed and verified in distributed mode

### Phase 2 — Data Layer (next)
- PostgreSQL (shared metastore for Airflow + Hive + MLflow)
- Hive Metastore (table catalog pointing to MinIO Parquet/Delta)
- Spark Thrift Server (SQL over JDBC — lets the frontend query tables)
- Airflow (job orchestration with REST API enabled)
- Delta Lake support (delta-spark jar on Spark workers)
- First DAG: CSV → Spark transform → Delta Lake on MinIO (medallion: bronze → silver → gold)

### Phase 2.5 — Kit Components
- Build **code editor block** (Monaco) in homelab-ui-kit
- Build **file browser** in homelab-ui-kit (reuse data-table)
- Build **chart builder** in homelab-ui-kit (Recharts)
- Build **schema viewer** in homelab-ui-kit

### Phase 3 — UI MVP (`data.amanhogan.com`)
- Scaffold Next.js app from homelab-ui-kit
- **Compute page** — Spark cluster status, worker cards, node health (uses: resource-card, stat-tile, data-table)
- **Data Catalog page** — browse Hive databases/tables/columns (uses: schema viewer, data-table)
- **SQL Editor page** — write queries, view results (uses: Monaco editor, data-table, tab-bar)
- **Workspace page** — MinIO file browser (uses: file browser, filter-chips)
- **Jobs page** — Airflow DAG list, run history, logs (uses: data-table, status-badge, log-viewer)
- Deploy on k3s, expose via Cloudflare Tunnel
- MongoDB for app state (saved queries, user prefs, query history)

### Phase 4 — Notebook & ML
- Jupyter Kernel Gateway (headless — replaces JupyterHub for the UI)
- Custom notebook editor in the UI (Monaco cells + output renderer)
- MLflow deployment
- Models/Experiments page (experiment list, run comparison, model registry)
- Kafka event bus for real-time streaming pipelines
