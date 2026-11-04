"""Part 2 helper: create the RETAIL_HOL_PG Managed Postgres instance without exposing its password.

What it does (same SQL as solutions/03_postgres_instance.sql):
  1. CREATE POSTGRES INSTANCE RETAIL_HOL_PG ... (as RETAIL_HOL_ROLE)
  2. Writes host + snowflake_admin password to pg_creds.json (gitignored)
  3. Waits until the instance state is READY
  4. Creates secret RETAIL_HOL_ADMIN.SECRETS.RETAIL_HOL_PG_PASSWORD (as ACCOUNTADMIN)
  5. Points RETAIL_HOL_ADMIN.NETWORK.RETAIL_HOL_EGRESS_RULE at <host>:5432
Only the host and the last 4 characters of the password are printed.

Auth (pick one):
  --account ORG-ACCOUNT          uses user VHOLuser + the PAT in secret.pat (repo root)
  --connection NAME              uses a named connection from ~/.snowflake/connections.toml
If pg_creds.json already exists and the instance exists, steps 1-2 are skipped (re-run safe).
"""
import argparse
import json
import os
import sys
import time

import snowflake.connector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CREDS = os.path.join(ROOT, "pg_creds.json")
INSTANCE = "RETAIL_HOL_PG"

CREATE_SQL = """
CREATE POSTGRES INSTANCE RETAIL_HOL_PG
  COMPUTE_FAMILY          = 'STANDARD_M'
  STORAGE_SIZE_GB         = 10
  AUTHENTICATION_AUTHORITY = POSTGRES
  POSTGRES_VERSION        = 18
  NETWORK_POLICY          = 'RETAIL_HOL_NETWORK_POLICY'
  COMMENT                 = 'Retail HOL - AI-Ready Data Pipeline demo'
"""


def connect(args):
    if args.connection:
        return snowflake.connector.connect(connection_name=args.connection)
    with open(os.path.join(ROOT, "secret.pat")) as f:
        token = f.read().strip()
    return snowflake.connector.connect(
        account=args.account, user="VHOLuser", authenticator="PROGRAMMATIC_ACCESS_TOKEN", token=token
    )


def describe(cur):
    cur.execute(f"DESCRIBE POSTGRES INSTANCE {INSTANCE}")
    return {r[0]: r[1] for r in cur.fetchall()}


def main():
    p = argparse.ArgumentParser()
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--account")
    g.add_argument("--connection")
    args = p.parse_args()

    conn = connect(args)
    cur = conn.cursor()
    cur.execute("USE ROLE RETAIL_HOL_ROLE")
    cur.execute("USE WAREHOUSE RETAIL_HOL_WH")

    cur.execute(f"SHOW POSTGRES INSTANCES LIKE '{INSTANCE}'")
    exists = cur.fetchone() is not None
    if exists and not os.path.exists(CREDS):
        sys.exit(
            f"{INSTANCE} already exists but pg_creds.json is missing, so the password is unknown. "
            "Reset the snowflake_admin credentials (or drop the instance) and re-run."
        )
    if not exists:
        cur.execute(CREATE_SQL)
        cols = [d[0].lower() for d in cur.description]
        row = dict(zip(cols, cur.fetchone()))
        password = json.loads(row["access_roles"])["snowflake_admin"]
        creds = {"host": row["host"], "user": "snowflake_admin", "password": password,
                 "database": "postgres", "port": 5432}
        with open(CREDS, "w") as f:
            json.dump(creds, f)
        os.chmod(CREDS, 0o600)
        print(f"Created {INSTANCE}; credentials saved to pg_creds.json")

    with open(CREDS) as f:
        creds = json.load(f)

    for _ in range(60):
        state = describe(cur).get("state")
        print(f"  state = {state}")
        if state == "READY":
            break
        time.sleep(20)
    else:
        sys.exit("Instance did not reach READY in 20 minutes; re-run this script to keep waiting.")

    cur.execute("USE ROLE ACCOUNTADMIN")
    cur.execute(
        "CREATE OR REPLACE SECRET RETAIL_HOL_ADMIN.SECRETS.RETAIL_HOL_PG_PASSWORD "
        "TYPE = GENERIC_STRING SECRET_STRING = %s "
        "COMMENT = 'Postgres password for OpenFlow CDC connector (user: snowflake_admin)'",
        (creds["password"],),
    )
    cur.execute("GRANT READ ON SECRET RETAIL_HOL_ADMIN.SECRETS.RETAIL_HOL_PG_PASSWORD TO ROLE RETAIL_HOL_ROLE")
    cur.execute(
        "ALTER NETWORK RULE RETAIL_HOL_ADMIN.NETWORK.RETAIL_HOL_EGRESS_RULE SET VALUE_LIST = (%s)",
        (f"{creds['host']}:5432",),
    )
    print(f"Host:     {creds['host']}")
    print(f"Password: ****{creds['password'][-4:]}  (stored in secret RETAIL_HOL_ADMIN.SECRETS.RETAIL_HOL_PG_PASSWORD)")
    print("Egress rule updated. Next: run scripts/load_retail_data.py")
    conn.close()


if __name__ == "__main__":
    main()
