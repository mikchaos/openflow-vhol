-- Openflow Retail VHOL — Act 4: Watch it flow (observability)
-- Source: docs "Monitor connectors using the Openflow Connectors Dashboard" + "Monitor Openflow using telemetry data".
-- Prereq: Act 3 done (connector POSTGRES_INGEST RUNNING). Safe to re-run.
-- Story: health (1-8) -> latency (9-11) -> alert + failure drill (alert block, 12, scripts/fail_replication.py).

USE ROLE ACCOUNTADMIN;

-- 1. Dedicated event table for Openflow telemetry (created in Act 1; IF NOT EXISTS keeps this re-runnable).
--    A dedicated table keeps Openflow logs/metrics out of the account-wide SNOWFLAKE.TELEMETRY.EVENTS,
--    so the dashboard and SQL queries are faster and access can be granted narrowly.
CREATE EVENT TABLE IF NOT EXISTS OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
  COMMENT = 'Openflow telemetry (logs + metrics) for deployment SPCS_SOM';
ALTER OPENFLOW DEPLOYMENT SPCS_SOM SET EVENT_TABLE = OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS;

-- 2. Read access for the data role (the dashboard needs at least read-only access to the event table).
GRANT USAGE ON DATABASE OPENFLOW_DB TO ROLE RETAIL_HOL_ROLE;
GRANT USAGE ON SCHEMA OPENFLOW_DB.OPENFLOW_SCHEMA TO ROLE RETAIL_HOL_ROLE;
GRANT SELECT ON TABLE OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS TO ROLE RETAIL_HOL_ROLE;

-- 3. Speed up the dashboard: cluster the event table (documented recommendation).
--    Automatic clustering uses serverless credits; the benefit appears once background clustering completes.
ALTER TABLE OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
  CLUSTER BY (
    DATE_TRUNC('HOUR', timestamp),
    RECORD_TYPE,
    CAST(record_attributes:"metricNameHash" AS STRING)
  );

-- 4. Is telemetry arriving? (rows by type in the last hour)
SELECT record_type, COUNT(*) AS events_last_hour, MAX(timestamp) AS latest_event
FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
WHERE timestamp > DATEADD('hour', -1, SYSDATE())
GROUP BY record_type;

-- 5. Error logs from the Openflow runtime (last 30 min). Expect zero rows on a healthy run.
SELECT timestamp, runtime_key,
       parsed_log:level::STRING            AS log_level,
       parsed_log:loggerName::STRING       AS logger,
       parsed_log:formattedMessage::STRING AS message
FROM (
  SELECT timestamp,
         resource_attributes:"k8s.namespace.name"::STRING AS runtime_key,
         TRY_PARSE_JSON(value) AS parsed_log
  FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
  WHERE timestamp > DATEADD('minutes', -30, SYSDATE())
    AND record_type = 'LOG'
    AND resource_attributes:"k8s.namespace.name" LIKE 'runtime-%'
)
WHERE log_level = 'ERROR'
ORDER BY timestamp DESC
LIMIT 20;

-- 6. Stuck FlowFiles: connections with data queued > 30 minutes. Expect zero rows.
SELECT * FROM (
  SELECT resource_attributes:"k8s.namespace.name"::STRING AS runtime_key,
         record_attributes:name::STRING AS connection_name,
         MAX(TO_NUMBER(value / 60 / 1000)) AS max_queued_minutes
  FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
  WHERE record_type = 'METRIC'
    AND record:metric:name = 'connection.queued.duration.max'
    AND timestamp > DATEADD('minutes', -30, SYSDATE())
  GROUP BY 1, 2
) WHERE max_queued_minutes > 30;

-- 7. Runtime CPU (%), last 30 min — chart this in Snowsight.
SELECT timestamp,
       resource_attributes:"k8s.pod.name"::STRING AS runtime_pod,
       TO_NUMBER(value, 10, 3) * 100 AS cpu_usage_pct
FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
WHERE timestamp > DATEADD('minute', -30, SYSDATE())
  AND record_type = 'METRIC'
  AND record:metric:name ILIKE 'container.cpu.usage'
  AND resource_attributes:"k8s.namespace.name" ILIKE 'runtime-%'
  AND resource_attributes:"k8s.container.name" ILIKE '%-server'
ORDER BY timestamp DESC;

-- 8. Prove CDC end to end: freshest row per Bronze table (run after changing data in Postgres).
SELECT 'SALES_TRANSACTIONS' AS table_name, COUNT(*) AS row_count FROM RETAIL_HOL_ICEBERG.BRONZE.SALES_TRANSACTIONS
UNION ALL SELECT 'PRODUCT_REVIEWS',   COUNT(*) FROM RETAIL_HOL_ICEBERG.BRONZE.PRODUCT_REVIEWS
UNION ALL SELECT 'CUSTOMER_COMMENTS', COUNT(*) FROM RETAIL_HOL_ICEBERG.BRONZE.CUSTOMER_COMMENTS
UNION ALL SELECT 'DAILY_REVIEWS',     COUNT(*) FROM RETAIL_HOL_ICEBERG.BRONZE.DAILY_REVIEWS
UNION ALL SELECT 'INVENTORY_FEED',    COUNT(*) FROM RETAIL_HOL_ICEBERG.BRONZE.INVENTORY_FEED;

-- ============================ Latency (PostgreSQL connector metrics) ============================
-- The connector reports three latencies every 60 s while data flows (docs: "Monitor the Openflow Connector for PostgreSQL"):
--   db.commit.to.capture.latency   source COMMIT -> connector read it        (connector level)
--   db.capture.to.journal.latency  connector read -> journal table in Snowflake (connector level)
--   db.commit.to.merge.latency     source COMMIT -> merged into the Bronze table (per table, end to end)
-- Run scripts/cdc_demo.py --continuous first so there is traffic to measure.

-- 9. End-to-end latency per table (commit in Postgres -> row in Bronze). Chart: X = minute, Y = latency_s, series = source_table.
SELECT DATE_TRUNC('minute', timestamp)                AS minute,
       record_attributes:"source.table.name"::STRING   AS source_table,
       MAX(value::NUMBER) / 1000                       AS latency_s
FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
WHERE timestamp > DATEADD('hour', -1, SYSDATE())
  AND record_type = 'METRIC'
  AND record:metric:name = 'db.commit.to.merge.latency'
GROUP BY 1, 2
ORDER BY 1 DESC, 2;

-- 10. Where the time goes: capture vs journal vs end-to-end, last 15 min (p50 / max of the 60 s reports).
SELECT record:metric:name::STRING                                  AS metric,
       COUNT(*)                                                    AS reports,
       ROUND(APPROX_PERCENTILE(value::NUMBER, 0.5) / 1000, 1)      AS p50_s,
       ROUND(MAX(value::NUMBER) / 1000, 1)                         AS max_s
FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
WHERE timestamp > DATEADD('minute', -15, SYSDATE())
  AND record_type = 'METRIC'
  AND record:metric:name IN ('db.commit.to.capture.latency', 'db.capture.to.journal.latency', 'db.commit.to.merge.latency')
GROUP BY 1
ORDER BY 1;

-- 11. Freshness + phase per table: latest replication status and when Bronze was last written.
--     Status 1 NEW, 2 SNAPSHOT_REPLICATION, 3 INCREMENTAL_REPLICATION, >= 4 FAILED (4008 = MISSING_PRIMARY_KEYS).
WITH status AS (
  SELECT record_attributes:"source.schema.name"::STRING AS source_schema,
         record_attributes:"source.table.name"::STRING  AS source_table,
         value::NUMBER                                  AS status,
         timestamp
  FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
  WHERE timestamp > DATEADD('hour', -1, SYSDATE())
    AND record_type = 'METRIC'
    AND record:metric:name = 'db.table.status'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY source_schema, source_table ORDER BY timestamp DESC) = 1
), fresh AS (
  SELECT record_attributes:"source.schema.name"::STRING AS source_schema,
         record_attributes:"source.table.name"::STRING  AS source_table,
         TO_TIMESTAMP_LTZ(MAX(value::NUMBER), 3)        AS last_ingested
  FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
  WHERE timestamp > DATEADD('hour', -1, SYSDATE())
    AND record_type = 'METRIC'
    AND record:metric:name = 'db.last.ingestion.time'
  GROUP BY 1, 2
)
SELECT s.source_schema, s.source_table, s.status,
       CASE s.status WHEN 1 THEN 'NEW' WHEN 2 THEN 'SNAPSHOT_REPLICATION' WHEN 3 THEN 'INCREMENTAL_REPLICATION'
                     WHEN 4008 THEN 'FAILED: MISSING_PRIMARY_KEYS' ELSE IFF(s.status >= 4, 'FAILED', 'REMOVED') END AS phase,
       f.last_ingested,
       DATEDIFF('second', f.last_ingested, CURRENT_TIMESTAMP()) AS seconds_since_last_write
FROM status s LEFT JOIN fresh f USING (source_schema, source_table)
ORDER BY s.status DESC, s.source_table;

-- ============================ Alert: table replication failure ============================
-- A Snowflake alert is just SQL over the event table. Every minute it looks for tables whose latest
-- db.table.status is FAILED (>= 4) and records them in REPLICATION_ALERT_LOG.
-- Create it as ACCOUNTADMIN: the alert's owner role needs the EXECUTE ALERT account privilege, otherwise
-- every run fails with "EXECUTE ALERT privilege must be granted to owner role".
-- Snowsight alternative (no SQL): Monitoring -> Alerts -> create from template, OPENFLOW group ->
-- "Table replication failure alert" (gen 2), scoped to connector POSTGRES_INGEST, with an email/webhook target.
CREATE TABLE IF NOT EXISTS OPENFLOW_DB.OPENFLOW_SCHEMA.REPLICATION_ALERT_LOG (
  fired_at      TIMESTAMP_LTZ,
  connector     STRING,
  source_schema STRING,
  source_table  STRING,
  status          NUMBER,
  observed_at_utc TIMESTAMP_NTZ   -- event-table timestamps are UTC
);

CREATE OR REPLACE ALERT OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_INGEST_TABLE_FAILURE_ALERT
  WAREHOUSE = RETAIL_HOL_WH
  SCHEDULE = '1 MINUTE'
  COMMENT = 'Fires when any table replicated by POSTGRES_INGEST reports a FAILED db.table.status'
  IF (EXISTS (
    SELECT record_attributes:"connector.name"::STRING      AS connector,
           record_attributes:"source.schema.name"::STRING  AS source_schema,
           record_attributes:"source.table.name"::STRING   AS source_table,
           value::NUMBER                                   AS status,
           timestamp                                       AS observed_at_utc
    FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS
    WHERE timestamp > DATEADD('minute', -10, SYSDATE())
      AND record_type = 'METRIC'
      AND record:metric:name = 'db.table.status'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY source_schema, source_table ORDER BY timestamp DESC) = 1
      AND status >= 4
  ))
  THEN
    INSERT INTO OPENFLOW_DB.OPENFLOW_SCHEMA.REPLICATION_ALERT_LOG
      SELECT CURRENT_TIMESTAMP(), connector, source_schema, source_table, status, observed_at_utc
      FROM TABLE(RESULT_SCAN(SNOWFLAKE.ALERT.GET_CONDITION_QUERY_UUID()));

ALTER ALERT OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_INGEST_TABLE_FAILURE_ALERT RESUME;  -- alerts are created suspended

-- 12. Did it fire? (after scripts/fail_replication.py --break; allow ~2-3 min: 60 s metric + 1 min schedule)
SELECT name, state, scheduled_time, completed_time, sql_error_message
FROM TABLE(OPENFLOW_DB.INFORMATION_SCHEMA.ALERT_HISTORY(
  SCHEDULED_TIME_RANGE_START => DATEADD('minute', -30, CURRENT_TIMESTAMP()),
  ALERT_NAME => 'POSTGRES_INGEST_TABLE_FAILURE_ALERT'))
ORDER BY scheduled_time DESC
LIMIT 10;
SELECT * FROM OPENFLOW_DB.OPENFLOW_SCHEMA.REPLICATION_ALERT_LOG ORDER BY fired_at DESC LIMIT 20;

-- Dashboard (Snowsight UI): Ingestion -> Openflow -> Connector Observability
--   Event table filter: OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS   Time frame: Last Hour
--   POSTGRES_INGEST -> (more) -> View Details: per-table replication status/phase/Last Ingested
--   Unhealthy? -> Troubleshoot (AI root cause), Issues tab, View logs, Go to canvas (read-only for wizard connectors)
