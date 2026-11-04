"""Act 4 helper: prove CDC is live by inserting new sales rows into Postgres and watching them land in Bronze.

Inserts N rows into bronze.sales_transactions (dated today) using pg_creds.json, then polls
RETAIL_HOL_ICEBERG.BRONZE.SALES_TRANSACTIONS in Snowflake until the new ids arrive.

Auth for the Snowflake side (pick one):
  --account ORG-ACCOUNT    uses user VHOLuser + the PAT in secret.pat (repo root)
  --connection NAME        uses a named connection from ~/.snowflake/connections.toml
"""
import argparse
import json
import os
import random
import time
from datetime import date

import psycopg2
import snowflake.connector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def snowflake_connect(args):
    if args.connection:
        return snowflake.connector.connect(connection_name=args.connection)
    with open(os.path.join(ROOT, "secret.pat")) as f:
        token = f.read().strip()
    return snowflake.connector.connect(
        account=args.account, user="VHOLuser", authenticator="PROGRAMMATIC_ACCESS_TOKEN", token=token
    )


def main():
    p = argparse.ArgumentParser()
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--account")
    g.add_argument("--connection")
    p.add_argument("--product", default="Frosted Juniper")
    p.add_argument("--rows", type=int, default=5)
    args = p.parse_args()

    with open(os.path.join(ROOT, "pg_creds.json")) as f:
        creds = json.load(f)
    pg = psycopg2.connect(host=creds["host"], port=creds.get("port", 5432), dbname=creds.get("database", "postgres"),
                          user=creds.get("user", "snowflake_admin"), password=creds["password"], sslmode="require")
    pg.autocommit = True
    cur = pg.cursor()
    ids = []
    for _ in range(args.rows):
        cur.execute(
            "INSERT INTO bronze.sales_transactions "
            "(product_name, transaction_date, units_online, units_ne, units_nw, units_se, units_sw) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING id",
            (args.product, date.today(), *[random.randint(20, 300) for _ in range(5)]),
        )
        ids.append(cur.fetchone()[0])
    pg.close()
    inserted_at = time.time()
    print(f"Inserted {len(ids)} rows into Postgres bronze.sales_transactions (ids {ids[0]}..{ids[-1]})")

    sf = snowflake_connect(args)
    sc = sf.cursor()
    sc.execute("USE ROLE ACCOUNTADMIN")
    id_list = ",".join(str(i) for i in ids)
    for _ in range(40):
        sc.execute(f"SELECT COUNT(*) FROM RETAIL_HOL_ICEBERG.BRONZE.SALES_TRANSACTIONS WHERE ID IN ({id_list})")
        landed = sc.fetchone()[0]
        elapsed = int(time.time() - inserted_at)
        print(f"  {elapsed:>4}s  {landed}/{len(ids)} rows in Bronze")
        if landed == len(ids):
            print(f"CDC confirmed: all new rows reached Bronze in ~{elapsed}s")
            break
        time.sleep(10)
    else:
        print("Rows not in Bronze yet. Check the dashboard and the error-log query in solutions/04b_observability.sql.")
    sf.close()


if __name__ == "__main__":
    main()
