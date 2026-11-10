-- Openflow Retail VHOL — Act 6a Semantic View
-- Source: notebooks/04-retail-hol-talk-to-data.ipynb (verbatim DDL). Run as shown; safe to re-run.

-- Setup
USE ROLE RETAIL_HOL_ROLE;
USE WAREHOUSE RETAIL_HOL_WH;
USE DATABASE RETAIL_HOL_ICEBERG;
USE SCHEMA GOLD_MANAGED_ICEBERG;

-- Create Semantic View using YAML specification
CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML(
  'RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG',
  $$name: RETAIL_PRODUCT_INTELLIGENCE
description: >-
  Retail product intelligence model covering daily and weekly performance metrics,
  inventory health, customer sentiment, voice-of-customer analytics, and warehouse
  geolocation for a candle and fragrance retail business with 12 products sold across
  online and 4 regional stores. Warehouses in LA, Houston, NYC, Chicago, SF.

tables:
  - name: DAILY_PRODUCT_PERFORMANCE
    base_table:
      database: RETAIL_HOL_ICEBERG
      schema: GOLD_MANAGED_ICEBERG
      table: DAILY_PRODUCT_PERFORMANCE
    description: >-
      Daily product-level performance combining sales units, inventory position,
      stock health, quality scores, and customer review sentiment.
      Each row is one product on one day. Date range 2024.
    dimensions:
      - name: PRODUCT_NAME
        description: Product name such as Frosted Juniper, Citrus Petal, Lavender Honeycomb
        expr: PRODUCT_NAME
        data_type: VARCHAR
      - name: STOCK_HEALTH_STATUS
        description: Inventory health CRITICAL LOW NORMAL or OVERSTOCKED
        expr: STOCK_HEALTH_STATUS
        data_type: VARCHAR
    time_dimensions:
      - name: PERFORMANCE_DATE
        description: The calendar date of the performance record
        expr: PERFORMANCE_DATE
        data_type: DATE
    facts:
      - name: TOTAL_UNITS_SOLD
        description: Total units sold across all channels for that day
        expr: TOTAL_UNITS_SOLD
        data_type: NUMBER
      - name: ONLINE_UNITS
        description: Units sold via the online e-commerce channel
        expr: ONLINE_UNITS
        data_type: NUMBER
      - name: STORE_UNITS
        description: Units sold across all physical stores combined
        expr: STORE_UNITS
        data_type: NUMBER
      - name: INVENTORY_POSITION
        description: Total inventory stock available across all locations
        expr: INVENTORY_POSITION
        data_type: NUMBER
      - name: QUALITY_SCORE
        description: Product quality score from supplier audit 0 to 100
        expr: QUALITY_SCORE
        data_type: FLOAT
      - name: AVG_DAILY_SENTIMENT
        description: Average daily customer review sentiment score positive means good
        expr: AVG_DAILY_SENTIMENT
        data_type: FLOAT
      - name: POSITIVE_REVIEWS
        description: Count of positive customer reviews received that day
        expr: POSITIVE_REVIEWS
        data_type: NUMBER
      - name: NEGATIVE_REVIEWS
        description: Count of negative customer reviews received that day
        expr: NEGATIVE_REVIEWS
        data_type: NUMBER
    metrics:
      - name: TOTAL_REVENUE_UNITS
        description: Sum of all units sold
        expr: SUM(TOTAL_UNITS_SOLD)
        data_type: NUMBER
      - name: ONLINE_MIX_PERCENTAGE
        description: Percentage of sales from online channel
        expr: ROUND(SUM(ONLINE_UNITS) * 100.0 / NULLIF(SUM(TOTAL_UNITS_SOLD), 0), 1)
        data_type: FLOAT
      - name: AVG_SENTIMENT
        description: Average sentiment score across the period
        expr: AVG(AVG_DAILY_SENTIMENT)
        data_type: FLOAT
      - name: REVIEW_POSITIVITY_RATE
        description: Percentage of reviews that are positive
        expr: ROUND(SUM(POSITIVE_REVIEWS) * 100.0 / NULLIF(SUM(POSITIVE_REVIEWS) + SUM(NEGATIVE_REVIEWS), 0), 1)
        data_type: FLOAT

  - name: WEEKLY_PRODUCT_SCORECARD
    base_table:
      database: RETAIL_HOL_ICEBERG
      schema: GOLD_MANAGED_ICEBERG
      table: WEEKLY_PRODUCT_SCORECARD
    description: >-
      Weekly executive scorecard per product with aggregated KPIs.
      Each row is one product for one week starting Monday.
    dimensions:
      - name: PRODUCT_NAME
        description: Product name joins to DAILY_PRODUCT_PERFORMANCE.PRODUCT_NAME
        expr: PRODUCT_NAME
        data_type: VARCHAR
      - name: WORST_STOCK_STATUS
        description: Worst inventory health status observed during the week
        expr: WORST_STOCK_STATUS
        data_type: VARCHAR
    time_dimensions:
      - name: WEEK_START
        description: The Monday start date of the business week
        expr: WEEK_START
        data_type: DATE
    facts:
      - name: WEEKLY_UNITS_SOLD
        description: Total units sold during the week across all channels
        expr: WEEKLY_UNITS_SOLD
        data_type: NUMBER
      - name: WEEKLY_ONLINE_UNITS
        description: Units sold online during the week
        expr: WEEKLY_ONLINE_UNITS
        data_type: NUMBER
      - name: WEEKLY_STORE_UNITS
        description: Units sold in physical stores during the week
        expr: WEEKLY_STORE_UNITS
        data_type: NUMBER
      - name: ONLINE_MIX_PCT
        description: Percentage of weekly sales from online channel
        expr: ONLINE_MIX_PCT
        data_type: FLOAT
      - name: AVG_INVENTORY
        description: Average inventory position during the week
        expr: AVG_INVENTORY
        data_type: FLOAT
      - name: AVG_QUALITY_SCORE
        description: Average product quality score for the week
        expr: AVG_QUALITY_SCORE
        data_type: FLOAT
      - name: WEEKLY_SENTIMENT
        description: Average customer sentiment for the week
        expr: WEEKLY_SENTIMENT
        data_type: FLOAT
      - name: WEEKLY_POSITIVE
        description: Total positive reviews received during the week
        expr: WEEKLY_POSITIVE
        data_type: NUMBER
      - name: WEEKLY_NEGATIVE
        description: Total negative reviews received during the week
        expr: WEEKLY_NEGATIVE
        data_type: NUMBER
      - name: POSITIVE_REVIEW_PCT
        description: Percentage of weekly reviews that are positive
        expr: POSITIVE_REVIEW_PCT
        data_type: FLOAT
    metrics:
      - name: TOTAL_WEEKLY_VOLUME
        description: Sum of weekly units sold
        expr: SUM(WEEKLY_UNITS_SOLD)
        data_type: NUMBER
      - name: AVG_WEEKLY_SENTIMENT
        description: Average weekly sentiment
        expr: AVG(WEEKLY_SENTIMENT)
        data_type: FLOAT

  - name: CUSTOMER_VOICE_ANALYTICS
    base_table:
      database: RETAIL_HOL_ICEBERG
      schema: GOLD_MANAGED_ICEBERG
      table: CUSTOMER_VOICE_ANALYTICS
    description: >-
      Customer comments enriched with Cortex AI sentiment scoring
      auto-summarization and intent classification.
    dimensions:
      - name: PRODUCT_NAME
        description: Product the comment is about joins to DAILY_PRODUCT_PERFORMANCE.PRODUCT_NAME
        expr: PRODUCT_NAME
        data_type: VARCHAR
      - name: COMMENT_TITLE
        description: Short title of the customer comment
        expr: COMMENT_TITLE
        data_type: VARCHAR
      - name: COMMENT_BODY
        description: Full text of the customer comment
        expr: COMMENT_BODY
        data_type: VARCHAR
      - name: USER_NAME
        description: Username of the commenter
        expr: USER_NAME
        data_type: VARCHAR
      - name: CHANNEL
        description: Channel where comment was received web social or email
        expr: CHANNEL
        data_type: VARCHAR
      - name: AI_SUMMARY
        description: AI generated one line summary of the comment
        expr: AI_SUMMARY
        data_type: VARCHAR
      - name: CUSTOMER_INTENT
        description: AI classified intent praise complaint question suggestion or shipping_issue
        expr: CUSTOMER_INTENT
        data_type: VARCHAR
      - name: SENTIMENT_LABEL
        description: AI sentiment label positive negative neutral or mixed
        expr: SENTIMENT_LABEL
        data_type: VARCHAR
    time_dimensions:
      - name: COMMENT_DATE
        description: Date the comment was posted
        expr: COMMENT_DATE
        data_type: DATE
    facts:
      - name: SENTIMENT_SCORE
        description: AI sentiment score 1 positive 0 neutral or mixed -1 negative (mapped from SENTIMENT_LABEL)
        expr: SENTIMENT_SCORE
        data_type: FLOAT
    metrics:
      - name: TOTAL_COMMENTS
        description: Total number of customer comments
        expr: COUNT(*)
        data_type: NUMBER
      - name: AVG_COMMENT_SENTIMENT
        description: Average sentiment score across comments
        expr: AVG(SENTIMENT_SCORE)
        data_type: FLOAT
      - name: COMPLAINT_RATE
        description: Percentage of comments classified as complaints
        expr: "ROUND(SUM(CASE WHEN CUSTOMER_INTENT = 'complaint' THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(*), 0), 1)"
        data_type: FLOAT

  - name: SILVER_INVENTORY
    base_table:
      database: RETAIL_HOL_ICEBERG
      schema: SILVER_MANAGED_ICEBERG
      table: SILVER_INVENTORY
    description: >-
      Inventory feed with warehouse geolocation. Each row is one SKU snapshot
      at one warehouse. Warehouses are in Los Angeles, Houston, New York,
      Chicago, and San Francisco. Use WAREHOUSE_LONGITUDE and WAREHOUSE_LATITUDE
      for spatial inventory queries. SKU_NAME joins to PRODUCT_NAME in other tables.
    dimensions:
      - name: SKU_NAME
        description: Product SKU name joins to DAILY_PRODUCT_PERFORMANCE.PRODUCT_NAME
        expr: SKU_NAME
        data_type: VARCHAR
      - name: SUPPLIER
        description: Supplier name PureEssence FragranceCo or AromaTech
        expr: SUPPLIER
        data_type: VARCHAR
      - name: STOCK_HEALTH
        description: Stock health CRITICAL LOW NORMAL or OVERSTOCKED
        expr: STOCK_HEALTH
        data_type: VARCHAR
    time_dimensions:
      - name: SNAPSHOT_DATE
        description: Date of the inventory snapshot
        expr: SNAPSHOT_DATE
        data_type: DATE
    facts:
      - name: QTY_ONLINE
        description: Quantity available for online fulfillment
        expr: QTY_ONLINE
        data_type: NUMBER
      - name: QTY_NORTHEAST
        description: Quantity at Northeast regional warehouse
        expr: QTY_NORTHEAST
        data_type: NUMBER
      - name: QTY_SOUTHEAST
        description: Quantity at Southeast regional warehouse
        expr: QTY_SOUTHEAST
        data_type: NUMBER
      - name: QTY_SOUTHWEST
        description: Quantity at Southwest regional warehouse
        expr: QTY_SOUTHWEST
        data_type: NUMBER
      - name: QTY_NORTHWEST
        description: Quantity at Northwest regional warehouse
        expr: QTY_NORTHWEST
        data_type: NUMBER
      - name: TOTAL_STOCK
        description: Total stock across all regions
        expr: TOTAL_STOCK
        data_type: NUMBER
      - name: QUALITY_SCORE
        description: Supplier quality score 0 to 100
        expr: QUALITY_SCORE
        data_type: FLOAT
      - name: WAREHOUSE_LONGITUDE
        description: Warehouse GPS longitude. Los Angeles is -118.24, Houston -95.37, New York -73.99, Chicago -87.63, San Francisco -122.42
        expr: WAREHOUSE_LONGITUDE
        data_type: FLOAT
      - name: WAREHOUSE_LATITUDE
        description: Warehouse GPS latitude. Los Angeles is 34.05, Houston 29.76, New York 40.75, Chicago 41.88, San Francisco 37.77
        expr: WAREHOUSE_LATITUDE
        data_type: FLOAT
    metrics:
      - name: TOTAL_INVENTORY_UNITS
        description: Sum of total stock across all records
        expr: SUM(TOTAL_STOCK)
        data_type: NUMBER
      - name: AVG_QUALITY
        description: Average quality score
        expr: AVG(QUALITY_SCORE)
        data_type: FLOAT

verified_queries:
  - name: top_selling_products
    question: What are the top 5 best-selling products?
    sql: |
      SELECT PRODUCT_NAME, SUM(TOTAL_UNITS_SOLD) AS TOTAL_UNITS
      FROM RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG.DAILY_PRODUCT_PERFORMANCE
      GROUP BY PRODUCT_NAME ORDER BY TOTAL_UNITS DESC LIMIT 5
    verified_at: 1722211200
    verified_by: RETAIL_ANALYTICS_TEAM
  - name: critical_stock_products
    question: Which products have critical stock levels?
    sql: |
      SELECT DISTINCT PRODUCT_NAME, INVENTORY_POSITION, STOCK_HEALTH_STATUS
      FROM RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG.DAILY_PRODUCT_PERFORMANCE
      WHERE STOCK_HEALTH_STATUS = 'CRITICAL'
      ORDER BY INVENTORY_POSITION ASC
    verified_at: 1722211200
    verified_by: SUPPLY_CHAIN_TEAM
  - name: customer_complaints
    question: What are customers complaining about?
    sql: |
      SELECT PRODUCT_NAME, COUNT(*) AS COMPLAINTS, AVG(SENTIMENT_SCORE) AS AVG_SENTIMENT
      FROM RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG.CUSTOMER_VOICE_ANALYTICS
      WHERE CUSTOMER_INTENT = 'complaint'
      GROUP BY PRODUCT_NAME ORDER BY COMPLAINTS DESC
    verified_at: 1722211200
    verified_by: CX_TEAM
  - name: online_vs_store_mix
    question: What is the online vs store channel mix?
    sql: |
      SELECT PRODUCT_NAME,
             SUM(WEEKLY_ONLINE_UNITS) AS ONLINE_TOTAL,
             SUM(WEEKLY_STORE_UNITS) AS STORE_TOTAL,
             ROUND(SUM(WEEKLY_ONLINE_UNITS)*100.0/NULLIF(SUM(WEEKLY_UNITS_SOLD),0),1) AS ONLINE_PCT
      FROM RETAIL_HOL_ICEBERG.GOLD_MANAGED_ICEBERG.WEEKLY_PRODUCT_SCORECARD
      GROUP BY PRODUCT_NAME ORDER BY ONLINE_PCT DESC
    verified_at: 1722211200
    verified_by: ECOMMERCE_TEAM
  - name: inventory_by_warehouse_location
    question: What is the inventory distribution across warehouse locations?
    sql: |
      SELECT
        CASE
          WHEN ROUND(WAREHOUSE_LONGITUDE,2) = -118.24 THEN 'Los Angeles'
          WHEN ROUND(WAREHOUSE_LONGITUDE,2) = -95.37 THEN 'Houston'
          WHEN ROUND(WAREHOUSE_LONGITUDE,2) = -73.99 THEN 'New York'
          WHEN ROUND(WAREHOUSE_LONGITUDE,2) = -87.63 THEN 'Chicago'
          WHEN ROUND(WAREHOUSE_LONGITUDE,2) = -122.42 THEN 'San Francisco'
        END AS WAREHOUSE_CITY,
        COUNT(DISTINCT SKU_NAME) AS PRODUCTS_STOCKED,
        SUM(TOTAL_STOCK) AS TOTAL_INVENTORY
      FROM RETAIL_HOL_ICEBERG.SILVER_MANAGED_ICEBERG.SILVER_INVENTORY
      GROUP BY 1
      ORDER BY TOTAL_INVENTORY DESC
    verified_at: 1722211200
    verified_by: SUPPLY_CHAIN_TEAM
  - name: stock_health_by_warehouse
    question: Which warehouses have products at critical or low stock levels?
    sql: |
      SELECT
        CASE
          WHEN ROUND(WAREHOUSE_LONGITUDE,2) = -118.24 THEN 'Los Angeles'
          WHEN ROUND(WAREHOUSE_LONGITUDE,2) = -95.37 THEN 'Houston'
          WHEN ROUND(WAREHOUSE_LONGITUDE,2) = -73.99 THEN 'New York'
          WHEN ROUND(WAREHOUSE_LONGITUDE,2) = -87.63 THEN 'Chicago'
          WHEN ROUND(WAREHOUSE_LONGITUDE,2) = -122.42 THEN 'San Francisco'
        END AS WAREHOUSE_CITY,
        SKU_NAME,
        TOTAL_STOCK,
        STOCK_HEALTH
      FROM RETAIL_HOL_ICEBERG.SILVER_MANAGED_ICEBERG.SILVER_INVENTORY
      WHERE STOCK_HEALTH IN ('CRITICAL', 'LOW')
      ORDER BY TOTAL_STOCK ASC
    verified_at: 1722211200
    verified_by: SUPPLY_CHAIN_TEAM
$$
);

-- Verify the Semantic View was created
SHOW SEMANTIC VIEWS IN SCHEMA GOLD_MANAGED_ICEBERG;
