-- ============================================================
-- Buy/Sell Report EDA — Run in VS Code against Fabric (tenxhub)
-- Purpose: Verify we have the right attributes to build the
--          Deal Type × Deal Stage matrix report
-- ============================================================

-- ============================================================
-- 1. CHECK: Do we have bs_deal_type anywhere?
--    The worksheet says we need this HS property for row filtering.
--    It's NOT in silver_Deals or bronze_Deals schemas.
--    bronze_DealsFULL has cv_deal_type — is that it?
-- ============================================================

-- 1a. What distinct values are in cv_deal_type? (bronze_DealsFULL)
SELECT 
    cv_deal_type,
    COUNT(*) AS deal_count
FROM bronze_DealsFULL
WHERE cv_deal_type IS NOT NULL
GROUP BY cv_deal_type
ORDER BY deal_count DESC;

-- 1b. Does bronze_DealsINCR also have cv_deal_type?
SELECT 
    cv_deal_type,
    COUNT(*) AS deal_count
FROM bronze_DealsINCR
WHERE cv_deal_type IS NOT NULL
GROUP BY cv_deal_type
ORDER BY deal_count DESC;

-- 1c. Check silver_Deals — CVDealType column exists there
SELECT 
    CVDealType,
    COUNT(*) AS deal_count
FROM silver_Deals
WHERE CVDealType IS NOT NULL
GROUP BY CVDealType
ORDER BY deal_count DESC;


-- ============================================================
-- 2. CHECK: Pipeline values — do we have Buy/Sell pipelines?
--    Need: PBA, CSA, ARR, ERR, Buy Side DE, Sell Side DE, 
--          VA, AH, BAC, BAS, BAW
-- ============================================================

-- 2a. All pipelines in bronze_DealStages (the lookup table)
SELECT DISTINCT 
    pipeline_id,
    pipeline_label
FROM bronze_DealStages
ORDER BY pipeline_label;

-- 2b. What pipeline values are deals actually using?
SELECT 
    pipeline,
    COUNT(*) AS deal_count
FROM bronze_DealsFULL
GROUP BY pipeline
ORDER BY deal_count DESC;

-- 2c. Same for silver_Deals
SELECT 
    Pipeline,
    COUNT(*) AS deal_count
FROM silver_Deals
GROUP BY Pipeline
ORDER BY deal_count DESC;


-- ============================================================
-- 3. CHECK: Deal stages — are they stored as IDs or labels?
-- ============================================================

-- 3a. Sample dealstage values from bronze_DealsFULL
SELECT TOP 20
    dealstage,
    pipeline,
    dealname
FROM bronze_DealsFULL
WHERE pipeline IS NOT NULL;

-- 3b. Sample from silver_Deals
SELECT TOP 20
    DealStage,
    Pipeline,
    DealName
FROM silver_Deals
WHERE Pipeline IS NOT NULL;

-- 3c. All stages for Buy/Sell pipelines from the lookup
--     (This is the reference we'll JOIN on)
SELECT 
    pipeline_label,
    stage_label,
    stage_id,
    display_order,
    probability,
    is_closed
FROM bronze_DealStages
WHERE pipeline_label IN (
    'Buy Side Direct Engagement',
    'Sell Side Direct Engagement',
    'Partnership Buyout Advisory',
    'Capital Structure Advisory',
    'Acquisition Readiness Review (ARR)',
    'Exit Readiness Review (ERR)',
    'Valuation Analysis',
    'BAC Members — Club',
    'Advisory Hours',
    'Business Acquisition Summit',
    'Business Acquisition Workshop'
)
ORDER BY pipeline_label, display_order;


-- ============================================================
-- 4. CHECK: Can we join deals → stages to get labels?
--    If dealstage stores stage_id, we join to bronze_DealStages
-- ============================================================

-- 4a. Quick join test — bronze_DealsFULL to bronze_DealStages
SELECT TOP 50
    d.dealname,
    d.pipeline,
    d.dealstage,
    ds.pipeline_label,
    ds.stage_label
FROM bronze_DealsFULL d
LEFT JOIN bronze_DealStages ds
    ON d.dealstage = ds.stage_id
WHERE d.pipeline IS NOT NULL
ORDER BY d.pipeline;

-- 4b. How many deals DON'T join? (orphaned stage IDs)
SELECT 
    COUNT(*) AS total_deals,
    SUM(CASE WHEN ds.stage_id IS NULL THEN 1 ELSE 0 END) AS orphaned_stages,
    SUM(CASE WHEN ds.stage_id IS NOT NULL THEN 1 ELSE 0 END) AS matched_stages
FROM bronze_DealsFULL d
LEFT JOIN bronze_DealStages ds
    ON d.dealstage = ds.stage_id;


-- ============================================================
-- 5. CHECK: hs_is_closed_lost — do we have it?
--    The worksheet says we need it. Not in any schema I see.
-- ============================================================

-- 5a. silver_Deals has IsClosedWon but NOT IsClosedLost
--     Can we infer it? Check if bronze_DealStages.is_closed helps
SELECT DISTINCT 
    is_closed,
    probability,
    stage_label
FROM bronze_DealStages
WHERE is_closed IS NOT NULL
ORDER BY is_closed, probability;

-- 5b. Does bronze_DealsFULL have any closed-lost indicator?
--     Check hs_is_closed_won values
SELECT 
    hs_is_closed_won,
    COUNT(*) AS cnt
FROM bronze_DealsFULL
GROUP BY hs_is_closed_won;


-- ============================================================
-- 6. THE MONEY QUERY: Simulate the matrix report
--    Deal Type (rows) × Stage Label (columns) → COUNT
--    This is what Power BI will render
-- ============================================================

-- 6a. First: What does the cross-tab look like with current data?
--     Using pipeline_label as the row (since we may not have bs_deal_type)
SELECT 
    ds.pipeline_label AS deal_type,
    ds.stage_label,
    COUNT(DISTINCT d.hs_object_id) AS deal_count
FROM bronze_DealsFULL d
INNER JOIN bronze_DealStages ds
    ON d.dealstage = ds.stage_id
WHERE ds.pipeline_label IN (
    'Buy Side Direct Engagement',
    'Sell Side Direct Engagement',
    'Partnership Buyout Advisory',
    'Capital Structure Advisory',
    'Acquisition Readiness Review (ARR)',
    'Exit Readiness Review (ERR)',
    'Valuation Analysis',
    'BAC Members — Club',
    'Advisory Hours',
    'Business Acquisition Summit',
    'Business Acquisition Workshop'
)
GROUP BY ds.pipeline_label, ds.stage_label
ORDER BY ds.pipeline_label, ds.stage_label;

-- 6b. Grand totals by pipeline (row totals)
SELECT 
    ds.pipeline_label AS deal_type,
    COUNT(DISTINCT d.hs_object_id) AS total_deals
FROM bronze_DealsFULL d
INNER JOIN bronze_DealStages ds
    ON d.dealstage = ds.stage_id
WHERE ds.pipeline_label IN (
    'Buy Side Direct Engagement',
    'Sell Side Direct Engagement',
    'Partnership Buyout Advisory',
    'Capital Structure Advisory',
    'Acquisition Readiness Review (ARR)',
    'Exit Readiness Review (ERR)',
    'Valuation Analysis',
    'BAC Members — Club',
    'Advisory Hours',
    'Business Acquisition Summit',
    'Business Acquisition Workshop'
)
GROUP BY ds.pipeline_label
ORDER BY total_deals DESC;


-- ============================================================
-- 7. KEY QUESTION: bs_deal_type vs pipeline_label
--    If bs_deal_type isn't in Fabric yet, can we use 
--    pipeline_label as a proxy? Or is bs_deal_type a 
--    deal-level property that differs from the pipeline?
-- ============================================================

-- 7a. Check if cv_deal_type maps 1:1 to pipeline
SELECT 
    d.cv_deal_type,
    ds.pipeline_label,
    COUNT(*) AS cnt
FROM bronze_DealsFULL d
LEFT JOIN bronze_DealStages ds
    ON d.dealstage = ds.stage_id
WHERE d.cv_deal_type IS NOT NULL
GROUP BY d.cv_deal_type, ds.pipeline_label
ORDER BY d.cv_deal_type, ds.pipeline_label;

-- 7b. Are there deals where cv_deal_type != pipeline_label?
--     (This tells us if they're interchangeable or not)
SELECT 
    d.cv_deal_type,
    ds.pipeline_label,
    COUNT(*) AS cnt
FROM bronze_DealsFULL d
LEFT JOIN bronze_DealStages ds
    ON d.dealstage = ds.stage_id
WHERE d.cv_deal_type IS NOT NULL
  AND d.cv_deal_type != ds.pipeline_label
GROUP BY d.cv_deal_type, ds.pipeline_label
ORDER BY cnt DESC;


-- ============================================================
-- 8. CHECK: FieldOptions for bs_deal_type
--    If it's a HubSpot property, its options might be in 
--    bronze_FieldOptions / bronze_FieldOptionsFULL
-- ============================================================

SELECT *
FROM bronze_FieldOptionsFULL
WHERE property_name = 'bs_deal_type';

-- Also check DealProperties for it
SELECT *
FROM bronze_DealProperties
WHERE name = 'bs_deal_type';

-- And check if it's in the API properties list
SELECT *
FROM bronze_APIProperties
WHERE name = 'bs_deal_type';
