---
name: openflow-retail-vhol
description: "Build the Retail AI-Ready Data Pipeline for the Openflow VHOL: Snowflake Managed Postgres -> Openflow Gen2 PostgreSQL CDC (SQL-configured connector) -> Bronze Iceberg -> Silver/Gold Dynamic Iceberg Tables with Cortex AI -> Semantic View -> Cortex Agent. Loads the exact object model, naming, and DDL so short prompts produce consistent objects. Use when: building any part of this lab. Triggers: openflow vhol, retail hol, candle retailer, RETAIL_HOL_PG, SPCS_SOM, POSTGRES_RUNTIME_SOM, POSTGRES_INGEST, postgres cdc, bronze iceberg, silver managed iceberg, gold managed iceberg, retail analyst agent, RETAIL_PRODUCT_INTELLIGENCE."
---

# Openflow Retail VHOL — Ingestion to Insight

You are helping a workshop attendee build an **AI-Ready Data Pipeline** on Snowflake
from **CoCo Desktop**, one prompt per part.

**The story:** a 12-SKU candle and fragrance brand (*Frosted Juniper*, *Vanilla
Cedarlight*, ...) sells online and through 4 regional store networks (NE, NW, SE, SW),
fulfilled from 5 warehouses (LA, Houston, NYC, Chicago, SF). Four personas can't agree
on a number:
- **Merchandiser** (daily): "What sold yesterday? Is anything running low?"
- **VP of Retail** (weekly): "How did we do? Where are we trending?"
- **CX Lead** (constantly): "What are customers saying about us right now?"
- **Supply Chain Planner**: "Which warehouse needs a truck today?"

The fix: one platform, one pipeline, one agent.
`Managed Postgres (OLTP) --CDC/Openflow--> Iceberg Bronze --> Dynamic Iceberg Silver/Gold --> Semantic View --> Cortex Agent`

**Golden rule:** produce objects with the EXACT names, columns and settings in the
Object Model and `references/object_model.md` (verbatim from the original notebooks).
Do not rename objects, change target lags, or "improve" DDL. Use `IF NOT EXISTS` /
`CREATE OR REPLACE` exactly as written so re-runs are safe. After each part, run its
Checkpoint and report the result in one or two lines, then tell the attendee the
"why it matters" line for that part.

## Fixed context

- Account: event-provided, region **varies**. SPCS, Openflow, Managed Postgres and
  Cortex AI are expected to be available. Run the **Preflight** before Part 1 and
  stop with a clear message if a feature is missing.
- CoCo Desktop connection: user `VHOLuser`, role `ACCOUNTADMIN` (from
  `solutions/00_bootstrap.sql`). Run all SQL through the active CoCo SQL connection.
  Do NOT use `snowflake_connections_list` or shell out to `snow`/`cortex` CLI for SQL:
  those may hit a different default connection.
- Roles: `ACCOUNTADMIN` for setup, `OPENFLOW_ADMIN` for deployment/runtime/connector,
  `RETAIL_HOL_ROLE` for Postgres, Silver/Gold, semantic view and agent. Every DDL block
  starts with the `USE ROLE` shown in `object_model.md`.
- Setup check prompt ("test the connection and confirm the skill is loaded"): run
  `SELECT CURRENT_ACCOUNT() AS account, CURRENT_USER() AS user, CURRENT_ROLE() AS role, CURRENT_REGION() AS region;`
  report values (expect `VHOLUSER`, `ACCOUNTADMIN`) and confirm `openflow-retail-vhol` is active.

## Secrets handling (strict)

- The Postgres `snowflake_admin` password is returned ONCE by `CREATE POSTGRES INSTANCE`.
  **Never run that CREATE through the SQL tool** (the password would enter chat context).
  Always run `scripts/setup_postgres.py`, which writes it straight to `pg_creds.json`
  (gitignored, chmod 600), creates the secret, updates the egress rule, and prints only the
  host + `****<last 4>`.
- Never `cat`/read `pg_creds.json`, `secret.pat`, or `~/.snowflake/connections.toml` into chat.
- Helper-script auth: `--account <ORG-ACCOUNT>` (user `VHOLuser` + PAT from `secret.pat` in the
  repo root). Get the account with SQL on the active connection:
  `SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME();`
  If `secret.pat` is missing, ask the attendee to save their `vhol_pat` token into it first.
  (Presenters may use `--connection <name>` instead.)
- If `setup_postgres.py` says the instance exists but `pg_creds.json` is missing, the password
  is lost: tell the attendee, and with their confirmation drop `RETAIL_HOL_PG` and re-run.

## Object Model (single source of truth)

### Part 1 — Environment + Openflow deployment (`solutions/01_environment.sql`, `02_openflow_deployment.sql`)
| Object | Name |
|---|---|
| Data role | `RETAIL_HOL_ROLE` (granted to current user and SYSADMIN, plus `SNOWFLAKE.CORTEX_USER`) |
| Warehouse | `RETAIL_HOL_WH` XSMALL, AUTO_SUSPEND 60 |
| Admin DB | `RETAIL_HOL_ADMIN` with schemas `SECRETS`, `NETWORK` |
| Destination DB | `RETAIL_HOL_ICEBERG` with `CATALOG='SNOWFLAKE'`, `EXTERNAL_VOLUME='SNOWFLAKE_MANAGED'` |
| PG network rule / policy | `RETAIL_HOL_ADMIN.NETWORK.RETAIL_HOL_INGRESS_RULE` (POSTGRES_INGRESS) / `RETAIL_HOL_NETWORK_POLICY` |
| Egress rule / EAI | `RETAIL_HOL_ADMIN.NETWORK.RETAIL_HOL_EGRESS_RULE` (HOST_PORT, placeholder until Part 2) / `RETAIL_HOL_POSTGRES_EAI` |
| Openflow namespace | `OPENFLOW_DB.OPENFLOW_SCHEMA` |
| Roles | `OPENFLOW_ADMIN`, `POSTGRES_INGEST_SERVICE_ROLE` (execute-as role) |
| Deployment | `SPCS_SOM` (`DEPLOYMENT_TYPE='SNOWFLAKE'`), ~15 min to ACTIVE |
| Event table | `OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS`, attached to `SPCS_SOM` |

Order matters: run `01_environment.sql` THEN `02_openflow_deployment.sql` (the service
role grants reference `RETAIL_HOL_ICEBERG`, `RETAIL_HOL_ADMIN`, `RETAIL_HOL_WH`, the EAI).
Kick off the deployment and immediately continue to Part 2 — do not block on ACTIVE.

### Part 2 — Postgres source (`solutions/03_postgres_instance.sql`, `scripts/load_retail_data.py`)
- Instance `RETAIL_HOL_PG`: `COMPUTE_FAMILY='STANDARD_M'`, `STORAGE_SIZE_GB=10`,
  `AUTHENTICATION_AUTHORITY=POSTGRES`, `POSTGRES_VERSION=18`,
  `NETWORK_POLICY='RETAIL_HOL_NETWORK_POLICY'`. Created as `RETAIL_HOL_ROLE`.
- Wait for `state = READY` (poll `DESCRIBE POSTGRES INSTANCE` every ~30s).
- Secret `RETAIL_HOL_ADMIN.SECRETS.RETAIL_HOL_PG_PASSWORD` (`GENERIC_STRING`), READ to `RETAIL_HOL_ROLE`.
- `ALTER NETWORK RULE RETAIL_HOL_ADMIN.NETWORK.RETAIL_HOL_EGRESS_RULE SET VALUE_LIST = ('<host>:5432')`.
- Postgres `bronze` schema (loader creates it, with PostGIS) — 5 tables:
  `sales_transactions`, `product_reviews`, `inventory_feed` (JSONB `metadata`, PostGIS
  `warehouse_location`), `customer_comments`, `daily_reviews`. Data is deterministic
  (`random.seed(42)`), dates 2024-01-01 to 2025-02-17.
- Publication `openflow_retail_pub` on all 5 tables.
- **Detect the OS first**, then create the venv at the repo root and install deps:
  - macOS/Linux: `python3 -m venv .venv` -> `.venv/bin/pip install -r scripts/requirements.txt`; interpreter `.venv/bin/python`
  - Windows: `python -m venv .venv` -> `.venv\Scripts\pip.exe install -r scripts\requirements.txt`; interpreter `.venv\Scripts\python.exe` (no `uv`, no POSIX paths)
- Instance + secret + egress: `<venv-python> scripts/setup_postgres.py --account <ORG-ACCOUNT>` (~5 min; polls to READY).
- Data + publication: `<venv-python> scripts/load_retail_data.py` (reads `pg_creds.json`).
  Do not modify the loader's data logic.

### Part 3 — Runtime + CDC connector (`solutions/04_runtime_connector.sql`, `references/connector_config.md`)
- Prereq: `SHOW OPENFLOW DEPLOYMENTS` shows `SPCS_SOM` ACTIVE. If not, report the state and wait.
- `GRANT READ ON SECRET ... TO ROLE POSTGRES_INGEST_SERVICE_ROLE` (as ACCOUNTADMIN).
- Runtime `OPENFLOW_DB.OPENFLOW_SCHEMA.POSTGRES_RUNTIME_SOM` IN DEPLOYMENT `SPCS_SOM`,
  `NODE_TYPE=MEDIUM`, `MIN_NODES=1`, `MAX_NODES=1`, `EXECUTE_AS_ROLE=POSTGRES_INGEST_SERVICE_ROLE`,
  `EXTERNAL_ACCESS_INTEGRATIONS=(RETAIL_HOL_POSTGRES_EAI)`. Wait for ACTIVE.
- Tasks `SUSPEND_POSTGRES_RUNTIME_SOM` (5 PM PT) / `RESUME_POSTGRES_RUNTIME_SOM` (6 AM PT). Leave them suspended unless asked.
- Connector `POSTGRES_INGEST` — **configured with SQL, not the wizard.** Run
  `<venv-python> scripts/configure_connector.py --account <ORG-ACCOUNT>`. It does
  `CREATE OPENFLOW CONNECTOR ... FROM DEFINITION OPENFLOW_POSTGRES_CDC` -> waits out CREATING ->
  `GET` live `config.json` to `./connector/` -> sets values -> `PUT` JDBC jar + config to the live
  **directory** -> `COMMIT` -> wait stable -> `START` -> wait stable, and prints the changed keys.
  Show the attendee the changed-keys list. Details/format: `references/connector_config.md`.
- Destination: `RETAIL_HOL_ICEBERG`, schema strategy `{schema}` (lands in `RETAIL_HOL_ICEBERG.BRONZE`),
  Iceberg v3 tables, warehouse `RETAIL_HOL_WH`, ingestion type Full (snapshot + CDC).

### Part 4 — Silver + Gold Dynamic Iceberg Tables (`solutions/05_silver.sql`, `06_gold.sql`)
First (as ACCOUNTADMIN) grant `RETAIL_HOL_ROLE` USAGE on `RETAIL_HOL_ICEBERG.BRONZE` and
SELECT on all + future tables and Iceberg tables. Then as `RETAIL_HOL_ROLE`:
| Table | Lag | Notes |
|---|---|---|
| `SILVER_MANAGED_ICEBERG.SILVER_SALES` | DOWNSTREAM | unpivot 5 regional unit columns -> REGION rows |
| `SILVER_MANAGED_ICEBERG.SILVER_INVENTORY` | 5 minutes | flatten JSONB, STOCK_HEALTH (CRITICAL/LOW/NORMAL/OVERSTOCKED), lon/lat |
| `SILVER_MANAGED_ICEBERG.SILVER_PRODUCT_REVIEWS` | 10 minutes | `CORTEX.SENTIMENT` + `CLASSIFY_TEXT` theme |
| `GOLD_MANAGED_ICEBERG.DAILY_PRODUCT_PERFORMANCE` | 10 minutes | FROZEN WHERE > 7 days |
| `GOLD_MANAGED_ICEBERG.CUSTOMER_VOICE_ANALYTICS` | 15 minutes | SENTIMENT + SUMMARIZE + CLASSIFY_TEXT, FROZEN > 14 days |
| `GOLD_MANAGED_ICEBERG.WEEKLY_PRODUCT_SCORECARD` | 1 hour | reads DAILY_PRODUCT_PERFORMANCE, FROZEN > 30 days |
All: `CREATE OR REPLACE DYNAMIC ICEBERG TABLE`, `WAREHOUSE=RETAIL_HOL_WH`, `REFRESH_MODE=ADAPTIVE`.
No CATALOG/EXTERNAL_VOLUME clauses — they inherit Snowflake-managed storage from the database.
Bronze column names are UPPERCASE (connector uses case-insensitive identifiers).

### Part 5 — Semantic View + Agent (`solutions/07_semantic_view.sql`, `08_agent.sql`, `references/agent_spec.md`)
- Semantic view `RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG.RETAIL_PRODUCT_INTELLIGENCE`
  via `CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML('RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG', $$...$$)`.
  Use the YAML verbatim from `solutions/07_semantic_view.sql`.
- Agent `RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG.RETAIL_ANALYST_AGENT`, `CREATE OR REPLACE AGENT ... FROM SPECIFICATION $$ ... $$`
  verbatim from `solutions/08_agent.sql` (`models.orchestration: auto`, budget 30s / 16000 tokens).
  Dollar-quote with plain `$$` (named tags like `$spec$` fail in CoCo's SQL path).
- To change the agent, re-run the full CREATE OR REPLACE statement; do not use a workspace
  file edit/redeploy path.
- Tell the attendee to chat in **Snowsight -> AI & ML -> Agents -> Retail Analyst Agent**
  (or Snowflake Intelligence/CoWork if they ran the optional grant block). Programmatic
  option: `SNOWFLAKE.CORTEX.DATA_AGENT_RUN` (example in `08_agent.sql`).

## Preflight (run before Part 1)
```sql
SELECT CURRENT_REGION() AS region, CURRENT_ACCOUNT() AS account;
SHOW OPENFLOW DEPLOYMENTS;            -- command must be recognized
SHOW POSTGRES INSTANCES;              -- command must be recognized
SELECT SNOWFLAKE.CORTEX.SENTIMENT('Smells amazing') AS cortex_ok;
```
If any fails with "unsupported"/"unknown command", stop and tell the attendee which
feature is unavailable in this account/region. (Openflow terms of service may need to be
accepted once by ORGADMIN; if deployment creation fails mentioning terms, say so.)

## Workflow (one prompt each)
0. Connection + skill check, Preflight.
1. Environment + kick off Openflow deployment (do not wait). Checkpoint D: `SHOW OPENFLOW DEPLOYMENTS` (expect CREATING/…).
2. Postgres instance -> READY -> pg_creds.json -> secret + egress rule -> venv + loader. Checkpoint P.
3. (Deployment ACTIVE) Runtime -> ACTIVE -> tasks -> connector via SQL -> START. Checkpoint C.
4. Bronze grants -> Silver -> Gold. Checkpoints S, G.
5. Semantic view -> agent -> ask persona questions (from `references/agent_spec.md`) with DATA_AGENT_RUN, then point to Snowsight chat.
   Data note: the generated inventory is never CRITICAL/LOW (~86% OVERSTOCKED), so the Supply Chain story is
   overstock + rebalancing, not stock-outs. The 30 s budget can cut off long answers; suggest "continue".
6. Cleanup only when explicitly asked: `solutions/99_cleanup.sql` (confirm first — destructive).

## Checkpoints
- **D (deployment):** `SHOW OPENFLOW DEPLOYMENTS;` -> `SPCS_SOM` state. ACTIVE needed before Part 3.
- **P (Postgres):** loader prints sales_transactions 4,375 / daily_reviews 4,375 / product_reviews 512 /
  customer_comments 200 / inventory_feed 634 (total 10,096), and the 5 tables in `openflow_retail_pub`.
- **R (runtime):** `DESCRIBE OPENFLOW RUNTIME POSTGRES_RUNTIME_SOM;` -> ACTIVE.
- **C (CDC):** `SHOW ICEBERG TABLES IN SCHEMA RETAIL_HOL_ICEBERG.BRONZE;` shows 5 tables, then
  per-table `COUNT(*)` equals the loader counts (snapshot lands ~1–3 min after START).
  If empty after ~5 min, query `OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS` for `severity_text = 'ERROR'`.
- **S (silver):** `SHOW DYNAMIC TABLES IN SCHEMA RETAIL_HOL_ICEBERG.SILVER_MANAGED_ICEBERG;` -> 3 tables, is_iceberg = true, ADAPTIVE
  (SILVER_SALES 21,875 rows = 4,375 x 5 regions; SILVER_INVENTORY 634; SILVER_PRODUCT_REVIEWS 512).
  Peek: lowest-sentiment reviews from `SILVER_PRODUCT_REVIEWS` with `AI_REVIEW_THEME`.
- **G (gold):** `SHOW DYNAMIC TABLES IN SCHEMA RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG;` -> 3 tables with `immutable_where` set; refresh history query in `06_gold.sql`.
- **A (agent):** `SHOW AGENTS IN SCHEMA RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG;` and one DATA_AGENT_RUN answer.

## Why it matters (say one line after each part)
1. Infrastructure-as-SQL, least-privilege by construction (connector runs as a single ingest role), observable from minute one (event table).
2. OLTP lives in the same account as analytics — no egress, one security perimeter.
3. CDC without a third-party engine: the Openflow runtime is Snowflake-managed SPCS; connector config is code (config.json, versioned, committed).
4. Open format with zero setup (Snowflake-managed Iceberg), ADAPTIVE incremental refresh, FROZEN regions stop re-processing history, AI enrichment inline in SQL.
5. The agent writes the SQL; one semantic model answers all four personas; budgets cap cost.

## Stopping points
- Do not start Part 3 until the deployment is ACTIVE; do not START the connector until COMMIT is stable.
- Confirm with the attendee before running `99_cleanup.sql`.

## References
- `references/object_model.md` — part-by-part pointer to verbatim DDL in `solutions/` + gotchas.
- `references/connector_config.md` — SQL connector configuration procedure and value map.
- `references/agent_spec.md` — persona question bank and agent notes.
