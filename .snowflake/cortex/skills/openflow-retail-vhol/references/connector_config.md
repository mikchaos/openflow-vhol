# PostgreSQL CDC connector: configured with SQL (no wizard)

Source: Snowflake docs "Configure a gen 2 connector with SQL"
(https://docs.snowflake.com/en/user-guide/data-integration/openflow/gen2/configure-connector-sql).
**Verified end to end** on a live account: CREATE -> GET -> edit -> PUT (jar + config) -> COMMIT -> START -> RUNNING,
and all 5 Bronze Iceberg tables matched the Postgres row counts.

The lab automates this with `scripts/configure_connector.py`. Use the manual steps below only to
explain the script or to debug it.

## The real config.json format (definition OPENFLOW_POSTGRES_CDC, configFormatVersion 1)
`config.json` holds a `configuration` array of named groups. Each group has `properties` keyed by the
wizard field label. Value types are `STRING_LITERAL`, `SECRET_REFERENCE` and `ASSET_REFERENCE`.
Enum values differ from the wizard's display text (for example `SOURCE_SCHEMA`, not `{schema}`).

| Group | Key | Lab value |
|---|---|---|
| Source | Source Database Connection URL | `jdbc:postgresql://<host from pg_creds.json>:5432/postgres` |
| Source | Source Database User | `snowflake_admin` |
| Source | Source Database Password | `{"valueType":"SECRET_REFERENCE","fullyQualifiedSecretName":"RETAIL_HOL_ADMIN.SECRETS.RETAIL_HOL_PG_PASSWORD"}` |
| Source | Source Database Publication Name | `openflow_retail_pub` |
| Source | Source Database Driver | `{"valueType":"ASSET_REFERENCE","assetIds":["postgresql-42.7.5.jar"]}` (the jar is PUT into the same live version folder) |
| Replication table schema | Included Comma Separated Source Table Names | `"bronze"."customer_comments","bronze"."daily_reviews","bronze"."inventory_feed","bronze"."product_reviews","bronze"."sales_transactions"` |
| Replication columns | Column Filter JSON | `[]` (all columns) |
| Destination authentication | Snowflake Authentication Strategy | `SNOWFLAKE_MANAGED` |
| Destination details | Snowflake Destination Database | `RETAIL_HOL_ICEBERG` |
| Destination details | Snowflake Warehouse | `RETAIL_HOL_WH` |
| Destination details | Destination Schema Strategy | `SOURCE_SCHEMA` (lands in `RETAIL_HOL_ICEBERG.BRONZE`) |
| Destination details | Object Identifier Resolution | `CASE_INSENSITIVE` |
| Destination details | Oversized Value Strategy | `Set Null` |
| Destination details | Table Storage Format | `ICEBERG` |
| Destination details | Iceberg Version | `3` |
| Tuning | Merge Task Schedule CRON | `* * * * * ?` |
| Tuning | Concurrent Snapshot Queries | `2` |
| Migration | Ingestion Type | `full` |

## Manual steps
```sql
USE ROLE OPENFLOW_ADMIN; USE DATABASE OPENFLOW_DB; USE SCHEMA OPENFLOW_SCHEMA;
SHOW OPENFLOW CONNECTOR DEFINITIONS LIKE '%POSTGRES%';          -- OPENFLOW_POSTGRES_CDC
CREATE OPENFLOW CONNECTOR IF NOT EXISTS POSTGRES_INGEST
  IN RUNTIME POSTGRES_RUNTIME_SOM FROM DEFINITION OPENFLOW_POSTGRES_CDC DISPLAY_NAME = 'POSTGRES_INGEST';
SHOW OPENFLOW CONNECTORS LIKE 'POSTGRES_INGEST';                -- wait: CREATING -> STOPPED (~30 s)
GET 'snow://openflow_connector/OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_INGEST/versions/live/config.json' 'file://<repo>/connector/';
-- edit connector/config.json per the table above; download postgresql-42.7.5.jar into connector/
PUT 'file://<repo>/connector/postgresql-42.7.5.jar' 'snow://openflow_connector/OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_INGEST/versions/live/' AUTO_COMPRESS = FALSE OVERWRITE = TRUE;
PUT 'file://<repo>/connector/config.json'           'snow://openflow_connector/OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_INGEST/versions/live/' AUTO_COMPRESS = FALSE OVERWRITE = TRUE;
ALTER OPENFLOW CONNECTOR POSTGRES_INGEST COMMIT;
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS(600, 'POSTGRES_INGEST');
ALTER OPENFLOW CONNECTOR POSTGRES_INGEST START;
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS(600, 'POSTGRES_INGEST');   -- status RUNNING
```
Gotchas:
- The PUT destination is the live version **directory**. If you PUT to `.../live/config.json`, you create a nested object that shadows the real file.
- A new connector is briefly `CREATING`. Wait for `STOPPED` before you GET.
- To edit after a commit, run `ALTER OPENFLOW CONNECTOR POSTGRES_INGEST ADD LIVE VERSION FROM LAST;`, then GET/edit/PUT and `COMMIT` (or `ABORT`).
- Snowsight worksheets can't GET/PUT connector stages. CoCo's connection and the Python connector can.

## Troubleshooting
- Commit/validation error: read the message, fix the named key, PUT again, COMMIT again.
- Connector is RUNNING but Bronze is empty after ~5 min:
  ```sql
  SELECT TIMESTAMP, RECORD_ATTRIBUTES, VALUE FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
  WHERE RECORD_ATTRIBUTES:"severity_text" = 'ERROR' ORDER BY TIMESTAMP DESC LIMIT 20;
  ```
  The usual causes are an egress rule that still has the placeholder host, missing READ on the secret for `POSTGRES_INGEST_SERVICE_ROLE`, or a missing publication.
- For deeper diagnostics, load the bundled `openflow` / `openflow-observability` skills.

## Wizard fallback
Snowsight -> Ingestion -> Openflow -> Launch Openflow -> switch role to `OPENFLOW_ADMIN` -> Runtime tab ->
`POSTGRES_RUNTIME_SOM` -> View more connectors -> Gen2 -> **PostgreSQL CDC (Guided Wizard)** -> Install ->
name it `POSTGRES_INGEST`. Use the values above, then run `ALTER OPENFLOW CONNECTOR OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_INGEST START;`.
