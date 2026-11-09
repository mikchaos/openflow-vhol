"""Act 4 helper: prove CDC is live by changing data in Postgres and watching it land in Bronze.

Two modes:
  (default)      one-shot: insert N sales rows (dated today), then poll Bronze until they all arrive.
  --continuous   a store that keeps trading: every --interval seconds, insert sales rows, insert a
                 product review, and update an inventory level (an UPDATE, not just inserts). Every
                 --check-every seconds it prints how far Bronze is behind Postgres. Runs for
                 --minutes (default 20) or until Ctrl+C. This keeps the Connector Observability
                 dashboard and the latency metrics in solutions/04b_observability.sql moving.

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

# Same 12 SKUs as scripts/load_retail_data.py (product_id = position + 1).
PRODUCTS = [
    'Frosted Juniper', 'Peachwood Breeze', 'Golden Amberleaf',
    'Lavender Honeycomb', 'Sea Salt Blossom', 'Harvest Thyme',
    'Rainleaf', 'Lemon Verbena Grove', 'Citrus Petal',
    'Vanilla Cedarlight', 'Spiced Oak & Apple', 'Meadow Bloom'
]
REVIEWS = [
    (5, 'Obsessed', 'Fills the whole room and burns evenly. Already ordered two more.'),
    (4, 'Lovely scent', 'Really nice throw, the jar is pretty too. Shipping took a while.'),
    (3, 'It is fine', 'Smells good up close but I expected a stronger throw.'),
    (2, 'Disappointed', 'Tunneled after the first burn and the label peeled off.'),
    (1, 'Arrived broken', 'The jar was cracked on arrival and support has not replied.'),
]
SALES_SQL = ("INSERT INTO bronze.sales_transactions "
             "(product_name, transaction_date, units_online, units_ne, units_nw, units_se, units_sw) "
             "VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING id")


def snowflake_connect(args):
    if args.connection:
        return snowflake.connector.connect(connection_name=args.connection)
    with open(os.path.join(ROOT, "secret.pat")) as f:
        token = f.read().strip()
    return snowflake.connector.connect(
        account=args.account, user="VHOLuser", authenticator="PROGRAMMATIC_ACCESS_TOKEN", token=token
    )


def postgres_connect():
    with open(os.path.join(ROOT, "pg_creds.json")) as f:
        creds = json.load(f)
    pg = psycopg2.connect(host=creds["host"], port=creds.get("port", 5432), dbname=creds.get("database", "postgres"),
                          user=creds.get("user", "snowflake_admin"), password=creds["password"], sslmode="require")
    pg.autocommit = True
    return pg


def insert_sales(cur, product):
    cur.execute(SALES_SQL, (product, date.today(), *[random.randint(20, 300) for _ in range(5)]))
    return cur.fetchone()[0]


def one_shot(args, pg, sc):
    cur = pg.cursor()
    ids = [insert_sales(cur, args.product) for _ in range(args.rows)]
    inserted_at = time.time()
    print(f"Inserted {len(ids)} rows into Postgres bronze.sales_transactions (ids {ids[0]}..{ids[-1]})")

    id_list = ",".join(str(i) for i in ids)
    for _ in range(40):
        sc.execute(f"SELECT COUNT(*) FROM RETAIL_HOL_ICEBERG.BRONZE.SALES_TRANSACTIONS WHERE ID IN ({id_list})")
        landed = sc.fetchone()[0]
        elapsed = int(time.time() - inserted_at)
        print(f"  {elapsed:>4}s  {landed}/{len(ids)} rows in Bronze")
        if landed == len(ids):
            print(f"CDC confirmed: all new rows reached Bronze in ~{elapsed}s")
            return
        time.sleep(10)
    print("Rows not in Bronze yet. Check the dashboard and the error-log query in solutions/04b_observability.sql.")


def continuous(args, pg, sc):
    cur = pg.cursor()
    cur.execute("SELECT MIN(id), MAX(id) FROM bronze.inventory_feed")
    inv_min, inv_max = cur.fetchone()
    stop_at = time.time() + args.minutes * 60
    totals = {"sales": 0, "reviews": 0, "inventory updates": 0}
    last_check = 0.0
    print(f"Continuous generator: ~{args.sales_per_tick} sales + 1 review + 1 inventory update every "
          f"{args.interval}s for {args.minutes} min (Ctrl+C to stop).")
    try:
        while time.time() < stop_at:
            for _ in range(args.sales_per_tick):
                insert_sales(cur, random.choice(PRODUCTS))
            totals["sales"] += args.sales_per_tick

            i = random.randrange(len(PRODUCTS))
            stars, title, body = random.choice(REVIEWS)
            cur.execute(
                "INSERT INTO bronze.product_reviews (product_id, product_name, title, body, star_rating, author, "
                "submitted_at, helpful_votes, api_source) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, 'live-generator')",
                (i + 1, PRODUCTS[i], title, body, stars, f"shopper{random.randint(1000, 9999)}",
                 date.today(), random.randint(0, 20)),
            )
            totals["reviews"] += 1

            # An UPDATE, so the demo shows CDC carrying changes, not just new rows.
            cur.execute("UPDATE bronze.inventory_feed SET qty_online = GREATEST(qty_online - %s, 0) WHERE id = %s",
                        (random.randint(1, 15), random.randint(inv_min, inv_max)))
            totals["inventory updates"] += 1

            if time.time() - last_check >= args.check_every:
                last_check = time.time()
                cur.execute("SELECT MAX(id), COUNT(*) FROM bronze.sales_transactions")
                pg_max, pg_count = cur.fetchone()
                sc.execute("SELECT MAX(ID), COUNT(*) FROM RETAIL_HOL_ICEBERG.BRONZE.SALES_TRANSACTIONS")
                sf_max, sf_count = sc.fetchone()
                behind = pg_count - (sf_count or 0)
                print(f"  {time.strftime('%H:%M:%S')}  written {totals}  |  sales rows: Postgres {pg_count:,} "
                      f"/ Bronze {sf_count or 0:,}  ({behind:,} in flight, max id {pg_max} vs {sf_max})")
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\nStopped by user.")
    print(f"Generator finished: {totals}. Check latency with the db.commit.to.merge.latency query in "
          f"solutions/04b_observability.sql.")


def main():
    p = argparse.ArgumentParser()
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--account")
    g.add_argument("--connection")
    p.add_argument("--product", default="Frosted Juniper", help="one-shot mode: product for the new rows")
    p.add_argument("--rows", type=int, default=5, help="one-shot mode: rows to insert")
    p.add_argument("--continuous", action="store_true", help="keep generating changes until --minutes or Ctrl+C")
    p.add_argument("--minutes", type=float, default=20, help="continuous mode: how long to run")
    p.add_argument("--interval", type=float, default=5, help="continuous mode: seconds between ticks")
    p.add_argument("--sales-per-tick", type=int, default=3, help="continuous mode: sales rows per tick")
    p.add_argument("--check-every", type=float, default=30, help="continuous mode: seconds between Bronze checks")
    args = p.parse_args()

    pg = postgres_connect()
    sf = snowflake_connect(args)
    sc = sf.cursor()
    sc.execute("USE ROLE ACCOUNTADMIN")
    try:
        (continuous if args.continuous else one_shot)(args, pg, sc)
    finally:
        pg.close()
        sf.close()


if __name__ == "__main__":
    main()
