# Data Platform — Learning Path & Build Roadmap

A self-guided roadmap for building Phases 5–9 of this platform (MinIO → Kafka →
Spark/Delta → JupyterHub → MLflow) **while actually learning the technologies**.

This doc is the companion to [`PLAN.md`](../PLAN.md). `PLAN.md` says *what* to
deploy; this doc says *what to learn first*, *where to learn it*, and *how to know
you understood it*. Build it yourself — use Claude as a tutor/debugger, not a
ghostwriter.

> **Scale reminder:** this is a *learning-scale* platform (hundreds–thousands of
> rows, 1 broker, 1 Spark executor). The goal is to understand the mechanics and
> the wiring, not to handle big-data volume. Everything here runs comfortably on
> your 2 HP ProDesk nodes.

---

## How to use this doc

For each phase:

1. **Concepts** — the mental model to build before touching a terminal.
2. **Learn** — specific, mostly-free references (read/skim in order).
3. **Build** — what to deploy (cross-references `PLAN.md`).
4. **Verify / Milestone** — a concrete task that proves you *get it*, not just
   that it's running.

Don't rush. A phase where you can *explain it to someone else* is worth three
phases you copy-pasted.

---

## Phase 0 — Foundations to shore up FIRST

Everything below rides on these. If Kubernetes feels shaky, the data tools will
feel impossible — because every error will look like a data error when it's
actually a pod/volume/networking error. Spend a week here if you need to.

| Skill | Why it matters here | Best references |
|---|---|---|
| **Kubernetes core objects** (Pod, Deployment, Service, PVC, ConfigMap, Secret, Job/CronJob, StatefulSet) | Every tool is deployed as these. You already used most via the app + MongoDB. | [kubernetes.io/docs/concepts](https://kubernetes.io/docs/concepts/) · *Kubernetes Up & Running* (Burns, Beda, Hightower) · [killercoda.com](https://killercoda.com/) interactive scenarios |
| **Helm** | MinIO, Kafka, Spark, JupyterHub all install via Helm charts + a `values.yaml`. | [helm.sh/docs](https://helm.sh/docs/) — focus on "Using Helm" + "Values" |
| **`kubectl` fluency** (logs, describe, exec, port-forward, events) | This is 90% of your debugging. | [kubectl cheat sheet](https://kubernetes.io/docs/reference/kubectl/cheatsheet/) |
| **Object storage / S3 model** (buckets, keys, no folders, access key/secret) | MinIO *is* this. Spark/MLflow/Jupyter all read/write S3 paths. | [AWS S3 core concepts](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html) · [MinIO docs](https://min.io/docs/minio/kubernetes/upstream/) |
| **Python + SQL basics** | PySpark is Python; Spark/Delta querying is SQL. | If rusty: [Python docs tutorial](https://docs.python.org/3/tutorial/) + any SQL `SELECT/JOIN/GROUP BY` refresher |
| **(Big-picture book)** *Designing Data-Intensive Applications* — Kleppmann | The "why" behind every tool here (logs, partitioning, batch vs stream). | Read alongside the whole journey, a chapter at a time |

**Milestone:** Without notes, explain the difference between a Deployment and a
StatefulSet, and why MongoDB/Kafka want stable storage. Deploy any random Helm
chart (e.g. `nginx`), change one value, `helm upgrade`, and see it change.

---

## Phase 5 — Storage: MinIO (the data lake)

**Concept:** MinIO is a self-hosted, S3-compatible object store. It's the
*foundation* — Kafka sink, Spark input/output, Jupyter reads, MLflow artifacts all
land here. Learn the S3 mental model (a bucket + a flat keyspace; "folders" are
just key prefixes) and how apps authenticate (access key + secret, endpoint URL).

**Learn:**
- [MinIO Kubernetes docs](https://min.io/docs/minio/kubernetes/upstream/) — install + Console tour
- [`mc` (MinIO Client) reference](https://min.io/docs/minio/linux/reference/minio-mc.html) — `mc alias`, `mc ls`, `mc cp`, `mc mb`
- S3 concepts: buckets, objects, keys, prefixes, presigned URLs

**Build:** `PLAN.md` Phase 5 — Helm install in `data-platform`, expose Console
(Tailscale-only), create access key/secret as a Secret, make buckets:
`raw-data`, `processed-data`, `mlflow-artifacts`, `backups`.

**Verify / Milestone:** From your Mac over Tailscale, `mc alias set` your MinIO,
then `mc cp` a CSV into `raw-data` and `mc ls` it back. You should be able to
articulate the endpoint/access-key/secret triplet any S3 client needs — you'll
reuse it in every later phase.

---

## Phase 6 — Ingestion: Kafka (streaming log)

**Concept:** Kafka is a distributed, append-only commit log. Producers append
messages to **topics** (split into **partitions**); consumers read at their own
**offset**. Internalize: topic vs partition, offset, consumer group, retention,
and "the log is the source of truth." Modern Kafka runs **KRaft** mode (no
ZooKeeper) — know that ZooKeeper tutorials are now legacy.

**Learn:**
- [Apache Kafka docs — Introduction & Design](https://kafka.apache.org/documentation/#introduction)
- [*Kafka: The Definitive Guide* (2nd ed)](https://www.confluent.io/resources/kafka-the-definitive-guide/) — free O'Reilly PDF via Confluent; read ch. 1–4
- [developer.confluent.io](https://developer.confluent.io/) — free courses ("Kafka 101", "Kafka Internals")
- Concept check: *why* is a partition the unit of parallelism and ordering?

**Build:** `PLAN.md` Phase 6 — Bitnami Kafka chart, KRaft, 1 broker, modest
resources. Set explicit `retention.ms`/`retention.bytes` on topics as a habit.

**Verify / Milestone:** Create a `test-topic`, produce a few messages with the
console producer, consume them with the console consumer **and** re-consume from
offset 0 (proving the log persists independent of readers). Bonus: write a tiny
Python producer/consumer with `kafka-python` or `confluent-kafka`.

---

## Phase 7 — Processing: Spark + Delta Lake (the core learning goal)

**Concept:** This is the big one. Spark is a distributed compute engine; you
describe transformations on **DataFrames** and Spark builds a lazy execution plan
that runs across executors. **PySpark** is the Python API. **Delta Lake** adds
ACID transactions, schema enforcement, and time-travel on top of Parquet files in
object storage — turning your MinIO buckets into a real "lakehouse" table.

Key things to truly understand (these are what interviews and real bugs hinge on):
- **Lazy evaluation**: transformations (`select`, `filter`, `join`) vs actions
  (`count`, `collect`, `write`) — nothing runs until an action.
- **Partitions & shuffles**: why a `groupBy`/`join` is expensive.
- **DataFrame API vs Spark SQL**: same engine, two front-ends.
- **Why Delta over raw Parquet**: atomic writes, schema evolution, time travel.

**Learn (in order):**
1. [*Learning Spark, 2nd ed*](https://www.databricks.com/resources/ebook/learning-spark) — free from Databricks; the best starting book. Ch. 1–6.
2. [Spark SQL / DataFrame Programming Guide](https://spark.apache.org/docs/latest/sql-programming-guide.html)
3. [PySpark API reference](https://spark.apache.org/docs/latest/api/python/index.html)
4. [Delta Lake docs](https://docs.delta.io/latest/index.html) — quickstart + "Delta table batch reads and writes"
5. *Spark: The Definitive Guide* (Chambers & Zaharia) — deeper reference when you want internals
6. Running Spark on Kubernetes: [Kubeflow Spark Operator](https://github.com/kubeflow/spark-operator) docs + [Spark "Running on Kubernetes"](https://spark.apache.org/docs/latest/running-on-kubernetes.html)

**Build:** `PLAN.md` Phase 7 — Spark Operator via Helm, a custom Spark image
(built through your Jenkins pipeline!) bundling Delta + `hadoop-aws` jars so Spark
can talk to MinIO over S3A. A `SparkApplication` CR that reads a CSV from
`raw-data`, transforms, and writes a **Delta table** to `processed-data`.

**Tip — learn locally first, then go distributed:** before fighting the Operator,
run PySpark + Delta on your Mac (`pip install pyspark delta-spark`) against a
local folder or directly against MinIO. Get the *code* working in a notebook/REPL,
*then* wrap it in a container and `SparkApplication`. Separates "do I understand
Spark?" from "do I understand Spark-on-k8s?".

**Verify / Milestone:** Write a small ETL that reads CSV → does a `groupBy`
aggregation → writes Delta to MinIO. Then prove you understand Delta:
`DESCRIBE HISTORY` the table, overwrite it, and **time-travel** to read the prior
version. Explain out loud why nothing computed until `.write`.

---

## Phase 8 — Notebooks: JupyterHub (interactive analysis)

**Concept:** JupyterHub serves per-user notebook servers in-cluster. Here it's
your interactive window into the lakehouse — read the Delta table Spark wrote and
explore it with PySpark + pandas + matplotlib.

**Learn:**
- [Zero to JupyterHub on Kubernetes (z2jh)](https://z2jh.jupyter.org/) — the canonical Helm-based guide
- Connecting a notebook to S3: `boto3` / `s3fs` for plain object access; PySpark
  with S3A config for Delta
- [Delta Lake "without Spark"](https://delta.io/blog/) (e.g. `delta-rs`/`deltalake` Python) is an option for light reads — know it exists

**Build:** `PLAN.md` Phase 8 — z2jh Helm chart; a custom notebook image (built via
Jenkins) with PySpark + Delta + boto3/s3fs; a sample notebook reading the Delta
table from MinIO.

**Verify / Milestone:** From a notebook, load the `processed-data` Delta table
into a DataFrame and make one chart. You now have an end-to-end path:
`CSV → MinIO → Spark/Delta → notebook → plot`.

---

## Phase 9 — ML Tracking: MLflow (experiments + artifacts)

**Concept:** MLflow records ML experiments — params, metrics, and artifacts
(models, plots) — so runs are reproducible and comparable. It needs a **backend
store** (Postgres, for run metadata) and an **artifact store** (your MinIO
`mlflow-artifacts` bucket). This phase also teaches you the
"stateful service + its own backup" pattern again (Postgres `pg_dump` CronJob).

**Learn:**
- [MLflow docs](https://mlflow.org/docs/latest/index.html) — "Tracking" + "Tracking Server"
- [MLflow Tracking quickstart](https://mlflow.org/docs/latest/getting-started/intro-quickstart/)
- How MLflow uses S3 for artifacts (the `MLFLOW_S3_ENDPOINT_URL` for MinIO)

**Build:** `PLAN.md` Phase 9 — Postgres (Bitnami chart), MLflow tracking server
(Postgres backend + MinIO artifacts), a small sklearn training script that logs a
run, and a `pg_dump` → MinIO `backups` CronJob.

**Verify / Milestone:** Train a tiny sklearn model (e.g. iris), log params +
accuracy + the model artifact to MLflow, and view two runs side-by-side in the UI.
Confirm the artifact actually landed in the MinIO bucket.

---

## Capstone — tie it together (this is your portfolio centerpiece)

Once the phases work in isolation, build **one coherent mini-pipeline** end to
end. This is the thing the portfolio site will showcase:

> A small dataset (e.g. a public CSV) → **produced into Kafka** → a job lands it in
> **MinIO `raw-data`** → **Spark** reads it, transforms, writes a **Delta** table to
> `processed-data` → a **Jupyter** notebook analyzes it → a model is trained and
> **logged to MLflow**.

Document it with a diagram (you already like Excalidraw) and a short write-up of
what each component does and *why*. That narrative — "I built a bare-metal
lakehouse and here's the data's journey" — is worth more than any single tool on a
résumé.

---

## Suggested pace & sequencing

- **Phase 0 foundations:** ~1–2 weeks (don't skip; it pays back everywhere).
- **MinIO:** a few evenings — it's the easiest and unblocks everything.
- **Kafka:** ~1 week — concepts take longer than the install.
- **Spark + Delta:** the longest, **~3–4 weeks** — this is the real learning. Budget the most time here.
- **JupyterHub:** a few evenings once Spark/Delta work.
- **MLflow:** ~1 week.
- **Capstone:** ~1 week of wiring + writing it up.

Do them **in order** — each phase consumes the previous one's output. The hard
dependency chain is: **MinIO → (Kafka ∥ Spark) → Spark needs MinIO → Jupyter needs
Delta → MLflow needs MinIO + Postgres.**

---

## Reference shelf (bookmark these)

**Books**
- *Designing Data-Intensive Applications* — Martin Kleppmann (the foundational "why")
- *Learning Spark, 2nd ed* — Damji et al. (free, Databricks) — **start here for Spark**
- *Spark: The Definitive Guide* — Chambers & Zaharia (deeper reference)
- *Kafka: The Definitive Guide, 2nd ed* — Narkhede et al. (free, Confluent)
- *Kubernetes Up & Running* — Burns, Beda, Hightower

**Official docs**
- Kubernetes — https://kubernetes.io/docs/
- Helm — https://helm.sh/docs/
- MinIO — https://min.io/docs/
- Apache Kafka — https://kafka.apache.org/documentation/
- Apache Spark — https://spark.apache.org/docs/latest/
- Delta Lake — https://docs.delta.io/
- JupyterHub (z2jh) — https://z2jh.jupyter.org/
- MLflow — https://mlflow.org/docs/

**Free courses / interactive**
- Confluent Developer (Kafka) — https://developer.confluent.io/
- KillerCoda (k8s scenarios) — https://killercoda.com/
- Databricks Spark resources — https://www.databricks.com/resources

---

## A note on using Claude while you learn

Good uses (keep learning intact):
- "Explain *why* this Spark job shuffles here."
- "I'm getting this S3A error connecting Spark to MinIO — what does it mean?"
- "Review my `values.yaml` and explain what each block does."
- "Quiz me on Kafka partitions and consumer groups."

Avoid (defeats the purpose): "write the whole Spark job / chart for me." Struggle
a bit first — the struggle is the learning. Bring me the error, not the blank page.
