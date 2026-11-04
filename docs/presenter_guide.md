# Presenter guide — Openflow Retail VHOL

## Run of show (~75 min)
| Min | Part | Presenter does | Attendees do |
|---|---|---|---|
| 0–10 | Setup | Tell the four-personas story. Walk through bootstrap + CoCo connection | Clone, run bootstrap, connect CoCo |
| 10–15 | 0 + 1 | Explain why the deployment goes first (~15 min to ACTIVE) | Preflight, environment, kick off `SPCS_SOM` |
| 15–30 | 2 | Pitch OLTP + analytics on one platform. Show the 5 `bronze` tables and the JSONB/PostGIS columns | Create `RETAIL_HOL_PG`, load data |
| 30–45 | 3 | Highlight the connector-as-code moment: show `config.json`, COMMIT, START | Runtime, connector, Bronze checkpoint |
| 45–60 | 4 | Show AI sentiment on the worst reviews, then FROZEN WHERE in `SHOW DYNAMIC TABLES` | Silver, Gold |
| 60–72 | 5 | Ask each persona's question live in Snowsight Agents chat | Semantic view, agent, questions |
| 72–75 | 6 | Recap the architecture, then cleanup | Cleanup (optional) |

## Talk track (one line per part)
1. "Before any data moves we separate concerns: the connector runs as a single ingest role, and that's the whole blast radius."
2. "The OLTP database lives in the same account as the analytics, so there's no egress and no second security perimeter."
3. "There's no Debezium or Kafka. The CDC engine is Snowflake-managed compute, and its config is a versioned file you commit."
4. "The data is open Iceberg with zero setup. Refresh is adaptive and history is frozen, and the AI is just a SQL function."
5. "Four personas, one semantic model, one agent, and it has a budget."

## Timing risks and mitigations
- **Deployment provisioning (~15 min).** It must start in Part 1. If an attendee is late, have them run Part 1 immediately and do Part 2 while it provisions.
- **Runtime provisioning (2–5 min).** Fill the wait by explaining `EXECUTE_AS_ROLE` and the cost-control tasks.
- **Initial snapshot.** Bronze tables can take a few minutes to appear after START.
- **Cortex in Silver/Gold.** The first refresh of `SILVER_PRODUCT_REVIEWS` and `CUSTOMER_VOICE_ANALYTICS` calls AI functions on every row, so allow a couple of minutes.

## Connector SQL path: rehearse before the event
The SQL steps (`CREATE OPENFLOW CONNECTOR ... FROM DEFINITION OPENFLOW_POSTGRES_CDC`, then GET/PUT `config.json`, then `COMMIT` and `START`) follow the Snowflake docs. The exact parameter keys in `config.json`, and how the PostgreSQL JDBC driver asset is referenced, come from the definition itself. **Do a full dry run on an event account and save a known-good `config.json` (with the secret reference, no passwords).** That lets you confirm the value map in `references/connector_config.md`. If the SQL path is blocked on the day, use the wizard fallback documented there.

## Troubleshooting quick reference
- Openflow errors: `SELECT TIMESTAMP, RECORD_ATTRIBUTES, VALUE FROM OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS WHERE RECORD_ATTRIBUTES:"severity_text"='ERROR' ORDER BY TIMESTAMP DESC LIMIT 20;`
- Connector observability: Snowsight -> Ingestion -> Openflow -> Connector Observability -> event table `OPENFLOW_DB.OPENFLOW_SCHEMA.EVENTS`.
- Lost Postgres password: reset the `snowflake_admin` credentials on the instance, then update the secret and `pg_creds.json`.
- Ask CoCo: "use the openflow-observability skill to diagnose POSTGRES_INGEST".

## Cost notes
- The deployment control pool (CPU_X64_S) runs while the deployment exists.
- The runtime (MEDIUM) bills while ACTIVE. Optional suspend/resume tasks are included.
- The Postgres instance is STANDARD_M with 10 GB.
- Run `99_cleanup.sql` after the event.
