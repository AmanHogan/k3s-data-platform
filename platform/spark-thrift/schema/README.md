# Hive Metastore Schema Bootstrap

Official Hive 2.3 metastore schema for PostgreSQL (from `apache/hive` rel/release-2.3.9).
Spark 3.5 bundles the Hive 2.3.9 client, so this is the schema version it expects.

**Must be applied to the `hive_metastore` database BEFORE starting the Spark
Thrift Server for the first time.** Do not rely on
`datanucleus.schema.autoCreateAll` — lazy schema creation runs DDL
mid-transaction and deadlocks in PostgreSQL (create_table hangs forever,
wedging the whole thrift server).

## Apply

```bash
POD=$(kubectl get pod -n data-platform -l app=postgres -o jsonpath='{.items[0].metadata.name}')
kubectl cp hive-schema-2.3.0.postgres.sql data-platform/$POD:/tmp/
kubectl cp hive-txn-schema-2.3.0.postgres.sql data-platform/$POD:/tmp/
kubectl exec -n data-platform $POD -- bash -c \
  "cd /tmp && psql -U dataplatform -d hive_metastore -f hive-schema-2.3.0.postgres.sql"
```

Verify: `SELECT "SCHEMA_VERSION" FROM "VERSION";` should return `2.3.0`.
