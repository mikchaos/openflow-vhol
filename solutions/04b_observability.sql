-- Openflow Retail VHOL — Act 4: Watch it flow (observability)
-- Source: docs "Monitor connectors using the Openflow Connectors Dashboard" + "Monitor Openflow using telemetry data".
-- Prereq: Act 3 done (connector POSTGRES_INGEST RUNNING). Safe to re-run.

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

-- Dashboard (Snowsight UI): Ingestion -> Openflow -> Connector Observability
--   Event table filter: OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS   Time frame: Last Hour
--   POSTGRES_INGEST -> (more) -> View Details: per-table replication status/phase/Last Ingested
--   Unhealthy? -> Troubleshoot (AI root cause), Issues tab, View logs, Go to canvas (read-only for wizard connectors)
