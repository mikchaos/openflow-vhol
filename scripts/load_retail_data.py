"""Retail HOL data loader (from Notebook 01, cells 2-11).

Connects to the Snowflake Managed Postgres instance RETAIL_HOL_PG, creates the
`bronze` schema + 5 tables (JSONB + PostGIS), loads deterministic retail data
(random.seed(42)), and creates the `openflow_retail_pub` publication for CDC.

Credentials are read from pg_creds.json (gitignored, written by CoCo in Part 2):
  {"host": "...", "user": "snowflake_admin", "password": "..."}
The password is never printed.
"""
import json
import os
import sys

import psycopg2

CREDS_FILE = os.environ.get("PG_CREDS_FILE", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pg_creds.json"))
with open(CREDS_FILE) as f:
    _creds = json.load(f)

POSTGRES_HOST = _creds["host"]
POSTGRES_PASSWORD = _creds["password"]
POSTGRES_USER = _creds.get("user", "snowflake_admin")
POSTGRES_DB = _creds.get("database", "postgres")
POSTGRES_PORT = int(_creds.get("port", 5432))

# cell 1: Connection Setup for PostgreSQL (uses variables from Configuration cell above)

import psycopg2

conn = psycopg2.connect(
    host=POSTGRES_HOST,
    port=POSTGRES_PORT,
    dbname=POSTGRES_DB,
    user=POSTGRES_USER,
    password=POSTGRES_PASSWORD,
    sslmode='require'
)
conn.autocommit = True
cur = conn.cursor()
cur.execute("SELECT version();")
print(f"Connected to: {cur.fetchone()[0]}")

# Cell 2: Drop existing schema in PostgreSQL Instance (clean slate for fresh run)
cur.execute("DROP SCHEMA IF EXISTS bronze CASCADE;")
print("Dropped existing 'bronze' schema (if any). Starting fresh.")

# Cell 3: Create Schema and Tables in PostgreSQL Instance

cur.execute("CREATE SCHEMA IF NOT EXISTS bronze;")
cur.execute("CREATE EXTENSION IF NOT EXISTS postgis;")

DDL_STATEMENTS = [
    """CREATE TABLE IF NOT EXISTS bronze.sales_transactions (
        id SERIAL PRIMARY KEY,
        product_name TEXT NOT NULL,
        transaction_date DATE NOT NULL,
        units_online INT NOT NULL DEFAULT 0,
        units_ne INT NOT NULL DEFAULT 0,
        units_nw INT NOT NULL DEFAULT 0,
        units_se INT NOT NULL DEFAULT 0,
        units_sw INT NOT NULL DEFAULT 0,
        created_at TIMESTAMPTZ DEFAULT NOW()
    )""",
    """CREATE TABLE IF NOT EXISTS bronze.product_reviews (
        id SERIAL PRIMARY KEY,
        product_id INT NOT NULL,
        product_name TEXT NOT NULL,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        star_rating INT NOT NULL CHECK (star_rating BETWEEN 1 AND 5),
        author TEXT NOT NULL,
        submitted_at DATE NOT NULL,
        is_verified BOOLEAN DEFAULT TRUE,
        helpful_votes INT NOT NULL DEFAULT 0,
        moderation_status TEXT NOT NULL DEFAULT 'approved',
        api_source TEXT NOT NULL DEFAULT 'web',
        created_at TIMESTAMPTZ DEFAULT NOW()
    )""",
    """CREATE TABLE IF NOT EXISTS bronze.inventory_feed (
        id SERIAL PRIMARY KEY,
        sku_name TEXT NOT NULL,
        snapshot_date DATE NOT NULL,
        qty_online INT NOT NULL DEFAULT 0,
        qty_northeast INT NOT NULL DEFAULT 0,
        qty_southeast INT NOT NULL DEFAULT 0,
        qty_southwest INT NOT NULL DEFAULT 0,
        qty_northwest INT NOT NULL DEFAULT 0,
        metadata JSONB NOT NULL,
        warehouse_location GEOMETRY(Point, 4326) NOT NULL,
        created_at TIMESTAMPTZ DEFAULT NOW()
    )""",
    """CREATE TABLE IF NOT EXISTS bronze.customer_comments (
        id SERIAL PRIMARY KEY,
        item_name TEXT NOT NULL,
        comment_title TEXT NOT NULL,
        comment_body TEXT NOT NULL,
        user_name TEXT NOT NULL,
        created_at TIMESTAMPTZ DEFAULT NOW(),
        channel TEXT NOT NULL DEFAULT 'web'
    )""",
    """CREATE TABLE IF NOT EXISTS bronze.daily_reviews (
        id SERIAL PRIMARY KEY,
        product TEXT NOT NULL,
        review_date DATE NOT NULL,
        positive_count INT NOT NULL DEFAULT 0,
        negative_count INT NOT NULL DEFAULT 0,
        sentiment_sum NUMERIC(8,4) NOT NULL DEFAULT 0,
        created_at TIMESTAMPTZ DEFAULT NOW()
    )""",
]

for stmt in DDL_STATEMENTS:
    cur.execute(stmt)

print("Schema 'bronze' and all 5 tables created successfully.")

# Cell 4: Data Generation Config

import random
import json
from datetime import date, timedelta
from psycopg2.extras import execute_values

random.seed(42)

PRODUCTS = [
    'Frosted Juniper', 'Peachwood Breeze', 'Golden Amberleaf',
    'Lavender Honeycomb', 'Sea Salt Blossom', 'Harvest Thyme',
    'Rainleaf', 'Lemon Verbena Grove', 'Citrus Petal',
    'Vanilla Cedarlight', 'Spiced Oak & Apple', 'Meadow Bloom'
]

PRODUCT_IDS = {p: i+1 for i, p in enumerate(PRODUCTS)}

# Staggered launch dates - 2 newest products launch later
LAUNCH_DATES = {
    'Frosted Juniper': date(2024, 1, 1),
    'Peachwood Breeze': date(2024, 1, 1),
    'Golden Amberleaf': date(2024, 1, 1),
    'Lavender Honeycomb': date(2024, 1, 1),
    'Sea Salt Blossom': date(2024, 1, 1),
    'Harvest Thyme': date(2024, 1, 1),
    'Rainleaf': date(2024, 1, 1),
    'Lemon Verbena Grove': date(2024, 1, 1),
    'Citrus Petal': date(2024, 1, 1),
    'Vanilla Cedarlight': date(2024, 1, 1),
    'Spiced Oak & Apple': date(2024, 10, 15),  # Newer scent
    'Meadow Bloom': date(2024, 11, 1),         # Newest scent
}

END_DATE = date(2025, 2, 17)

CHANNELS = ['web', 'mobile', 'email', 'social', 'in_store']
API_SOURCES = ['web', 'mobile_app', 'email_campaign', 'social_media']

FIRST_NAMES = ['Alex','Jordan','Taylor','Morgan','Casey','Riley','Quinn','Avery',
               'Dakota','Sage','Rowan','Finley','Harper','Emerson','Parker','Skyler',
               'Blake','Cameron','Hayden','Reese','Drew','Logan','Jamie','Kendall']
LAST_NAMES = ['Chen','Patel','Smith','Garcia','Kim','Nguyen','Williams','Brown',
              'Jones','Miller','Davis','Wilson','Anderson','Thomas','Jackson','White']

# Warehouse locations (lon, lat) - major US distribution hubs
WAREHOUSE_LOCATIONS = [
    (-87.6298, 41.8781),   # Chicago (Northeast hub)
    (-118.2437, 34.0522),  # Los Angeles (Southwest hub)
    (-95.3698, 29.7604),   # Houston (Southeast hub)
    (-122.4194, 37.7749),  # San Francisco (Northwest hub)
    (-73.9857, 40.7484),   # New York (Online fulfillment)
]

print(f"Data config: {len(PRODUCTS)} products")
print(f"  Date range: {min(LAUNCH_DATES.values())} to {END_DATE}")
print(f"  Newest products: Spiced Oak & Apple (Oct 2024), Meadow Bloom (Nov 2024)")

# Cell 5: Insert Sales Transactions (regional units per product per day)

print("Inserting sales_transactions...")
batch = []
for product in PRODUCTS:
    launch = LAUNCH_DATES[product]
    current = launch
    while current <= END_DATE:
        days_since_launch = (current - launch).days
        boost = 1.3 if days_since_launch < 30 else 1.0

        units_online = int(random.randint(50, 400) * boost)
        units_ne = int(random.randint(30, 250) * boost)
        units_nw = int(random.randint(20, 200) * boost)
        units_se = int(random.randint(25, 220) * boost)
        units_sw = int(random.randint(20, 180) * boost)

        batch.append((product, current, units_online, units_ne, units_nw, units_se, units_sw))
        current += timedelta(days=1)

execute_values(
    cur,
    """INSERT INTO bronze.sales_transactions
       (product_name, transaction_date, units_online, units_ne, units_nw, units_se, units_sw)
       VALUES %s""",
    batch, page_size=1000
)
print(f"  Inserted {len(batch)} rows into sales_transactions")

# Cell 6: Insert Daily Reviews (positive_count, negative_count, sentiment_sum)

print("Inserting daily_reviews...")
batch = []
for product in PRODUCTS:
    launch = LAUNCH_DATES[product]
    current = launch
    while current <= END_DATE:
        positive = random.randint(3, 35)
        negative = random.randint(0, 8)
        sentiment_sum = round(
            positive * random.uniform(0.1, 0.5) - negative * random.uniform(0.1, 0.5), 4
        )
        batch.append((product, current, positive, negative, sentiment_sum))
        current += timedelta(days=1)

execute_values(
    cur,
    """INSERT INTO bronze.daily_reviews
       (product, review_date, positive_count, negative_count, sentiment_sum)
       VALUES %s""",
    batch, page_size=1000
)
print(f"  Inserted {len(batch)} rows into daily_reviews")

# Cell 7: Insert Product Reviews (~500 rows)
# Rich text for RAG/semantic search

REVIEW_TEMPLATES = [
    (5, "Absolutely love it!", "I've been using {product} for {weeks} weeks now and it's become my go-to. The scent is {adj1} and {adj2}. Highly recommend to anyone looking for a premium experience."),
    (5, "Best purchase this year", "{product} exceeded all my expectations. The quality is outstanding and the {aspect} is simply unmatched. Will definitely repurchase."),
    (5, "A new favorite", "Just discovered {product} and I'm hooked. It fills my {room} with the most {adj1} aroma. My {person} keeps asking what smells so good!"),
    (5, "Gift hit!", "Bought {product} as a gift for my {person} and they absolutely loved it. The packaging is elegant and the scent is {adj1}. Already ordered more."),
    (5, "Perfect for every day", "I use {product} daily and it never disappoints. The scent lasts {hours} hours and isn't overpowering. Just right."),
    (4, "Really good, minor wish", "{product} is genuinely impressive. The {aspect} is great but I wish the scent lasted a bit longer. Still, very satisfied with my purchase."),
    (4, "Solid quality", "Good product overall. {product} has a {adj1} scent that works well in my {room}. Took off one star because {minor_issue}."),
    (4, "Would recommend", "Been using {product} for about {weeks} weeks. It's {adj1} and {adj2}. Only complaint is {minor_issue}. Otherwise excellent."),
    (4, "Great value", "{product} delivers quality at a fair price. The scent is {adj1} and the {aspect} is well-designed. Minor: {minor_issue}."),
    (3, "It's okay", "{product} is decent but nothing special. The scent is {adj1} enough but fades after {hours} hours. Expected more for the price."),
    (3, "Mixed feelings", "I have mixed feelings about {product}. On one hand, the {aspect} is nice. On the other, {negative_point}. Might try a different variant."),
    (3, "Average experience", "Not bad, not great. {product} does what it promises but doesn't stand out. The {aspect} could be improved."),
    (2, "Disappointed", "Had high hopes for {product} but was let down. {negative_point}. The scent barely lasts {hours} hours. Not worth the premium price."),
    (2, "Not for me", "{product} just doesn't work for my {room}. The scent is too {adj_neg} and {negative_point}. Returning it."),
    (1, "Waste of money", "Extremely disappointed with {product}. {negative_point}. The {aspect} feels cheap and the scent is nothing like described. Avoid."),
]

ADJECTIVES_POS = ['refreshing','soothing','invigorating','delightful','subtle','warm','crisp','elegant','luxurious','calming']
ADJECTIVES_NEG = ['overpowering','artificial','weak','chemical','cloying']
ASPECTS = ['throw','burn time','wax quality','fragrance blend','packaging','wick design','glass container']
ROOMS = ['living room','bedroom','bathroom','office','kitchen','studio']
PERSONS = ['wife','husband','mom','sister','friend','coworker','roommate']
MINOR_ISSUES = ['the lid is hard to open','shipping took a while','the label peeled off','slightly smaller than expected']
NEGATIVE_POINTS = ['it gave me a headache','the scent is nothing like the description','it arrived damaged','the color is off-putting','barely any fragrance']

print("Inserting product_reviews...")
batch = []
for product in PRODUCTS:
    product_id = PRODUCT_IDS[product]
    launch = LAUNCH_DATES[product]
    num_reviews = random.randint(38, 46)

    for _ in range(num_reviews):
        template = random.choice(REVIEW_TEMPLATES)
        rating, title, body_tmpl = template

        body = body_tmpl.format(
            product=product,
            weeks=random.randint(1, 12),
            hours=random.randint(2, 8),
            adj1=random.choice(ADJECTIVES_POS),
            adj2=random.choice(ADJECTIVES_POS),
            adj_neg=random.choice(ADJECTIVES_NEG),
            aspect=random.choice(ASPECTS),
            room=random.choice(ROOMS),
            person=random.choice(PERSONS),
            minor_issue=random.choice(MINOR_ISSUES),
            negative_point=random.choice(NEGATIVE_POINTS)
        )

        author = f"{random.choice(FIRST_NAMES)} {random.choice(LAST_NAMES)}"
        days_after_launch = random.randint(7, (END_DATE - launch).days)
        submitted_at = launch + timedelta(days=days_after_launch)
        is_verified = random.random() > 0.15
        helpful_votes = random.randint(0, 50)
        moderation_status = random.choices(['approved', 'pending', 'rejected'], weights=[85, 10, 5])[0]
        api_source = random.choice(API_SOURCES)

        batch.append((product_id, product, title, body, rating, author,
                      submitted_at, is_verified, helpful_votes, moderation_status, api_source))

execute_values(
    cur,
    """INSERT INTO bronze.product_reviews
       (product_id, product_name, title, body, star_rating, author,
        submitted_at, is_verified, helpful_votes, moderation_status, api_source)
       VALUES %s""",
    batch, page_size=500
)
print(f"  Inserted {len(batch)} rows into product_reviews")

# Cell 8: Insert Customer Comments (~200 rows)

COMMENT_TITLES = [
    "Love this scent!", "Not what I expected", "Great gift idea",
    "Could be better", "My new favorite", "Overpriced",
    "Perfect for my home", "Smells amazing", "Arrived damaged",
    "Will buy again", "Just okay", "Exceeded expectations",
    "Not worth the hype", "Beautiful packaging", "Long-lasting fragrance",
    "Too strong", "Subtle and elegant", "Fast shipping!",
    "Poor quality", "Recommend to everyone"
]

COMMENT_BODIES = {
    'positive': [
        "The {product} scent is absolutely divine. It reminds me of {memory}. Would buy again in a heartbeat.",
        "Every time I light {product}, my whole house smells amazing for hours. Best purchase this year.",
        "Love how {product} fills the room without being overpowering. Perfect balance.",
        "Got {product} as a gift and the recipient was thrilled. Beautiful packaging too.",
        "{product} lasts forever! I've had mine for months and it's still going strong.",
        "The quality of {product} is unmatched. You can tell premium ingredients were used.",
    ],
    'negative': [
        "I find {product} a bit too strong for my taste. Wish it were more subtle. Returning it.",
        "The scent of {product} doesn't match what's described on the website at all. Disappointed.",
        "Waited 3 weeks for {product} to arrive and the box was crushed. Unacceptable.",
        "{product} burned through way too fast. Only lasted about a week of regular use.",
        "Honestly, {product} is overpriced for what you get. Expected much more quality.",
        "Tried to return {product} and the process was a nightmare. Took weeks to resolve.",
    ],
    'neutral': [
        "{product} has a nice scent but it's not as unique as I expected. Average quality.",
        "Shipping for {product} was about average \u2014 arrived in a week. Product is fine.",
        "The price of {product} is comparable to similar products. Nothing special.",
        "{product} packaging is standard. Nothing special but gets the job done.",
        "Bought {product} as a housewarming gift. Recipient said it was nice.",
        "The burn time on {product} is about what I expected \u2014 standard for the size.",
    ]
}

MEMORIES = ['a spring garden', 'walking through a forest', "my grandmother's kitchen",
            'a coastal breeze', 'holiday mornings', 'a warm library']

print("Inserting customer_comments...")
batch = []
for i in range(200):
    product = random.choice(PRODUCTS)
    sentiment_type = random.choices(['positive', 'negative', 'neutral'], weights=[50, 25, 25])[0]
    title = random.choice(COMMENT_TITLES)
    body_template = random.choice(COMMENT_BODIES[sentiment_type])
    body = body_template.format(product=product, memory=random.choice(MEMORIES))
    user_name = f"{random.choice(FIRST_NAMES)}_{random.choice(LAST_NAMES)}_{random.randint(1,99)}"
    channel = random.choice(CHANNELS)
    days_offset = random.randint(0, (END_DATE - date(2024, 1, 1)).days)
    created_at = date(2024, 1, 1) + timedelta(days=days_offset)

    batch.append((product, title, body, user_name, str(created_at), channel))

execute_values(
    cur,
    """INSERT INTO bronze.customer_comments
       (item_name, comment_title, comment_body, user_name, created_at, channel)
       VALUES %s""",
    batch, page_size=200
)
print(f"  Inserted {len(batch)} rows into customer_comments")

# Cell 9: Insert Inventory Feed (regional qty + JSONB metadata + GEOMETRY)

print("Inserting inventory_feed...")
batch = []
for product in PRODUCTS:
    launch = LAUNCH_DATES[product]
    current = launch
    week_num = 0
    while current <= END_DATE:
        wh_idx = PRODUCT_IDS[product] % len(WAREHOUSE_LOCATIONS)
        lon, lat = WAREHOUSE_LOCATIONS[wh_idx]

        base = random.randint(50000, 200000)
        qty_online = base + random.randint(-10000, 10000)
        qty_northeast = int(base * 0.7) + random.randint(-5000, 5000)
        qty_southeast = int(base * 0.6) + random.randint(-5000, 5000)
        qty_southwest = int(base * 0.5) + random.randint(-5000, 5000)
        qty_northwest = int(base * 0.4) + random.randint(-5000, 5000)

        metadata = json.dumps({
            'supplier': random.choice(['FragranceCo', 'AromaTech', 'ScentWorks', 'PureEssence']),
            'batch_id': f"B{random.randint(1000, 9999)}",
            'quality_score': round(random.uniform(85, 99.5), 1),
            'storage_temp_f': random.randint(60, 72),
            'last_audit': str(current - timedelta(days=random.randint(1, 7))),
            'week_number': week_num + 1
        })

        wkt = f"SRID=4326;POINT({lon} {lat})"
        batch.append((product, current, qty_online, qty_northeast, qty_southeast,
                      qty_southwest, qty_northwest, metadata, wkt))
        current += timedelta(weeks=1)
        week_num += 1

# Use row-by-row insert for ST_GeomFromEWKT
insert_sql = """
    INSERT INTO bronze.inventory_feed
        (sku_name, snapshot_date, qty_online, qty_northeast, qty_southeast,
         qty_southwest, qty_northwest, metadata, warehouse_location)
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s::jsonb, ST_GeomFromEWKT(%s))
"""
for row in batch:
    cur.execute(insert_sql, row)

print(f"  Inserted {len(batch)} rows into inventory_feed")

# Cell 10: Create Publication — registers tables for logical replication

cur.execute("""
    SELECT EXISTS (
        SELECT 1 FROM pg_publication WHERE pubname = 'openflow_retail_pub'
    );
""")
exists = cur.fetchone()[0]

if not exists:
    cur.execute("""
        CREATE PUBLICATION openflow_retail_pub
        FOR TABLE
            bronze.sales_transactions,
            bronze.product_reviews,
            bronze.inventory_feed,
            bronze.customer_comments,
            bronze.daily_reviews;
    """)
    print("Publication 'openflow_retail_pub' created.")
else:
    cur.execute("""
        ALTER PUBLICATION openflow_retail_pub
        SET TABLE
            bronze.sales_transactions,
            bronze.product_reviews,
            bronze.inventory_feed,
            bronze.customer_comments,
            bronze.daily_reviews;
    """)
    print("Publication 'openflow_retail_pub' updated with current table list.")

cur.execute("SELECT * FROM pg_publication_tables WHERE pubname = 'openflow_retail_pub';")
print(f"\nTables in publication:")
for row in cur.fetchall():
    print(f"  - {row[1]}.{row[2]}")

# Cell 11: Verify Row Counts

tables = ['sales_transactions', 'daily_reviews', 'product_reviews',
          'customer_comments', 'inventory_feed']

print("=" * 45)
print(f"{'Table':<25} {'Rows':>8}")
print("-" * 45)
total = 0
for t in tables:
    cur.execute(f"SELECT COUNT(*) FROM bronze.{t};")
    count = cur.fetchone()[0]
    total += count
    print(f"{t:<25} {count:>8,}")
print("-" * 45)
print(f"{'TOTAL':<25} {total:>8,}")
print("=" * 45)
print("\nData population complete! Ready for OpenFlow CDC replication.")

cur.close()
conn.close()
print("Connection closed.")
