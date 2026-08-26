-- ============================================================
-- vw_BuySellPipelineMatrix
--
-- Stage mapping lives in ONE place (stage_map CTE).
-- Parts 1 and 2 both read from it — no duplication.
-- PipelineOrder comes from bronze_DealPipelines — no hardcoding.
-- StageOrder = display_order from bronze_DealStages — no hardcoding.
-- New stage added in HubSpot? It surfaces automatically via the
-- ELSE fallback (StageGroup = its label, StageGroupOrder = 99).
-- To properly place it, add one WHEN line to stage_map. Done.
-- ============================================================

CREATE OR ALTER VIEW [dbo].[vw_BuySellPipelineMatrix] AS

WITH

-- ── Step 1: trim whitespace once, filter to the 11 pipelines ──────────────
--   pipeline_label is expanded to full display names here so Power BI
--   row labels show the full name. The WHERE still uses the raw short
--   names because that's what bronze_DealStages actually contains.
bronze_trimmed AS (
    SELECT
        CASE pipeline_label
            WHEN '10XBS | Buy Side DE'  THEN 'Buy Side Direct Engagement'
            WHEN '10XBS | Sell Side DE' THEN 'Sell Side Direct Engagement'
            WHEN '10XBS | PBA'          THEN 'Partnership Buyout Advisory'
            WHEN '10XBS | CSA'          THEN 'Capital Structure Advisory'
            WHEN '10XBS | ARR'          THEN 'Acquisition Readiness Review'
            WHEN '10XBS | ERR'          THEN 'Exit Readiness Review'
            WHEN '10XBS | VA'           THEN 'Valuation Analysis'
            WHEN '10XBS | BAC'          THEN 'BAC Members — Club'
            WHEN '10XBS | AH'           THEN 'Advisory Hours'
            WHEN '10XBS | BAS'          THEN 'Business Acquisition Summit'
            WHEN '10XBS | BAW'          THEN 'Business Acquisition Workshop'
            ELSE pipeline_label
        END                             AS pipeline_label,
        pipeline_id,
        stage_id,
        is_closed,
        probability,
        display_order,
        TRIM(stage_label)   AS stage_label
    FROM [IT_Data_Gateway].[HubSpot].[bronze_DealStages]
    WHERE pipeline_label IN (
        '10XBS | Buy Side DE',
        '10XBS | Sell Side DE',
        '10XBS | PBA',
        '10XBS | CSA',
        '10XBS | ARR',
        '10XBS | ERR',
        '10XBS | VA',
        '10XBS | BAC',
        '10XBS | AH',
        '10XBS | BAS',
        '10XBS | BAW'
    )
    AND TRIM(stage_label) NOT IN (
        'Closed Lost',
        'Closed Lost (Non-Renewed)',
        'Exit Engagement'
    )
),

-- ── Step 2: apply all stage group logic ONCE ──────────────────────────────
--   To handle a new stage: add one WHEN line to StageName, StageGroup,
--   and StageGroupOrder. No other changes needed anywhere in the view.
--   Until you do, the ELSE fallback ensures the stage still appears —
--   it just sorts after all known groups (StageGroupOrder = 99).
stage_map AS (
    SELECT
        pipeline_label,
        pipeline_id,
        stage_id,
        is_closed,
        probability,
        display_order                                       AS StageOrder,

        -- StageName: passthrough; only two legacy label fixes needed
        CASE
            WHEN stage_label = 'Wokelo AI'                               THEN 'AI Process'
            WHEN stage_label = '5 Due Diligence / Integration Plan'      THEN 'Due Diligence / Integration Plan'
            ELSE stage_label
        END                                                 AS StageName,

        -- StageGroup: the cross-pipeline column buckets
        CASE
            WHEN stage_label = 'Sourcing'                                THEN 'Sourcing'
            WHEN stage_label IN ('Initial Review', 'On-Board + Kick Off') THEN 'Initial Review / On-board'
            WHEN stage_label IN ('AI Process', 'Wokelo AI')              THEN 'AI Process'
            WHEN stage_label = 'Active Search'                           THEN 'Active Search'
            WHEN stage_label = 'Marketing'                               THEN 'Marketing'
            WHEN stage_label = 'Negotiation'                             THEN 'Negotiation'
            WHEN stage_label = 'Capital Structuring'                     THEN 'Capital Structuring'
            WHEN stage_label = 'Valuation Methodologies'                 THEN 'Valuation Methodologies'
            WHEN stage_label IN ('LOI / Term Sheet', 'Route to Workflow', 'Renewal') THEN 'LOI / Term Sheet'
            WHEN stage_label IN ('Due Diligence / Integration Plan',
                '5 Due Diligence / Integration Plan', 'Pre-Delivery')    THEN 'Due Diligence + Pre-Delivery'
            WHEN stage_label = 'Closing'                                 THEN 'Closing'
            WHEN stage_label IN ('Event / Attendee Conversion', 'Event / Client Engagement') THEN 'Event Engagement'
            WHEN stage_label IN ('Closed Won', 'Closed Won (Renewed)', 'Member', 'Delivered', 'Active') THEN 'Close / Member'
            WHEN stage_label = 'On Hold'                                 THEN 'On Hold'
            ELSE stage_label   -- new stage appears as its own column
        END                                                 AS StageGroup,

        -- StageGroupOrder: left-to-right column sort across all pipelines
        CASE
            WHEN stage_label = 'Sourcing'                                THEN 1
            WHEN stage_label IN ('Initial Review', 'On-Board + Kick Off') THEN 2
            WHEN stage_label IN ('AI Process', 'Wokelo AI')              THEN 3
            WHEN stage_label = 'Active Search'                           THEN 4
            WHEN stage_label = 'Marketing'                               THEN 5
            WHEN stage_label = 'Negotiation'                             THEN 6
            WHEN stage_label = 'Capital Structuring'                     THEN 7
            WHEN stage_label = 'Valuation Methodologies'                 THEN 8
            WHEN stage_label IN ('LOI / Term Sheet', 'Route to Workflow', 'Renewal') THEN 9
            WHEN stage_label IN ('Due Diligence / Integration Plan',
                '5 Due Diligence / Integration Plan', 'Pre-Delivery')    THEN 10
            WHEN stage_label = 'Closing'                                 THEN 11
            WHEN stage_label IN ('Event / Attendee Conversion', 'Event / Client Engagement') THEN 12
            WHEN stage_label IN ('Closed Won', 'Closed Won (Renewed)', 'Member', 'Delivered', 'Active') THEN 13
            WHEN stage_label = 'On Hold'                                 THEN 14
            ELSE 99   -- new stage sorts after all known groups; fix by adding a WHEN above
        END                                                 AS StageGroupOrder

    FROM bronze_trimmed
)


-- ============================================================
-- PART 1: Real deals
-- ============================================================
SELECT
    'Buy/Sell Pipeline'                                     AS SourcePipeline,
    sm.pipeline_label                                       AS PipelineLabel,
    sm.StageName,
    sm.StageGroup,
    sm.StageGroupOrder,
    sm.StageOrder,
    dp.display_order                                        AS PipelineOrder,
    sm.is_closed                                            AS IsClosed,
    sm.probability                                          AS StageProbability,
    sm.pipeline_id                                          AS PipelineID,

    d.DealID,
    d.DealName,
    d.Amount,
    d.CloseDate,
    d.ExpectedCloseDate,
    d.CreatedAtUTC                                          AS CreateDate,
    d.CreatedAtMST,
    FORMAT(d.CreatedAtUTC, 'yyyy-MM')                       AS CreateMonth,
    YEAR(d.CreatedAtUTC)                                    AS CreateYear,
    d.HubspotOwnerID,
    d.DealOwnerName,
    d.SecondaryDealOwnerName,
    d.TertiaryDealOwnerName,
    d.IsClosedWon,
    d.IsClosedLost,
    d.BSDealType,
    d.CompanyID,
    d.ContactID,
    d.DealSource,
    d.Vertical,
    d.SubVertical,

    CONCAT(c.FirstName, ' ', c.LastName)                    AS ClientName,
    co.Name                                                 AS CompanyName,
    d.BSDealSize,
    d.TCV,
    d.EstimatedValue,
    d.DealStageProbability,
    d.SuccessFee,
    d.TimeInCurrentStage                                    AS StageEntryDate,
    DATEDIFF(DAY, d.TimeInCurrentStage, GETDATE())          AS DaysInCurrentStage,
    d.EstimatedValue * d.DealStageProbability               AS ExpectedWeightedValue,
    d.SuccessFee   * d.DealStageProbability                 AS ProbabilityExpectedFeeRevenue,

    d.BACMemberStatus,
    d.BACMembershipTier,
    d.BACMembershipStartDate,
    d.BACRenewalDate,

    CASE
        WHEN d.BACRenewalDate IS NOT NULL
            THEN DATEDIFF(DAY, GETDATE(), d.BACRenewalDate)
    END                                                     AS DaysUntilRenewal,

    CASE
        WHEN d.BACRenewalDate IS NULL                        THEN 'No Renewal Date'
        WHEN DATEDIFF(DAY, GETDATE(), d.BACRenewalDate) < 0  THEN 'Past Due'
        WHEN DATEDIFF(DAY, GETDATE(), d.BACRenewalDate) <= 90 THEN 'Within 90 Days'
        ELSE 'Active'
    END                                                     AS RenewalStatus,

    CASE
        WHEN d.BACMembershipStartDate IS NOT NULL
            THEN DATEDIFF(DAY, d.BACMembershipStartDate, GETDATE())
    END                                                     AS DaysAsMember

FROM [IT_Data_Gateway].[HubSpot].[silver_Deals] d
INNER JOIN stage_map sm
    ON d.DealStage = sm.stage_id
LEFT JOIN [IT_Data_Gateway].[HubSpot].[bronze_DealPipelines] dp
    ON sm.pipeline_id = dp.id
LEFT JOIN [IT_Data_Gateway].[HubSpot].[silver_Contacts] c
    ON d.ContactID = c.ContactID
LEFT JOIN [IT_Data_Gateway].[HubSpot].[silver_Companies] co
    ON d.CompanyID = co.CompanyID

WHERE
    d.DealName NOT LIKE '%TEST%'
    AND d.DealName NOT LIKE '%Big Daddy%'
    AND d.DealName NOT LIKE '%Bizops Testing%'


UNION ALL


-- ============================================================
-- PART 2: Placeholder rows — guarantees every stage column
--         exists in Power BI even when no deals are in it
-- ============================================================
SELECT
    'Buy/Sell Pipeline'                                     AS SourcePipeline,
    sm.pipeline_label                                       AS PipelineLabel,
    sm.StageName,
    sm.StageGroup,
    sm.StageGroupOrder,
    sm.StageOrder,
    dp.display_order                                        AS PipelineOrder,
    MAX(sm.is_closed)                                       AS IsClosed,
    MAX(sm.probability)                                     AS StageProbability,
    sm.pipeline_id                                          AS PipelineID,

    NULL AS DealID, NULL AS DealName, NULL AS Amount,
    NULL AS CloseDate, NULL AS ExpectedCloseDate,
    NULL AS CreateDate, NULL AS CreatedAtMST,
    NULL AS CreateMonth, NULL AS CreateYear,
    NULL AS HubspotOwnerID, NULL AS DealOwnerName,
    NULL AS SecondaryDealOwnerName, NULL AS TertiaryDealOwnerName,
    NULL AS IsClosedWon, NULL AS IsClosedLost, NULL AS BSDealType,
    NULL AS CompanyID, NULL AS ContactID, NULL AS DealSource,
    NULL AS Vertical, NULL AS SubVertical,
    NULL AS ClientName, NULL AS CompanyName,
    NULL AS BSDealSize, NULL AS TCV, NULL AS EstimatedValue,
    NULL AS DealStageProbability, NULL AS SuccessFee,
    NULL AS StageEntryDate, NULL AS DaysInCurrentStage,
    NULL AS ExpectedWeightedValue, NULL AS ProbabilityExpectedFeeRevenue,
    NULL AS BACMemberStatus, NULL AS BACMembershipTier,
    NULL AS BACMembershipStartDate, NULL AS BACRenewalDate,
    NULL AS DaysUntilRenewal, NULL AS RenewalStatus, NULL AS DaysAsMember

FROM stage_map sm
LEFT JOIN [IT_Data_Gateway].[HubSpot].[bronze_DealPipelines] dp
    ON sm.pipeline_id = dp.id

GROUP BY
    sm.pipeline_label, sm.pipeline_id,
    sm.StageName, sm.StageGroup, sm.StageGroupOrder, sm.StageOrder,
    dp.display_order


UNION ALL


-- ============================================================
-- PART 3: CV Sales Pipeline — Closed Won Buy/Sell products
-- ============================================================
SELECT
    'CV Sales Pipeline'                                     AS SourcePipeline,
    d.BSDealType                                            AS PipelineLabel,
    'Closed Won'                                            AS StageName,
    'Close / Member'                                        AS StageGroup,
    13                                                      AS StageGroupOrder,
    99                                                      AS StageOrder,
    99                                                      AS PipelineOrder,
    'true'                                                  AS IsClosed,
    CAST(1.0 AS real)                                       AS StageProbability,
    '1495708'                                               AS PipelineID,

    d.DealID, d.DealName, d.Amount, d.CloseDate, d.ExpectedCloseDate,
    d.CreatedAtUTC                                          AS CreateDate,
    d.CreatedAtMST,
    FORMAT(d.CreatedAtUTC, 'yyyy-MM')                       AS CreateMonth,
    YEAR(d.CreatedAtUTC)                                    AS CreateYear,
    d.HubspotOwnerID, d.DealOwnerName,
    d.SecondaryDealOwnerName, d.TertiaryDealOwnerName,
    d.IsClosedWon, d.IsClosedLost, d.BSDealType,
    d.CompanyID, d.ContactID, d.DealSource, d.Vertical, d.SubVertical,

    CONCAT(c.FirstName, ' ', c.LastName)                    AS ClientName,
    co.Name                                                 AS CompanyName,
    d.BSDealSize, d.TCV, d.EstimatedValue, d.DealStageProbability, d.SuccessFee,
    d.TimeInCurrentStage                                    AS StageEntryDate,
    DATEDIFF(DAY, d.TimeInCurrentStage, GETDATE())          AS DaysInCurrentStage,
    d.EstimatedValue * d.DealStageProbability               AS ExpectedWeightedValue,
    d.SuccessFee   * d.DealStageProbability                 AS ProbabilityExpectedFeeRevenue,

    d.BACMemberStatus, d.BACMembershipTier,
    d.BACMembershipStartDate, d.BACRenewalDate,

    CASE
        WHEN d.BACRenewalDate IS NOT NULL
            THEN DATEDIFF(DAY, GETDATE(), d.BACRenewalDate)
    END                                                     AS DaysUntilRenewal,

    CASE
        WHEN d.BACRenewalDate IS NULL                        THEN 'No Renewal Date'
        WHEN DATEDIFF(DAY, GETDATE(), d.BACRenewalDate) < 0  THEN 'Past Due'
        WHEN DATEDIFF(DAY, GETDATE(), d.BACRenewalDate) <= 90 THEN 'Within 90 Days'
        ELSE 'Active'
    END                                                     AS RenewalStatus,

    CASE
        WHEN d.BACMembershipStartDate IS NOT NULL
            THEN DATEDIFF(DAY, d.BACMembershipStartDate, GETDATE())
    END                                                     AS DaysAsMember

FROM [IT_Data_Gateway].[HubSpot].[silver_Deals] d
LEFT JOIN [IT_Data_Gateway].[HubSpot].[silver_Contacts] c
    ON d.ContactID = c.ContactID
LEFT JOIN [IT_Data_Gateway].[HubSpot].[silver_Companies] co
    ON d.CompanyID = co.CompanyID

WHERE
    d.Pipeline = '1495708'
    AND d.IsClosedWon = 1
    AND d.BSDealType IS NOT NULL
    AND d.BSDealType != 'None'
    AND d.DealName NOT LIKE '%TEST%'
    AND d.DealName NOT LIKE '%Big Daddy%'
    AND d.DealName NOT LIKE '%Bizops Testing%'
