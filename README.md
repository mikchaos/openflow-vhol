# Ingestion to Insight: An AI-Ready Retail Pipeline with Openflow

Virtual Hands-On Lab. You run a 12-SKU candle and fragrance brand, with scents like *Frosted Juniper*,
*Vanilla Cedarlight* and *Sea Salt Blossom*. It sells online and through 4 regional store
networks, fulfilled from 5 warehouses. In about an hour you'll take that business from an
operational **Postgres** database to an **AI agent that answers questions in plain English**,
without leaving Snowflake. You build everything by prompting **CoCo (Cortex Code) Desktop**;
you don't paste any SQL.

```
 Snowflake Managed       Openflow Gen2          Snowflake-managed        Dynamic Iceberg         Semantic View
   Postgres (OLTP)  ──▶  PostgreSQL CDC   ──▶   Iceberg  BRONZE   ──▶   SILVER / GOLD    ──▶   + Cortex Agent
   RETAIL_HOL_PG         POSTGRES_INGEST        (open format)           Cortex AI enrich        "Ask anything"
     Part 2                 Parts 1 + 3            Part 3                  Part 4                  Part 5
```

## The story: four people, four tools, zero alignment

| Persona | Asks | Today |
|---|---|---|
| **The Merchandiser** (daily) | "What sold yesterday? Is anything running low?" | Waits for a nightly batch |
| **The VP of Retail** (weekly) | "How did we do? Where are we trending?" | A slide someone built by hand |
| **The CX Lead** (constantly) | "What are customers saying about us right now?" | Reads reviews one at a time |
| **The Supply Chain Planner** | "Which warehouse needs a truck today?" | A spreadsheet export |

Each of them uses a different tool, waits for a different report, and trusts a different copy of the data.

**What you'll build:** one platform, one pipeline, and one agent that answers all four of them. Every
layer runs inside Snowflake under one governance and RBAC model, with no third-party CDC
engine, no data egress, and no ETL glue.

| Part | Chapter | You'll see |
|---|---|---|
| 1 | *Lay the foundation* | Openflow infrastructure created as SQL. It takes ~15 min to provision, so you start it first. |
| 2 | *Open the store* | A Managed Postgres instance filled with ~10,000 rows of retail history |
| 3 | *Stream it in* | Openflow CDC replicating Postgres into open-format Iceberg, with the connector configured by SQL (no wizard) |
| 4 | *Make it make sense* | Silver/Gold Dynamic Iceberg Tables with AI sentiment and classification built in |
| 5 | *Ask it anything* | A semantic view and Cortex Agent answering each persona's question |
| 6 | *Clean up* | Tear everything down |

## What you need

- A **Snowflake event account** (provided to you) with SPCS, Openflow, Snowflake Managed
  Postgres and Cortex AI enabled. You will be ACCOUNTADMIN. The lab checks feature availability
  for you in Part 0.
- **CoCo Desktop** ([download](https://www.snowflake.com/en/product/snowflake-coco/downloads/)).
- **Git** and **Python 3.9+** on your machine (used to load the Postgres data).

## Repo layout

```
README.md                         this file: setup + the full lab story
solutions/                        SQL answer key (00 bootstrap ... 08 agent, 99 cleanup)
scripts/load_retail_data.py       generates + loads the retail data into Postgres, creates the CDC publication
notebooks/                        the original Snowsight notebooks (reference only)
docs/presenter_guide.md           timing, talk track, troubleshooting for presenters
.snowflake/cortex/skills/openflow-retail-vhol/   the VHOL skill (auto-loads in CoCo)
```

## Setup

### A. Get the lab files

1. Clone the repo. CoCo Desktop will ask for this folder when it launches.
   ```
   git clone https://github.com/sfc-gh-skumar-1/openflow-vhol.git
   cd openflow-vhol
   ```
   (No git? Use **Code -> Download ZIP** and unzip it.)

### B. Bootstrap the account (Snowsight)

2. Log in to your event account in **Snowsight** as the provided admin user. Open a worksheet
   and run `solutions/00_bootstrap.sql` **one block at a time** (highlight a block, then press Cmd/Ctrl+Enter):
   - **Block 1** creates the lab user `VHOLuser`, a lab network policy, and a Programmatic
     Access Token `vhol_pat`. **Copy the `token_secret` now**, because it is shown only once.
   - **Block 2** prints your account identifier (`ORG-ACCOUNT`). Copy it.

### C. Connect CoCo Desktop (as VHOLuser)

3. **Install and launch CoCo Desktop.** When it asks for a project folder, open the repo
   folder you cloned in step 1.
   - Download: https://www.snowflake.com/en/product/snowflake-coco/downloads/
   - Setup/docs: https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code-desktop

   CoCo Desktop is available to all accounts; usage is billed on token consumption, so it
   runs on your trial credits.
4. Open **Connections** and add a new connection:
   - **Account identifier:** the `ORG-ACCOUNT` value from Block 2
   - **User:** `VHOLuser`
   - **Auth:** choose **Programmatic Access Token** and paste the token. If that option isn't
     listed, choose **Password** and paste the PAT into the password field.

   Make it the **active** connection. Alternatively, add it to `~/.snowflake/connections.toml`:
   ```toml
   [connections.openflow_vhol]
   account = "ORG-ACCOUNT"
   user = "VHOLuser"
   authenticator = "PROGRAMMATIC_ACCESS_TOKEN"
   token = "<paste vhol_pat>"
   ```
5. **Pick the model:** the latest Claude Sonnet or Opus, or the latest GPT if Claude isn't listed.

## Run the lab

Each step below is **one prompt** you type into CoCo. The `openflow-retail-vhol` skill makes
sure your objects get exactly the same names and settings as everyone else's. After each
part, CoCo runs a **checkpoint** query and tells you why that step matters.

### Part 0: Ready to build

> Test my Snowflake connection, make sure the openflow-retail-vhol skill is loaded, and run the lab preflight.

CoCo shows your account, user (`VHOLUSER`), role (`ACCOUNTADMIN`) and region. It then checks that
Openflow, Managed Postgres and Cortex AI respond in this account. If the skill isn't loaded, go to
Agent Settings -> Skills -> Local Skills -> **+ Add Local Skill** and pick the repo folder.

---

### Part 1: Lay the foundation (and start the clock)

*An Openflow deployment takes about 15 minutes to become ACTIVE, so you start it first and build
the Postgres source while it provisions.*

> Set up the lab environment: the RETAIL_HOL_ROLE data role, the RETAIL_HOL_WH warehouse, the
> RETAIL_HOL_ADMIN database for secrets and network rules, the RETAIL_HOL_ICEBERG destination
> database on Snowflake-managed Iceberg storage, the Postgres network policy, and the
> RETAIL_HOL_POSTGRES_EAI external access integration.

> Now kick off Openflow: create OPENFLOW_DB.OPENFLOW_SCHEMA, the OPENFLOW_ADMIN role and the
> least-privilege POSTGRES_INGEST_SERVICE_ROLE, the SPCS_SOM Gen2 deployment, and a dedicated
> EVENTS event table attached to it. Don't wait for it to finish.

**Checkpoint D:** `SPCS_SOM` appears in `SHOW OPENFLOW DEPLOYMENTS` while it provisions.

> **Why it matters.** The whole deployment is *infrastructure-as-SQL*: repeatable, reviewable,
> and version-controlled. Before any data moves, admin duties and the connector's identity are
> already separated, so a compromised connector can only affect a single ingest role. Telemetry
> lands in an event table from the first minute.

---

### Part 2: Open the store (the operational source)

*Your store's system of record is a Postgres database. With Snowflake Managed Postgres it runs
in the same account as your analytics.*

> Create the RETAIL_HOL_PG Snowflake Managed Postgres instance for the lab. Save its host and
> snowflake_admin password to pg_creds.json without showing me the password, wait until it's
> READY, then create the Postgres password secret and point the egress rule at the instance host.

> Set up a Python virtual environment for my OS, install scripts/requirements.txt, and run
> scripts/load_retail_data.py to load the retail data and create the CDC publication.

**Checkpoint P:** the loader prints row counts for 5 tables in the `bronze` schema
(`sales_transactions`, `daily_reviews`, `product_reviews`, `customer_comments`, `inventory_feed`,
with JSONB metadata and PostGIS warehouse locations). It also lists the tables in the
`openflow_retail_pub` publication.

> **Why it matters.** OLTP and analytics share one platform and one security perimeter. CDC
> never has to cross clouds or reach an external database.

---

### Part 3: Stream it in (Openflow CDC to Iceberg)

*Check in on Part 1:*

> Is the SPCS_SOM deployment ACTIVE yet?

Once it shows ACTIVE:

> Create the POSTGRES_RUNTIME_SOM Gen2 runtime on SPCS_SOM (medium, one node, running as
> POSTGRES_INGEST_SERVICE_ROLE with the Postgres EAI), plus the suspend/resume cost-control tasks.
> Wait until the runtime is ACTIVE.

> Create the POSTGRES_INGEST PostgreSQL CDC connector with SQL, not the wizard: configure it to
> replicate the bronze schema from RETAIL_HOL_PG into RETAIL_HOL_ICEBERG as Iceberg v3 tables,
> commit the configuration, and start it.

CoCo creates the connector from its catalog definition and downloads its `config.json`. It fills
in your source, secret reference, publication and destination, uploads the file, commits it, and
starts the connector. CoCo shows you the keys it changed. The password is a secret
*reference*, so it never appears in the file.

> Show me the Bronze Iceberg tables Openflow created, and compare their row counts with Postgres.

**Checkpoint C:** 5 Iceberg tables in `RETAIL_HOL_ICEBERG.BRONZE`, and their counts match the loader.

> **Why it matters.** This is CDC without a third-party engine: the Openflow runtime is
> Snowflake-managed SPCS compute running inside your account. The connector's configuration is
> code (a versioned `config.json` with commit and abort), so you can template it for a whole
> fleet of connectors. Data lands as **open Iceberg** from the very first byte.

---

### Part 4: Make it make sense (Silver + Gold with built-in AI)

> Build the Silver layer as Dynamic Iceberg Tables: unpivot sales by region, flatten the inventory
> JSON with stock health and warehouse coordinates, and enrich product reviews with Cortex
> sentiment and theme classification.

> Show me the most negative reviews with their AI sentiment score and theme.

> Build the Gold layer: daily product performance, customer voice analytics with AI summaries
> and intent, and a weekly product scorecard, with frozen regions so history isn't re-processed.

**Checkpoints S and G:** 6 Dynamic Iceberg Tables, all `is_iceberg = true` and `ADAPTIVE`, and
the Gold tables have frozen regions (`immutable_where`).

> **Why it matters.** The data stays in an open format with zero setup: Snowflake-managed Iceberg
> needs no external volume, catalog or IAM. **ADAPTIVE** refresh processes only changed rows, and
> **FROZEN WHERE** stops you paying to re-aggregate history. Sentiment, classification and
> summarization run as plain SQL functions inside the pipeline, so there are no external model calls.

---

### Part 5: Ask it anything

> Create the RETAIL_PRODUCT_INTELLIGENCE semantic view over the Gold tables, then the
> RETAIL_ANALYST_AGENT Cortex Agent that uses it.

Now ask the questions from the start of the story:

> Ask the agent, as the Merchandiser: what are the top 3 and bottom 3 products by total units
> sold, with their positive review percentage?

> As the Supply Chain Planner: which products had critical or low stock health, and for how many days?

> As the CX Lead: which products have the worst customer sentiment, and what are customers complaining about by intent type?

> As the VP of Retail: give me a weekly business review and flag products declining over the last 4 weeks.

Then open **Snowsight -> AI & ML -> Agents -> Retail Analyst Agent** and chat with it directly.
There are 20+ more questions in
`.snowflake/cortex/skills/openflow-retail-vhol/references/agent_spec.md`.

> **Why it matters.** The agent writes the SQL for you. One semantic model serves four personas,
> and a budget caps the cost of every answer. The data it reads is the same open Iceberg data a
> Spark or Trino job could query. Each layer, from an insert into Postgres to a business answer,
> was governed end to end on one platform.

---

### Part 6: Clean up

> Clean up everything this lab created.

CoCo asks you to confirm, then runs `solutions/99_cleanup.sql`. It stops the connector,
terminates the runtime and deployment, and drops the Postgres instance, databases, warehouse
and roles. To remove the `VHOLuser` login, use the teardown block in `00_bootstrap.sql` from
Snowsight. You can't do it from CoCo, because CoCo is logged in as that user.

## How the skill knows all this

You typed plain-English prompts, yet everyone's objects came out identical. That consistency comes
from the **`openflow-retail-vhol` skill** (`.snowflake/cortex/skills/openflow-retail-vhol/`).
CoCo loads it automatically when you open this folder:

- **`SKILL.md`** holds the object model (exact names and settings), the workflow, the checkpoints,
  the secret-handling rules and the "why it matters" lines.
- **`references/object_model.md`** points each part to its verbatim DDL in `solutions/`.
- **`references/connector_config.md`** describes the SQL connector workflow
  (`CREATE OPENFLOW CONNECTOR ... FROM DEFINITION` -> GET/PUT `config.json` -> COMMIT -> START),
  maps each value, and includes a wizard fallback.
- **`references/agent_spec.md`** covers the agent settings and the persona question bank.

### Build your own skill

A skill is a folder containing a `SKILL.md` (YAML front matter with `name` and `description`, then
markdown instructions), plus optional `references/`. Commit it with your repo and it auto-loads
for anyone who opens the project in CoCo Desktop. This skill makes a working template for
encoding your own team's Openflow and pipeline conventions.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Deployment stuck in CREATING | It usually takes ~15 min. If it fails and mentions terms of service, an ORGADMIN must accept the Openflow terms once. |
| Loader can't connect to Postgres | Check that the instance is READY and that `pg_creds.json` has the right host. |
| Connector commit/validation error | Ask CoCo to read the error, fix the named key in `config.json`, re-upload and commit again. |
| Connector running but Bronze is empty | Ask CoCo to "show recent Openflow errors from the event table". The usual causes are an egress rule still set to the placeholder host, or the secret not granted to `POSTGRES_INGEST_SERVICE_ROLE`. |
| SQL connector config is blocked | Use the wizard fallback in `references/connector_config.md`. Everything else stays the same. |
| Agent "not an allowed model" | The spec already uses `orchestration: auto`. Pick a model in Snowsight -> Agent -> Configuration. |

## Credits

Adapted from the *AI-Ready Data Pipeline* retail hands-on lab notebooks (in `notebooks/`) for a
prompt-driven, CoCo Desktop format.
