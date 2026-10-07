CREATE DATABASE kenya_real_estate;

USE kenya_real_estate;
CREATE TABLE staging_houses(
    title VARCHAR(255),
    location VARCHAR(100),
    size VARCHAR(50),
    selling_price VARCHAR(100)
    );
LOAD DATA INFILE "C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/houses-for-sale.csv"
INTO TABLE staging_houses
FIELDS TERMINATED BY ',' 
ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 ROWS
(title, location, size, selling_price);

CREATE TABLE kenyan_properties (
    property_id INT AUTO_INCREMENT PRIMARY KEY,
    original_title VARCHAR(255),
    property_type VARCHAR(50),
    bedrooms INT,
    clean_location VARCHAR(100),
    raw_size VARCHAR(50),
    price_numeric BIGINT
);

INSERT INTO kenyan_properties (
    original_title, property_type, bedrooms, clean_location, raw_size, price_numeric
)
SELECT 
    title,
    -- 1. Classify Property Type from keywords
    CASE 
        WHEN LOWER(title) LIKE '%villa%' THEN 'Villa'
        WHEN LOWER(title) LIKE '%tow%' OR LOWER(title) LIKE '%townhouse%' THEN 'Townhouse'
        WHEN LOWER(title) LIKE '%apt%' OR LOWER(title) LIKE '%apartment%' THEN 'Apartment'
        WHEN LOWER(title) LIKE '%hou%' OR LOWER(title) LIKE '%house%' THEN 'Standalone House'
        ELSE 'Other Residential'
    END AS property_type,
    
    -- 2. Safe bedroom extraction (handles missing numbers safely)
    CAST(NULLIF(REGEXP_SUBSTR(title, '[0-9]+'), '') AS UNSIGNED) AS bedrooms,
    
    -- 3. Standardize and fix neighborhood typos
    CASE 
        WHEN TRIM(location) = 'Ngong Roa' THEN 'Ngong Road'
        WHEN TRIM(location) IN ('Kiambi', 'Kiambu Rd', 'Off Kiambi') THEN 'Kiambu Road'
        ELSE TRIM(location)
    END AS clean_location,
    
    size AS raw_size,
    
    -- 4. Safe price cleaning (converts empty text strings into NULL safely)
    CAST(NULLIF(REGEXP_REPLACE(selling_price, '[^0-9]', ''), '') AS UNSIGNED) AS price_numeric
FROM staging_houses;

USE kenya_real_estate;
-- 1. Index for fast location filtering (e.g., searching specifically for 'Kilimani')
CREATE INDEX idx_properties_location ON kenyan_properties(region_city);

-- 2. Index for filtering budgets (e.g., finding houses under 20 Million KES)
CREATE INDEX idx_properties_price ON kenyan_properties(price_numeric);

-- 3. Composite Index for exact matches (e.g., searching for '3 Bedroom Apartments')
CREATE INDEX idx_properties_type_rooms ON kenyan_properties(property_type, bedrooms);
EXPLAIN SELECT * 
FROM kenyan_properties 
WHERE clean_location = 'Kilimani'
;

-- Query to inspect duplicate rows
SELECT
 original_title, 
 clean_location, 
 price_numeric, 
 COUNT(*)
FROM kenyan_properties
GROUP BY original_title, clean_location, price_numeric
HAVING COUNT(*) > 1;

 use kenya_real_estate;
 DELETE p1 FROM kenyan_properties p1
INNER JOIN kenyan_properties p2 
    ON p1.original_title = p2.original_title 
    AND p1.clean_location = p2.clean_location 
    -- Handing numeric values safely
    AND (p1.price_numeric = p2.price_numeric OR (p1.price_numeric IS NULL AND p2.price_numeric IS NULL))
WHERE p1.property_id > p2.property_id;

-- Surface every single location text string that contains hidden messiness
SELECT clean_location, COUNT(*) as total_occurrences
FROM kenyan_properties
WHERE clean_location LIKE '%,%'      -- Finds text with commas (e.g., 'Runda, Westlands')
   OR clean_location LIKE '%/%'      -- Finds text with slashes (e.g., 'Kilimani/Hurlingham')
   OR clean_location LIKE '%Area%'   -- Finds repetitive strings (e.g., 'Nyali Area')
   OR clean_location LIKE '%Off%'    -- Finds connector text (e.g., 'Off Thika Road')
GROUP BY clean_location
ORDER BY total_occurrences DESC;

ALTER TABLE kenyan_properties 
ADD COLUMN street_address VARCHAR(150) DEFAULT NULL,
ADD COLUMN neighborhood VARCHAR(100) DEFAULT NULL,
ADD COLUMN region_city VARCHAR(100) DEFAULT NULL;

-- splitting the clean_location column
UPDATE kenyan_properties
SET 
    -- 1. Extract everything BEFORE the first comma as the Street Address
    street_address = CASE 
        WHEN clean_location LIKE '%,%' THEN TRIM(SUBSTRING_INDEX(clean_location, ',', 1))
        ELSE NULL 
    END,
    
    -- 2. Extract the text BETWEEN the first and second comma as the Neighborhood
    neighborhood = CASE 
        WHEN clean_location LIKE '%,%,%' THEN TRIM(SUBSTRING_INDEX(SUBSTRING_INDEX(clean_location, ',', 2), ',', -1))
        WHEN clean_location LIKE '%,%' THEN TRIM(SUBSTRING_INDEX(clean_location, ',', -1))
        ELSE TRIM(clean_location)
    END,
    
    -- 3. Extract everything AFTER the second comma as the Region/City
    region_city = CASE 
        WHEN clean_location LIKE '%,%,%' THEN TRIM(SUBSTRING_INDEX(clean_location, ',', -1))
        ELSE 'Nairobi' -- Default fallback for unsegmented properties
    END
WHERE clean_location LIKE '%,%';

-- Explicitly assign cities based on known neighborhood lists
UPDATE kenyan_properties
SET region_city = CASE 
    -- 1. Mombasa Coast Segment
    WHEN LOWER(neighborhood) LIKE '%nyali%' 
      OR LOWER(neighborhood) LIKE '%bamburi%' 
      OR LOWER(neighborhood) LIKE '%shanzu%' 
      OR LOWER(neighborhood) LIKE '%mtwapa%' THEN 'Mombasa'
      
    -- 2. Kiambu Commuter Segment
    WHEN LOWER(neighborhood) LIKE '%kiambu%' 
      OR LOWER(neighborhood) LIKE '%ruiru%' 
      OR LOWER(neighborhood) LIKE '%juja%' 
      OR LOWER(neighborhood) LIKE '%kikuyu%' THEN 'Kiambu County'
      
    -- 3. Kajiado/Machakos Segment
    WHEN LOWER(neighborhood) LIKE '%kitengela%' 
      OR LOWER(neighborhood) LIKE '%kiserian%' THEN 'Kajiado'
    WHEN LOWER(neighborhood) LIKE '%syokimau%' 
      OR LOWER(neighborhood) LIKE '%athi river%' THEN 'Machakos'
      
    -- 4. Default baseline remains Nairobi for inner-city estates
    ELSE 'Nairobi'
END;

-- List all neighborhoods classified under Nairobi to spot grouping errors
SELECT neighborhood, COUNT(*) as property_count
FROM kenyan_properties
WHERE region_city = 'Nairobi'
GROUP BY neighborhood
ORDER BY property_count DESC;

-- grouping first to secure the nairobi areas
-- using the IN operator
use kenya_real_estate;
UPDATE kenyan_properties
SET region_city = 'Nairobi'
WHERE TRIM(neighborhood) IN (
    'Kilimani', 'Kileleshwa', 'Lavington', 'Westlands', 'Riverside', 
    'Gigiri', 'Nyari', 'Muthaiga', 'Runda', 'Karen', 'Kitisuru', 
    'Loresho', 'Kyuna', 'Spring Valley', 'Nairobi West', 'South B', 
    'South C', 'Langata', 'Parklands', 'Ngara', 'Pangani', 'Eastleigh', 
    'Highridge', 'Madaraka', 'Roysambu', 'Kasarani', 'Zimmerman', 
    'Umoja', 'Donholm', 'Fedha', 'Nyayo Estate', 'Embakasi', 
    'Imara Daima', 'Pipeline', 'Ruai', 'Njiru', 'Kamulu', 
    'Utawala', 'Riruta', 'Thome'
);

-- still grouping but using the regexp
UPDATE kenyan_properties
SET region_city = 'Nairobi'
WHERE neighborhood REGEXP 'kilimani|kileleshwa|lavington|westlands|riverside|gigiri|nyari|muthaiga|runda|karen|kitisuru|loresho|langata|parklands|south b|south c|roysambu|kasarani|zimmerman|utawala';

SELECT neighborhood, COUNT(*) as property_count
FROM kenyan_properties
WHERE region_city = 'Nairobi'
  AND neighborhood NOT REGEXP 'kilimani|kileleshwa|lavington|westlands|riverside|gigiri|nyari|muthaiga|runda|karen|kitisuru|loresho|kyuna|spring valley|nairobi west|south b|south c|langata|parklands|ngara|pangani|eastleigh|highridge|madaraka|roysambu|kasarani|zimmerman|githurai|kahawa|umoja|donholm|fedha|nyayo estate|embakasi|imara daima|pipeline|ruai|njiru|kamulu|utawala|riruta|thome'
GROUP BY neighborhood
ORDER BY property_count DESC;

-- Audit your full location groupings across all cities
SELECT 
    neighborhood, 
    region_city, 
    COUNT(*) as property_count
FROM kenyan_properties
GROUP BY neighborhood, region_city
ORDER BY region_city ASC, neighborhood ASC;

use kenya_real_estate;
SELECT 
    property_id, 
    clean_location, 
    neighborhood, 
    region_city 
FROM kenyan_properties;

-- Master Regrouping Query focusing strictly on the fully populated clean_location column
UPDATE kenyan_properties
SET region_city = CASE 
    -- 1. Group Kiambu County towns natively from clean_location text
    WHEN clean_location REGEXP 'ruaka|ruiru|juja|thika|kikuyu|limuru|banana|karuri|tatu city|kamakis|paradise lost|Thindigua|Kenyatta Road|matangi|tigoni|muchatha|kabete|githunguri|kirigiti|edenville|ngoiwa|kentmere|gikambura|sigona|zambezi|membley|kimbo|landless|makongeni|lower kabete' THEN 'Kiambu County'
    
    -- 2. Group Machakos County towns natively from clean_location text
    WHEN clean_location REGEXP 'syokimau|athi river|mavoko|katani|maanzoni|mlolongo|machakos town|joska|kamulu border|lukenya' THEN 'Machakos'
    
    -- 3. Group Kajiado County towns natively from clean_location text
    WHEN clean_location REGEXP 'ngong|rongai|kitengela|kiserian|isinya|kajiado town|kajiado corridor|olkeri|kajiado|oloolua' THEN 'Kajiado'
    
    -- 4. Group Mombasa & Coastal towns natively from clean_location text
    WHEN clean_location REGEXP 'nyali|bamburi|shanzu|mtwapa|kikambala|lamu|vipingo|ukunda|likoni|changamwe|kisauni|mombasa cbd|mombasa island|bamburi mwisho|greenwood mtwapa|diani|Bomani|Bokoboko|Bomani mamba|greenwood nyali|kilifi|watamu|malindi' THEN 'Mombasa / Coast'
    
    -- 5. Explicitly cluster standard inner Nairobi hubs
    WHEN clean_location REGEXP 'kilimani|kileleshwa|lavington|westlands|riverside|gigiri|nyari|muthaiga|runda|karen|kitisuru|loresho|kyuna|spring valley|nairobi west|south b|south c|karen|langata|parklands|ngara|pangani|eastleigh|highridge|madaraka|roysambu|kasarani|zimmerman|githurai|kahawa|umoja|donholm|fedha|nyayo estate|embakasi|imara daima|pipeline|ruai|njiru|kamulu|utawala|riruta|thome' THEN 'Nairobi'

    -- If a row doesn't match any of the above groups, keep its current value for manual sorting
    ELSE region_city
END;

-- Comprehensive Kiambu County alignment using the fully populated clean_location column
UPDATE kenyan_properties
SET region_city = 'Kiambu County'
WHERE clean_location REGEXP 'ruaka|ruiru|juja|thika|kikuyu|limuru|banana|karuri|tatu city|kamakis|paradise lost|matangi|tigoni|muchatha|kabete|githunguri|kirigiti|edenville|ngoiwa|kentmere|gikambura|sigona|zambezi|membley|kimbo|landless|makongeni|lower kabete|kiambu road|kiambu rd|^kiambu$';

-- Retrieve the full layout including property id and location hierarchy
SELECT 
    property_id,
    clean_location,
    neighborhood,
    region_city
FROM kenyan_properties
ORDER BY region_city ASC, clean_location ASC;
-- Force the neighborhood column to take the absolute last name from clean_location text
UPDATE kenyan_properties
SET neighborhood = TRIM(SUBSTRING_INDEX(clean_location, ',', -1));

-- Retrieve the full layout including property id and location hierarchy
SELECT 
    property_id,
    clean_location,
    neighborhood,
    region_city
FROM kenyan_properties
ORDER BY region_city ASC, clean_location ASC;

-- Safely remove the 5 targeted outlier/corrupted property IDs
DELETE FROM kenyan_properties
WHERE property_id IN (1723, 1088, 1586, 68,1715,1809,935,218,483,1680,982,182,867,316,200,
1351,1405,308,1078,1689,1747,1432,1389,304,338,1356,1070,394,1691,1535,989,1746,1731,1642, 620);

-- Standardize specific neighborhood names into their parent county classification
UPDATE kenyan_properties
SET neighborhood = CASE 
    WHEN LOWER(neighborhood) LIKE '%kiambu road%' OR LOWER(neighborhood) LIKE '%kiambu rd%' THEN 'Kiambu'
    WHEN LOWER(neighborhood) LIKE '%kenyatta road%' OR LOWER(neighborhood) LIKE '%kenyatta rd%' THEN 'Kiambu'
    ELSE neighborhood
END
WHERE region_city = 'Kiambu County';

-- Retrieve the full layout including property id and location hierarchy
SELECT 
    property_id,
    clean_location,
    neighborhood,
    region_city
FROM kenyan_properties
ORDER BY property_id DESC, clean_location DESC;

SELECT CONCAT('ID: ', property_id, ' | Nh_ood: ', IFNULL(neighborhood, 'NULL'), 
                    ' | City: ', region_city) AS clean_audit_list
FROM kenyan_properties
ORDER BY region_city ASC, neighborhood ASC;

-- Mass group your cities using the engineered neighborhood column
UPDATE kenyan_properties
SET region_city = CASE 
    -- 1. Route Karen, Langata, Ngong Road, and Westlands firmly to Nairobi
    WHEN LOWER(neighborhood) LIKE '%karen%'
      OR LOWER(neighborhood) LIKE '%langata%'
      OR LOWER(neighborhood) LIKE '%ngong road%'
      OR LOWER(neighborhood) LIKE '%ngong rd%'
      OR LOWER(neighborhood) LIKE '%westlands%' THEN 'Nairobi'
      
    -- 2. Route Nyali firmly to Mombasa/Coast
    WHEN LOWER(neighborhood) LIKE '%nyali%' THEN 'Mombasa/Coast'

    -- 3.route kiambu town to kiambu
    WHEN LOWER(neighborhood) LIKE '%kiambu town%' THEN 'kiambu'
    
    -- Keep any other city classifications completely untouched
    ELSE region_city
END;

SELECT CONCAT('ID: ', property_id, ' | Nh_ood: ', IFNULL(neighborhood, 'NULL'), 
                    ' | City: ', region_city) AS clean_audit_list
FROM kenyan_properties
ORDER BY region_city ASC, neighborhood ASC;

-- Audit the raw whole numbers without any commas or formatting
SELECT 
    property_id, 
    original_title, 
    neighborhood, 
    region_city, 
    price_numeric
FROM kenyan_properties
WHERE price_numeric IS NOT NULL
ORDER BY price_numeric ASC
LIMIT 15;

-- Permanently delete all property records that are missing a price tag
DELETE FROM kenyan_properties
WHERE price_numeric IS NULL;

ALTER TABLE kenya_real_estate.kenyan_properties
ADD COLUMN numerical_bedrooms INT AFTER bedrooms,
ADD COLUMN description_part TEXT AFTER raw_size;

UPDATE kenya_real_estate.kenyan_properties
SET 
    -- Extracts the leading digits from raw_size
    numerical_bedrooms = CAST(REGEXP_SUBSTR(raw_size, '^[0-9]+') AS UNSIGNED),
    
    -- Strips the leading digits and any immediate spaces from raw_size
    description_part = TRIM(REGEXP_REPLACE(raw_size, '^[0-9]+', ''));

ALTER TABLE kenya_real_estate.kenyan_properties
DROP COLUMN clean_location,
DROP COLUMN raw_size,
DROP COLUMN numerical_bedrooms;

-- changing the price column name
ALTER TABLE kenya_real_estate.kenyan_properties
RENAME COLUMN price_numeric TO price_kes;

-- cleaning the descriptions
UPDATE kenya_real_estate.kenyan_properties
SET description_part = TRIM(REGEXP_REPLACE(description_part, '^(bdrm|bedroom|s|br|bedroom all ensuite|4?br|5?bdrm)\\s*(for sale in|for sale|with)?\\s*', '', 1, 0, 'i'));

DROP INDEX idx_properties_location ON kenyan_properties;

SELECT 
    property_id, 
    original_title,
    property_type, 
    bedrooms, 
    price_kes,
    street_address,
    neighborhood, 
    region_city
FROM 
    kenya_real_estate.kenyan_properties
LIMIT 50

/*
# METRIC ANALYSIS NOTES: PHASE 1 (DATA SAFETY & INTEGRITY CHECK)

* **COUNT(*) [Total Listings]:**
  - PURPOSE: Measures the exact scope and scale of the data pool.
  - USE CASE: Ensures all data rows successfully imported without structural truncation.

* **MIN(price_kes) [Absolute Lowest Price]:**
  - PURPOSE: Acts as an automated anomaly detector for incomplete records.
  - USE CASE: Flags missing data placeholders (e.g., KES 0, 1, or 999) left blank by agents before they skew calculations.

* **MAX(price_kes) [Absolute Highest Price]:**
  - PURPOSE: Defines the structural ceiling of the price landscape.
  - USE CASE: Isolates potential data-entry typos (e.g., fat-finger zeros) and highlights ultra-luxury market outliers.
*/

SELECT 
    COUNT(*) AS total_listings,
    MIN(price_kes) AS absolute_lowest_price,
    MAX(price_kes) AS absolute_highest_price
FROM 
    kenyan_properties;

/*
# METRIC ANALYSIS NOTES: PHASE 2 (TRUE MARKET BASELINE)

* **SKEWED AVERAGE PRICE:**
  - PURPOSE: Computes a standard mathematical mean.
  - RISK: Heavily inflated by luxury outliers like your 684M listing.

* **TRUE MEDIAN PRICE:**
  - PURPOSE: Pinpoints the literal middle entry of your sorted dataset.
  - BENEFIT: Outlier-resistant. Gives the most realistic standard market price.
*/

USE kenya_real_estate;
WITH RankedProperties AS (
    SELECT 
        price_kes,
        ROW_NUMBER() OVER (ORDER BY price_kes) AS row_num,
        COUNT(*) OVER () AS total_count
    FROM 
        kenyan_properties
    WHERE 
        price_kes IS NOT NULL
)
SELECT 
    (SELECT FLOOR(AVG(price_kes)) FROM kenyan_properties) AS skewed_average_price,
    FLOOR(AVG(price_kes)) AS true_median_price
FROM 
    RankedProperties
WHERE 
    row_num IN (FLOOR((total_count + 1) / 2), CEIL((total_count + 1) / 2));

/*
# METRIC ANALYSIS NOTES: PHASE 3 (MEDIAN BY LOCATION)
* PURPOSE: Finds the true middle price for each specific region.
* PARTITION BY: Tells MySQL to reset the ranking counter for every new location.
*/

WITH RankedByLocation AS (-- this creates a temporary named virtual table officially called common table expression or CTE
    SELECT 
        region_city,
        price_kes,
        ROW_NUMBER() OVER (PARTITION BY region_city ORDER BY price_kes) AS row_num,
        COUNT(*) OVER (PARTITION BY region_city) AS total_count
    FROM 
        kenyan_properties
    WHERE 
        price_kes IS NOT NULL AND region_city IS NOT NULL
)
SELECT 
    region_city,
    total_count AS total_listings,
    FLOOR(AVG(price_kes)) AS median_price_kes
FROM 
    RankedByLocation
WHERE 
    row_num IN (FLOOR((total_count + 1) / 2), CEIL((total_count + 1) / 2))
GROUP BY 
    region_city, total_count
ORDER BY 
    median_price_kes DESC;

-- Fix Kiambu duplicates
UPDATE kenyan_properties
SET region_city = 'Kiambu County'
WHERE region_city = 'kiambu';

-- Fix Mombasa spacing duplicates
UPDATE kenyan_properties
SET region_city = 'Mombasa / Coast'
WHERE region_city IN ('Mombasa/Coast', 'Mombasa');

/*
# METRIC ANALYSIS NOTES: PHASE 4 (PROPERTY TYPE BY REGION)
* PURPOSE: Analyzes the volume and average pricing configuration per property type within each clean region.
*/

SELECT 
    region_city,
    property_type,
    COUNT(*) AS listings_count,
    FLOOR(AVG(price_kes)) AS average_price_kes
FROM 
    kenyan_properties
WHERE 
    region_city IS NOT NULL AND property_type IS NOT NULL
GROUP BY 
    region_city, 
    property_type
ORDER BY 
    region_city ASC, 
    listings_count DESC;

/*
# METRIC ANALYSIS NOTES: PHASE 5 (MARKET ANOMALIES & UNDERVALUED ALERTS)
* PURPOSE: Isolates listings priced significantly below their neighborhood type baseline.
* USE CASE: Flags data anomalies or massive potential investment deals.
*/

SELECT 
    p.property_id,
    p.region_city,
    p.property_type,
    p.bedrooms,
    p.price_kes,
    p.neighborhood,
    p.street_address
FROM 
    kenyan_properties p
JOIN (
    -- Background table calculating the average per type and region
    SELECT region_city, property_type, AVG(price_kes) AS avg_price
    -- What it does: It temporarily groups your database by region and property type to calculate a customized baseline average price.
    -- The Output: It builds a hidden lookup table that maps out the exact local average for every property category, such as:
    -- Kiambu County + Standalone House = 22.8 Million KES average
	-- Mombasa / Coast + Villa = 68 Million KES average This temporary lookup table is given the nickname baseline
    FROM kenyan_properties
    GROUP BY region_city, property_type
) baseline 
    ON p.region_city = baseline.region_city 
    AND p.property_type = baseline.property_type
-- What it does: This connects your main table of raw properties (nicknamed p) directly to your new baseline lookup table.
-- How it connects: The ON clause acts like an exact match filter.
-- It ensures that a standalone house in Kiambu is only evaluated against the Kiambu Standalone House baseline price,
-- preventing a cheap apartment in Kajiado from being compared against an expensive villa in Mombasa.

WHERE 
    p.price_kes < (baseline.avg_price * 0.40)
-- The Math: It multiplies the local average price by 0.40 to calculate a 40% threshold line. For example, 
-- if the average house price in an area is 20 Million KES, the threshold line becomes 8 Million KES (\(20M \times 0.40\)).
-- The Filter: The WHERE clause screens every single listing and says:
-- If this property's actual price tag is lower than its local 40% threshold line, 
-- flag it on the screen."

ORDER BY 
    p.price_kes ASC;
-- Finally, the query pulls the descriptive details (like neighborhood, bedrooms, and address) 
-- for the flagged anomalies and sorts them from the absolute lowest price upward,
-- putting the most suspicious properties right at the very top of your screen.
/*
# METRIC ANALYSIS NOTES: PHASE 6 (HIGH-END LUXURY OUTLIERS)
* PURPOSE: Isolates elite properties priced drastically above their regional category baseline.
* USE CASE: Flags the ultra-luxury market segment or potential data-entry typos (extra zeros).
*/

SELECT 
    p.property_id,
    p.region_city,
    p.property_type,
    p.bedrooms,
    p.price_kes,
    p.neighborhood,
    p.street_address
FROM 
    kenyan_properties p
JOIN (
    SELECT region_city, property_type, AVG(price_kes) AS avg_price
    FROM kenyan_properties
    GROUP BY region_city, property_type
) baseline 
    ON p.region_city = baseline.region_city 
    AND p.property_type = baseline.property_type
WHERE 
    p.price_kes > (baseline.avg_price * 2.5)
ORDER BY 
    p.price_kes DESC;

/*
# METRIC ANALYSIS NOTES: PHASE 7 (CLEANED MARKET CORE)
* PURPOSE: Drops both low-end and high-end outliers to isolate the standard consumer market.
* CRITERIA: Keeps properties priced between 40% and 250% of their localized category average.
*/

SELECT 
    COUNT(*) AS total_normal_listings,
    FLOOR(AVG(p.price_kes)) AS true_market_average,
    MIN(p.price_kes) AS normal_floor_price,
    MAX(p.price_kes) AS normal_ceiling_price
FROM 
    kenyan_properties p
JOIN (
    SELECT region_city, property_type, AVG(price_kes) AS avg_price
    FROM kenyan_properties
    GROUP BY region_city, property_type
) baseline 
    ON p.region_city = baseline.region_city 
    AND p.property_type = baseline.property_type
WHERE 
    p.price_kes >= (baseline.avg_price * 0.40)
    AND p.price_kes <= (baseline.avg_price * 2.50);

/*
# DATA SCIENCE ARCHITECTURE: PERMANENT CORE VIEW CREATION
========================================================================
* OBJECTIVE  : Creates a permanent, reusable virtual window for the retail market.
* ADVANTAGE  : You only run this ONCE. After this, you can query this clean core 
               instantly without re-writing the heavy subquery logic every time.
========================================================================
*/

-- 1. Establishes the permanent virtual view structure in your database schema
CREATE VIEW view_normal_market AS

SELECT 
    -- 2. Selects all raw descriptive columns from the primary property table
    p.property_id,
    p.original_title,
    p.property_type,
    p.bedrooms,
    p.price_kes,
    p.street_address,
    p.neighborhood,
    p.region_city
FROM 
    -- Aliases your master production table as 'p'
    kenyan_properties p

JOIN (
    -- BACKGROUND LOOKUP SUBQUERY: Evaluates individual category baseline metrics
    SELECT 
        region_city, 
        property_type, 
        AVG(price_kes) AS avg_price
    FROM 
        kenyan_properties
    GROUP BY 
        region_city, 
        property_type
) baseline 
    -- STRUCTURAL ALIGNMENT: Anchors rows specifically to their localized categories
    ON p.region_city = baseline.region_city 
    AND p.property_type = baseline.property_type

WHERE 
    -- SAFE-BOUND FILTER: Drops low-end entry variations (vacant plots / timeshares)
    p.price_kes >= (baseline.avg_price * 0.40)
    
    -- OUTLIER SHIFT FILTER: Drops high-end luxury peaks (the 684M scale entries)
    AND p.price_kes <= (baseline.avg_price * 2.50);

/*
# DATA SCIENCE ARCHITECTURE: PHASE 7 (CLEANED MARKET CORE ARCHIVE)
========================================================================
* PURPOSE: Isolate the standard retail housing sector from extreme anomalies.
* BOUNDARY PARAMETERS: 
  - Floor Cutoff   : >= 40% of the localized property type average.
  - Ceiling Cutoff : <= 250% of the localized property type average.
========================================================================
*/

SELECT 
    -- 1. Counts the total records remaining within our safe boundary limits
    COUNT(*) AS total_normal_listings,
    
    -- 2. Calculates the new mathematical mean price of the filtered market core
    FLOOR(AVG(p.price_kes)) AS true_market_average,
    
    -- 3. Identifies the lowest valid price boundary after purging low-end entries
    MIN(p.price_kes) AS normal_floor_price,
    
    -- 4. Identifies the highest valid price boundary after slicing off luxury peaks
    MAX(p.price_kes) AS normal_ceiling_price

FROM 
    -- Aliases the raw target dataset as 'p' for structural referencing
    kenyan_properties p

JOIN (
    -- BACKGROUND SUBQUERY: Establishes a customized local lookup matrix
    SELECT 
        region_city, 
        property_type, 
        AVG(price_kes) AS avg_price
    FROM 
        kenyan_properties
    GROUP BY 
        region_city, 
        property_type
) baseline 
    -- CONNECTIVE LOGIC: Matches individual rows to their specific target baselines
    ON p.region_city = baseline.region_city 
    AND p.property_type = baseline.property_type

WHERE 
    -- ANOMALY FILTER: Purges structural missing data and fractional ownership plots
    p.price_kes >= (baseline.avg_price * 0.40)
    
    -- OUTLIER FILTER: Slices off hyper-inflated mega-mansions and fat-finger typos
    AND p.price_kes <= (baseline.avg_price * 2.50);

/*
# DATA SCIENCE ARCHITECTURE: PHASE 8 (PRICE-PER-BEDROOM VALUE RATIO)
========================================================================
* PURPOSE  : Calculates the exact financial cost allocated to a single bedroom.
* RESOURCE : Queries your new 'view_normal_market' window directly for clean data.
* FILTER   : Excludes properties with 0 bedrooms (raw land plots or studios) to avoid math errors.
========================================================================
*/
-- The Premium Peak: Which property size configuration commands the highest cost per individual bedroom?
-- (Often, smaller 1 or 2-bedroom units have a higher price-per-bedroom ratio than sprawling 5-bedroom houses).
-- The Bulk Discount: Where do you get the cheapest cost per room?


SELECT 
    region_city,
    property_type,
    bedrooms,
    COUNT(*) AS total_properties,
    -- 1. Finds the baseline middle price for this specific size setup
    FLOOR(AVG(price_kes)) AS median_unit_price,
    
    -- 2. Calculates the cost efficiency ratio per bedroom room asset
    FLOOR(AVG(price_kes / bedrooms)) AS price_per_bedroom
FROM 
    view_normal_market
WHERE 
    bedrooms > 0
GROUP BY 
    region_city, 
    property_type, 
    bedrooms
ORDER BY 
    price_per_bedroom DESC;

/*
# DATA SCIENCE ARCHITECTURE: PHASE 9 (FINAL EXECUTIVE SUMMARY EXPORT)
========================================================================
* PURPOSE  : Generates the clean executive metrics table per region.
* USE CASE : Directly serves as the final data core for Power BI dashboards.
========================================================================
*/

SELECT 
    region_city,
    COUNT(*) AS standard_market_listings,
    FLOOR(AVG(price_kes)) AS average_market_price,
    FLOOR(AVG(price_kes / bedrooms)) AS average_cost_per_bedroom,
    MIN(price_kes) AS entry_level_price,
    MAX(price_kes) AS premium_core_price
FROM 
    view_normal_market
WHERE 
    bedrooms > 0
GROUP BY 
    region_city
ORDER BY 
    average_market_price DESC;

/*
# ANALYTICS NOTEBOOK: ARCHITECTURE PILLAR 1 (SUPPLY MATRIX)
========================================================================
* PURPOSE     : Categorizes listings into socio-economic pricing tiers.
* PROBLEM SOLD: Identifies whether the market is over-saturated with luxury 
                builds or under-supplied in affordable consumer brackets.
========================================================================
*/

SELECT 
    CASE 
        WHEN price_kes < 15000000 THEN '1. Budget Tier (Under 15M KES)'
        WHEN price_kes BETWEEN 15000000 AND 35000000 THEN '2. Mid-Market Tier (15M - 35M KES)'
        WHEN price_kes BETWEEN 35000001 AND 75000000 THEN '3. Premium Tier (35M - 75M KES)'
        ELSE '4. Elite Luxury Core (Over 75M KES)'
    END AS real_estate_market_segment,
    COUNT(*) AS total_inventory_volume,
    ROUND((COUNT(*) * 100.0 / (SELECT COUNT(*) FROM view_normal_market)), 1) AS overall_market_share_pct
FROM 
    view_normal_market
GROUP BY 
    1
ORDER BY 
    real_estate_market_segment ASC;

/*
# ANALYTICS NOTEBOOK: ARCHITECTURE PILLAR 2 (MICRO-MARKET MATRIX)
========================================================================
* PURPOSE     : Extracts localized real estate nodes based on room efficiency.
* PROBLEM SOLD: Reveals the true premium centers. Filters out single-property 
                anomalies by enforcing a minimum baseline sample size.
========================================================================
*/

SELECT 
    region_city,                                    -- Displays the main cleaned broad region
    neighborhood,                                   -- Displays the hyper-local node from web scraping
    COUNT(*) AS active_listings_count,              -- Tracks sample size count per neighborhood node
    FLOOR(AVG(price_kes)) AS average_property_price,-- Calculates the local absolute price baseline
    FLOOR(AVG(price_kes / bedrooms))                -- Computes the core price efficiency per room 
    AS raw_cost_per_bedroom                         -- Names the resulting room cost efficiency field
FROM 
    view_normal_market                              -- Pulls from the core view to block 684M skew
WHERE 
    bedrooms > 0                                    -- Data defense: Blocks properties with missing or 0 rooms
    AND neighborhood IS NOT NULL                    -- Data defense: Excludes unmapped locations
GROUP BY 
    region_city,                                    -- Multi-level grouping: splits first by city
    neighborhood                                    -- Multi-level grouping: splits next by local hub
HAVING 
    COUNT(*) >= 3                                   -- Post-calculation filter: drops small unverified nodes
ORDER BY 
    raw_cost_per_bedroom DESC                       -- Ranks from absolute most expensive per room downward
LIMIT 10;                                           -- Pulls the definitive top 10 premium anchors

/*
# ANALYTICS NOTEBOOK: ARCHITECTURE PILLAR 3 (MARGINAL COST MATRIX)
========================================================================
* PURPOSE     : Computes the explicit pricing premium of structural scaling.
* PROBLEM SOLD: Guides real estate developers on the financial feasibility of 
                adding rooms versus local buying thresholds.
========================================================================
*/

SELECT 
    property_type,                                  -- Breaks data down by the structural style
    bedrooms,                                       -- Isolates the specific room configuration scale
    COUNT(*) AS tracking_inventory_count,           -- Monitors inventory volume per combination type
    FLOOR(AVG(price_kes)) AS category_base_price,   -- Calculates the average price benchmark for this setup
    
    FLOOR(                                          -- Drops decimals for clean integer tracking
      AVG(price_kes) -                              -- Takes the current row's average price value
      LAG(AVG(price_kes), 1) OVER (                 -- Window lookback: grabs the average price of the previous row
        PARTITION BY property_type                  -- Isolates tracking boundaries to match property type
        ORDER BY bedrooms                           -- Sequences the lookback rows from 1-bed up to 10-bed
      )
    ) AS price_increase_per_extra_room              -- Calculates the net cost increase to step up one bedroom size
FROM 
    view_normal_market                              -- Runs on the outlier-insulated core view
GROUP BY 
    property_type, 
    bedrooms
ORDER BY 
    property_type, 
    bedrooms ASC;                                   -- Orders chronologically to allow LAG to look upward

/*
# ANALYTICS NOTEBOOK: ARCHITECTURE PILLAR 4 (FEATURE VALUE CALCULATOR)
========================================================================
* PURPOSE     : Performs phrase-matching parsing on text entries.
* PROBLEM SOLD: Measures the exact pricing premium commanded by premium amenities 
                (DSQs, Pools, Gardens) vs standard text entries.
========================================================================
*/

SELECT 
    CASE 
        WHEN description_part LIKE '%DSQ%'          -- Wildcard match: searches string for uppercase "DSQ"
          OR description_part LIKE '%servant%'      -- Wildcard match: catches lowercase variations like "servant quarter"
          THEN 'Equipped with DSQ / Servant Quarter'
        WHEN description_part LIKE '%pool%'          -- Wildcard match: isolates luxury relaxation assets
          OR description_part LIKE '%swimming%'    
          THEN 'Equipped with Swimming Pool'
        WHEN description_part LIKE '%garden%'        -- Wildcard match: identifies premium private yard items
          OR description_part LIKE '%yard%'        
          THEN 'Equipped with Private Managed Garden'
        ELSE 'Standard Residential Baseline Layout' -- Fallback label if text contains no luxury keywords
    END AS premium_architectural_feature,           -- Names the final amenity category grouping
    
    COUNT(*) AS designated_property_count,          -- Counts how many properties mention this amenity
    FLOOR(AVG(price_kes)) AS composite_average_price-- Calculates the average price for homes with this keyword
FROM 
    view_normal_market                              -- References your cleaned core view dataset
GROUP BY 
    1                                               -- Compresses results based on the text evaluation groups
ORDER BY 
    composite_average_price DESC;                   -- Ranks from highest amenity premium downward

/*
# DATA SCIENCE ARCHITECTURE: COLUMN EXTRACTION & CLEANING CORE
========================================================================
* PURPOSE     : Filters out NULL bedroom placeholders before calculating shifts.
* ATTACHMENT  : Keeps partitions isolated by property type for accurate step-ups.
========================================================================
*/

SELECT 
    property_type,                                  
    bedrooms,                                       
    tracking_inventory_count,           
    category_base_price,   
    FLOOR(                                          
      category_base_price -                              
      LAG(category_base_price, 1) OVER (                 
        PARTITION BY property_type                  
        ORDER BY bedrooms                           
      )
) AS price_increase_per_extra_room              
FROM (
    SELECT 
        property_type,
        bedrooms,
        COUNT(*) AS tracking_inventory_count,
        FLOOR(AVG(price_kes)) AS category_base_price
    FROM 
        view_normal_market
    WHERE 
        bedrooms IS NOT NULL -- 🌟 Fixes the partition starting point
    GROUP BY 
        property_type, bedrooms
) AS aggregated_market
ORDER BY 
    property_type, 
    bedrooms ASC;

/*
# GEOGRAPHICAL DRILL-DOWN: GLOBAL NEIGHBORHOOD LEADERBOARD
========================================================================
* PURPOSE     : Ranks localized estate nodes across the entire dataset.
* INTEGRITY   : Enforces a 3-listing minimum to block single-house anomalies.
========================================================================
*/

SELECT 
    region_city,
    neighborhood,
    COUNT(*) AS total_neighborhood_listings,
    FLOOR(MIN(price_kes)) AS entry_level_price,
    FLOOR(AVG(price_kes)) AS average_market_price,
    FLOOR(MAX(price_kes)) AS peak_market_price,
    FLOOR(AVG(price_kes / bedrooms)) AS average_cost_per_bedroom
FROM 
    view_normal_market
WHERE 
    neighborhood IS NOT NULL AND bedrooms > 0
GROUP BY 
    region_city, 
    neighborhood
HAVING 
    COUNT(*) >= 3
ORDER BY 
    average_market_price DESC;

SELECT 
    property_id,
    original_title,
    property_type,
    bedrooms,
    price_kes,
    street_address,
    neighborhood,
    region_city
FROM 
    kenya_real_estate.kenyan_properties
WHERE 
    neighborhood = 'Nairobi';

-- 1. First, merge Karen Hardy cleanly into the main Karen category
UPDATE kenyan_properties
SET neighborhood = 'Karen'
WHERE neighborhood = 'Karen Hardy';

-- 2. Map the street addresses to their correct local neighborhoods
UPDATE kenyan_properties
SET neighborhood = 'Kilimani'
WHERE street_address = 'Lenana Road' AND neighborhood = 'Nairobi';

UPDATE kenyan_properties
SET neighborhood = 'Kileleshwa'
WHERE street_address = 'Oloitokitok road' AND neighborhood = 'Nairobi';

UPDATE kenyan_properties
SET neighborhood = 'Lavington'
WHERE street_address IN (
    'Kanjata road', 
    'Convent Drive', 
    'Manyani East road', 
    'Mugumo Road', 
    'Owashika road'
) AND neighborhood = 'Nairobi';

/*
# GEOGRAPHICAL DRILL-DOWN: GLOBAL NEIGHBORHOOD LEADERBOARD
========================================================================
* PURPOSE     : Ranks localized estate nodes across the entire dataset.
* INTEGRITY   : Enforces a 3-listing minimum to block single-house anomalies.
========================================================================
*/

SELECT 
    region_city,
    neighborhood,
    COUNT(*) AS total_neighborhood_listings,
    FLOOR(MIN(price_kes)) AS entry_level_price,
    FLOOR(AVG(price_kes)) AS average_market_price,
    FLOOR(MAX(price_kes)) AS peak_market_price,
    FLOOR(AVG(price_kes / bedrooms)) AS average_cost_per_bedroom
FROM 
    view_normal_market
WHERE 
    neighborhood IS NOT NULL AND bedrooms > 0
GROUP BY 
    region_city, 
    neighborhood
HAVING 
    COUNT(*) >= 3
ORDER BY 
    average_market_price DESC;

/*
# BLUEPRINT PHASE 1: MACRO MARKET CONCENTRATION
* PURPOSE: Establishes the high-level volume baseline for each major region.
*/
SELECT 
    region_city,
    COUNT(*) AS total_listings,
    FLOOR(AVG(price_kes)) AS macro_average_price,
    ROUND((COUNT(*) * 100.0 / (SELECT COUNT(*) FROM view_normal_market)), 1) AS regional_market_share_pct
FROM 
    view_normal_market
GROUP BY 
    region_city
ORDER BY 
    total_listings DESC;

/*
# BLUEPRINT PHASE 2: MICRO-MARKET PREMIUM TIERING
* PURPOSE: Ranks neighborhoods by luxury premium and uncovers the highest entry-level financial floors.
*/
SELECT 
    region_city,
    neighborhood,
    COUNT(*) AS estate_listings_count,
    FLOOR(AVG(price_kes)) AS average_estate_price,
    MIN(price_kes) AS local_entry_floor_price,
    MAX(price_kes) AS local_premium_ceiling_price
FROM 
    view_normal_market
WHERE 
    neighborhood IS NOT NULL
GROUP BY 
    region_city, neighborhood
HAVING 
    COUNT(*) >= 3 -- Filters out single-property noise
ORDER BY 
    average_estate_price DESC;

/*
# BLUEPRINT PHASE 3: STRUCTURAL DRILLDOWN (LAVINGTON HOUSING ENGINE)
* PURPOSE: Pinpoints the specific property layout driving the local market value inside a single neighborhood.
*/
SELECT 
    property_type,
    bedrooms,
    COUNT(*) AS specific_layout_count,
    FLOOR(AVG(price_kes)) AS average_layout_price,
    FLOOR(AVG(price_kes / bedrooms)) AS average_cost_per_room
FROM 
    view_normal_market
WHERE 
    neighborhood = 'Lavington' AND bedrooms > 0
GROUP BY 
    property_type, bedrooms
ORDER BY 
    specific_layout_count DESC;

use kenya_real_estate;
SELECT 
    region_city,
    CASE 
        WHEN description_part LIKE '%pool%' OR description_part LIKE '%swimming%' THEN 'Equipped with Swimming Pool'
        ELSE 'Standard Layout Baseline'
    END AS amenity_status,
    COUNT(*) AS inventory_volume,
    FLOOR(AVG(price_kes)) AS localized_average_price
FROM 
    view_normal_market
GROUP BY 
    region_city, 
    -- Copy and paste the exact block here instead of using the number 1
    CASE 
        WHEN description_part LIKE '%pool%' OR description_part LIKE '%swimming%' THEN 'Equipped with Swimming Pool'
        ELSE 'Standard Layout Baseline'
    END
ORDER BY 
    region_city ASC, 
    localized_average_price DESC;

/*
# DATA SCIENCE ARCHITECTURE: STREAMLINED FEATURE ENGINEERING VIEW
========================================================================
* SOURCE      : view_normal_market (Our pre-cleaned, outlier-free core)
* PURPOSE     : Dynamically adds engineered columns without repeating filters.
========================================================================
*/

CREATE OR REPLACE VIEW view_powerbi_analytical_core AS
SELECT 
    property_id,
    original_title,
    property_type,
    bedrooms,
    price_kes,
    street_address,
    neighborhood,
    region_city,
    
    -- 🌟 FEATURE 1: Space Capital Efficiency Metric
    FLOOR(price_kes / bedrooms) AS price_per_bedroom,
    
    -- 🌟 FEATURE 2: Socio-Economic Market Segmentation
    CASE 
        WHEN price_kes < 15000000 THEN '1. Budget Tier'
        WHEN price_kes BETWEEN 15000000 AND 35000000 THEN '2. Mid-Market'
        WHEN price_kes BETWEEN 35000001 AND 75000000 THEN '3. Premium Tier'
        ELSE '4. Elite Luxury Core'
    END AS market_tier,
    
    -- 🌟 FEATURE 3: Structural Amenity Verification Markers (Boolean Flags)
    CASE WHEN description_part LIKE '%pool%' OR description_part LIKE '%swimming%' THEN 1 ELSE 0 END AS has_pool,
    CASE WHEN description_part LIKE '%DSQ%' OR description_part LIKE '%servant%' THEN 1 ELSE 0 END AS has_dsq,
    CASE WHEN description_part LIKE '%garden%' OR description_part LIKE '%yard%' THEN 1 ELSE 0 END AS has_garden,
    
    -- 🌟 FEATURE 4: Aggregated Architectural Luxury Index Score (0 to 3 Scale)
    (
        (CASE WHEN description_part LIKE '%pool%' OR description_part LIKE '%swimming%' THEN 1 ELSE 0 END) +
        (CASE WHEN description_part LIKE '%DSQ%' OR description_part LIKE '%servant%' THEN 1 ELSE 0 END) +
        (CASE WHEN description_part LIKE '%garden%' OR description_part LIKE '%yard%' THEN 1 ELSE 0 END)
    ) AS amenity_luxury_score
FROM 
    view_normal_market; -- 🌟 Clean, short, and directly references your filtered view!

SELECT 
    property_id,
    property_type,
    bedrooms,
    price_kes,
    neighborhood,
    region_city,
    price_per_bedroom,
    market_tier,
    has_pool,
    has_dsq,
    has_garden,
    amenity_luxury_score
FROM 
    view_powerbi_analytical_core
LIMIT 10;

