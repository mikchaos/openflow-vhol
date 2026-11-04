-- Openflow Retail VHOL — Part 2: Snowflake Managed Postgres source
-- Source: notebooks/01-retail-hol-instance-creation-data-population.ipynb
-- In the lab, steps 1-3 run via scripts/setup_postgres.py so the one-time password is never displayed.
-- This file is the reference SQL / answer key.

USE ROLE RETAIL_HOL_ROLE;
USE WAREHOUSE RETAIL_HOL_WH;

-- 1. Create the instance (returns host + access_roles ONCE — capture them)
CREATE POSTGRES INSTANCE RETAIL_HOL_PG
  COMPUTE_FAMILY          = 'STANDARD_M'
  STORAGE_SIZE_GB         = 10
  AUTHENTICATION_AUTHORITY = POSTGRES
  POSTGRES_VERSION        = 18
  NETWORK_POLICY          = 'RETAIL_HOL_NETWORK_POLICY'
  COMMENT                 = 'Retail HOL - AI-Ready Data Pipeline demo'
->> SELECT
  "host"                                              AS host,
  'snowflake_admin'                                   AS admin_user,
  PARSE_JSON("access_roles"):"snowflake_admin"::STRING AS admin_password
FROM $1;

-- 2. Checkpoint P: wait for state = READY
DESCRIBE POSTGRES INSTANCE RETAIL_HOL_PG
->> SELECT "property", "value" FROM $1 WHERE "property" IN ('name', 'state', 'host');

-- 3. Secret + egress rule (replace placeholders; CoCo does this from pg_creds.json)
USE ROLE ACCOUNTADMIN;
CREATE OR REPLACE SECRET RETAIL_HOL_ADMIN.SECRETS.RETAIL_HOL_PG_PASSWORD
  TYPE          = GENERIC_STRING
  SECRET_STRING = '<snowflake_admin password>'
  COMMENT       = 'Postgres password for OpenFlow CDC connector (user: snowflake_admin)';
GRANT READ ON SECRET RETAIL_HOL_ADMIN.SECRETS.RETAIL_HOL_PG_PASSWORD TO ROLE RETAIL_HOL_ROLE;

ALTER NETWORK RULE RETAIL_HOL_ADMIN.NETWORK.RETAIL_HOL_EGRESS_RULE
  SET VALUE_LIST = ('<instance host>:5432');

-- 4. Load data + publication: run locally from the repo root
--    <venv-python> scripts/load_retail_data.py
--    Expected: 5 tables, ~10,000+ rows, publication openflow_retail_pub.
