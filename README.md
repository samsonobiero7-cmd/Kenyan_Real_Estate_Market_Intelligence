# 🇰🇪 Kenyan Residential Market Intelligence: Enterprise BI Pipeline

An end-to-end data engineering and business intelligence application capturing, processing, and analyzing **1,308 transactional real estate records** across primary Kenyan economic hubs (Nairobi, Kiambu County, Mombasa, Machakos, and Kajiado).

---

## 🛠️ Tech Stack & Architecture
* **Data Warehousing & ETL:** MySQL Server (Relational Database Design)
* **Analytics & Visualization:** Power BI Desktop (`.pbix`)
* **Core Language:** SQL (Advanced Data Manipulation, Aggregations, Performance Tuning)

---

## ⚙️ Database Architecture & ETL Pipeline
Rather than connecting Power BI directly to a messy raw data file, a full ETL pipeline was built in MySQL to build clean data models, implement advanced regex transformations, and protect query performance.

### 1. Ingestion Layer
Data is initially pulled into a non-relational `staging_houses` table using high-speed server file paths:
```sql
LOAD DATA INFILE "C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/houses-for-sale.csv"
INTO TABLE staging_houses
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 ROWS;
```

### 2. Regex Feature Engineering & Type Conversion
Messy real estate descriptions were split apart into clean relational data attributes. This process included categorizing property profiles via substring mappings, converting alphanumeric strings into pure numeric integers via `REGEXP_REPLACE`, and isolating bedroom quantities with `REGEXP_SUBSTR`:
```sql
CASE 
    WHEN LOWER(title) LIKE '%villa%' THEN 'Villa'
    WHEN LOWER(title) LIKE '%townhouse%' THEN 'Townhouse'
    WHEN LOWER(title) LIKE '%apartment%' THEN 'Apartment'
    ELSE 'Standalone House'
END AS property_type,
CAST(NULLIF(REGEXP_SUBSTR(title, '[0-9]+'), '') AS UNSIGNED) AS bedrooms,
CAST(NULLIF(REGEXP_REPLACE(selling_price, '[^0-9]', ''), '') AS UNSIGNED) AS price_numeric
```

### 3. Spatial Parsing & Text Segmentation
A major challenge was processing unformatted, single-string user location data. Using geometric string indexers (`SUBSTRING_INDEX`) and targeted conditional checks, unformatted locations were cleanly separated into three independent fields: `street_address`, `neighborhood`, and `region_city` to power geographic drill-downs inside the visual dashboard.

```sql
-- Isolating nested addresses safely by comma breaks
street_address = CASE WHEN clean_location LIKE '%,%' THEN TRIM(SUBSTRING_INDEX(clean_location, ',', 1)) ELSE NULL END,
neighborhood   = CASE WHEN clean_location LIKE '%,%' THEN TRIM(SUBSTRING_INDEX(clean_location, ',', -1)) ELSE TRIM(clean_location) END
```

### 4. Query Performance & Index Optimization
To support lightning-fast dashboard interactions, single-column and multi-layered composite indexes were deployed. Query executions were continually verified using `EXPLAIN` cost matrices:
* `idx_properties_location`: Speeds up deep location-based slicing (e.g., Kilimani vs. Ruaka).
* `idx_properties_price`: Optimizes high-low pricing buckets.
* `idx_properties_type_rooms`: A high-performance composite index matching real-world buyer filters (e.g., *3-Bedroom Apartments*).

---

## 📊 Business Intelligence Layer
The clean relational tables connect seamlessly to **Power BI**, structuring interactive visuals across the cleaned Kenyan commuter nodes:
* **Market Distributions:** Tracking total structural supply over critical counties.
* **Pricing Matrices:** Outlining clear financial trends separating standalone houses from growing high-rise developments.
