# PostgreSQL CDC connector — configured with SQL (no wizard)

Source: Snowflake docs "Configure a gen 2 connector with SQL"
(https://docs.snowflake.com/en/user-guide/data-integration/openflow/gen2/configure-connector-sql).

> Status: the procedure (CREATE -> GET -> edit -> PUT -> COMMIT -> START) is documented.
> The exact parameter **keys** inside `config.json` are not published, so always edit the
> file you downloaded — never write `config.json` from scratch. Map the values below onto
> the keys you find (names match the wizard field labels, e.g. `"Source Database Password"`).

## 0. Context
```sql
USE ROLE OPENFLOW_ADMIN;
USE DATABASE OPENFLOW_DB;
USE SCHEMA OPENFLOW_SCHEMA;
SHOW OPENFLOW CONNECTOR DEFINITIONS LIKE '%POSTGRES%';   -- confirm OPENFLOW_POSTGRES_CDC exists
```
If the definition name differs in this account, use the one returned (the `name` column).

## 1. Create (STOPPED, Draft)
```sql
CREATE OPENFLOW CONNECTOR IF NOT EXISTS POSTGRES_INGEST
  IN RUNTIME POSTGRES_RUNTIME_SOM
  FROM DEFINITION OPENFLOW_POSTGRES_CDC
  DISPLAY_NAME = 'POSTGRES_INGEST';
```

## 2. Download the live config
Create `./connector/` at the repo root first (gitignored).
```sql
LS 'snow://openflow_connector/OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_INGEST/versions/live';
GET 'snow://openflow_connector/OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_INGEST/versions/live/config.json'
  'file://<absolute repo path>/connector/';
```
Snowsight cannot GET/PUT connector stages; CoCo's SQL connection can. If GET fails in the
SQL tool, run it via the Python connector in a shell command over the same connection.

## 3. Edit — value map (from the notebook's wizard table)
| Wizard field | Value |
|---|---|
| Source Database Connection URL | `jdbc:postgresql://<host from pg_creds.json>:5432/postgres` |
| Source Database User | `snowflake_admin` |
| Source Database Password | `{"valueType": "SECRET_REFERENCE", "fullyQualifiedSecretName": "RETAIL_HOL_ADMIN.SECRETS.RETAIL_HOL_PG_PASSWORD"}` |
| Source Database Publication Name | `openflow_retail_pub` |
| Tables / schemas to replicate | schema `bronze` only, all 5 tables (`bronze.sales_transactions`, `bronze.product_reviews`, `bronze.inventory_feed`, `bronze.customer_comments`, `bronze.daily_reviews`); exclude `public` |
| Columns | all; include newly added columns = on |
| Snowflake Destination Database | `RETAIL_HOL_ICEBERG` |
| Snowflake Warehouse | `RETAIL_HOL_WH` |
| Destination Schema Strategy | `{schema}` |
| Object Identifier Resolution | Case Insensitive (default; do not change after start) |
| Oversized Value Strategy | Set Null |
| Table Storage Format | Iceberg |
| Iceberg Version | 3 |
| Merge Task Schedule CRON | `* * * * * ?` (default) |
| Concurrent Snapshot Queries | `2` (default) |
| Ingestion Type | Full (default) |
| Replication Slot Name | blank (default) |

**JDBC driver.** The wizard asks for an uploaded PostgreSQL JDBC `.jar` asset. Inspect the
downloaded `config.json` for a driver/asset parameter:
- If it has none, or it is already populated by the definition, leave it.
- If it needs an asset, download the latest driver from https://jdbc.postgresql.org/download/
  (e.g. `postgresql-42.7.x.jar`) into `./connector/`, `LS` the connector's live version to see
  whether an assets path exists, `PUT` the jar there (`AUTO_COMPRESS = FALSE`), and reference it
  the way the file's existing asset structure shows. If the structure is unclear, stop and use the
  wizard fallback below — do not guess.

Show the attendee a diff of only the keys you changed (no secrets appear — the password is a reference).

## 4. Upload + commit
```sql
PUT 'file://<absolute repo path>/connector/config.json'
  'snow://openflow_connector/OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_INGEST/versions/live/'
  AUTO_COMPRESS = FALSE OVERWRITE = TRUE;
ALTER OPENFLOW CONNECTOR POSTGRES_INGEST COMMIT;
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS(600, 'POSTGRES_INGEST');
```
Destination is the live version **directory** (PUT appends the file name). Putting it to
`.../live/config.json` creates a nested object that shadows the real file.

## 5. Start
```sql
ALTER OPENFLOW CONNECTOR POSTGRES_INGEST START;
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS(600, 'POSTGRES_INGEST');
```

## 6. Edit later
```sql
ALTER OPENFLOW CONNECTOR POSTGRES_INGEST ADD LIVE VERSION FROM LAST;
-- GET, edit, PUT as above, then
ALTER OPENFLOW CONNECTOR POSTGRES_INGEST COMMIT;   -- or ABORT
```

## Troubleshooting
- Commit/validation error: read the message, fix the named key, PUT again, COMMIT again.
- Started but no Bronze tables after ~5 min:
  ```sql
  SELECT TIMESTAMP, RECORD_ATTRIBUTES, VALUE FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
  WHERE RECORD_ATTRIBUTES:"severity_text" = 'ERROR' ORDER BY TIMESTAMP DESC LIMIT 20;
  ```
  Common causes: egress rule still has the placeholder host; secret READ not granted to
  `POSTGRES_INGEST_SERVICE_ROLE`; publication missing.
- For deeper diagnostics load the bundled `openflow` / `openflow-observability` skills.

## Wizard fallback (if SQL config is blocked)
Snowsight -> Ingestion -> Openflow -> Launch Openflow -> switch role to `OPENFLOW_ADMIN` ->
Runtime tab -> `POSTGRES_RUNTIME_SOM` -> View more connectors -> Gen2 -> **PostgreSQL CDC
(Guided Wizard)** -> Install -> name `POSTGRES_INGEST`. Use the value map above. After
"Apply and Continue", start with `ALTER OPENFLOW CONNECTOR OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_INGEST START;`.
