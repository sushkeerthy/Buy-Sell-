# DEPRECATED — See vw_BuySellPipelineMatrix_context.md

This file has been merged into `vw_BuySellPipelineMatrix_context.md` which is the current source of truth. The content below is kept for reference only and may be outdated.

---

# Buy/Sell Pipeline Power BI Report — HubSpot Layer Context

## Project Overview

Power BI report for the Buy/Sell division at Cardone Ventures. Built on Microsoft Fabric using DirectQuery mode against the `IT_Data_Gateway` lakehouse. One consolidated SQL view (`vw_BuySellPipelineMatrix`) serves all HubSpot-based report pages.

**Key constraints:**
- DirectQuery mode — no calculated columns, no Power Query transforms, no implicit date hierarchies
- All cleanup and logic lives in the SQL view or DAX measures
- Minimizing views to reduce DirectQuery lag — everything is in one view with `SourcePipeline` flag to separate concerns
- Every COUNTROWS measure needs `NOT(ISBLANK(DealID))` guard to skip placeholder rows from the UNION ALL

---

## Data Sources

### Source Tables
- `[IT_Data_Gateway].[HubSpot].[silver_Deals]` — fact table, one row per deal
  - Key columns: DealID, DealStage (varchar, stores stage_id), Pipeline (stores pipeline_id), DealName, Amount, CloseDate, CreatedAtUTC, CreatedAtMST, HubspotOwnerID, DealOwnerName, IsClosedWon, IsClosedLost, BSDealType, BACMemberStatus, BACMembershipStartDate, BACMembershipTier, BACRenewalDate, CompanyID, ContactID, DealSource, Vertical, SubVertical
- `[IT_Data_Gateway].[HubSpot].[bronze_DealStages]` — dimension/lookup for pipelines and stages
  - Key columns: pipeline_id, pipeline_label, stage_id, stage_label, display_order, is_closed, probability
  - Join: `silver_Deals.DealStage = bronze_DealStages.stage_id`

### 11 Buy/Sell Pipelines
Buy Side Direct Engagement, Sell Side Direct Engagement, Partnership Buyout Advisory, Capital Structure Advisory, Acquisition Readiness Review (ARR), Exit Readiness Review (ERR), Valuation Analysis, BAC Members — Club, Advisory Hours, Business Acquisition Summit, Business Acquisition Workshop

---

## View: vw_BuySellPipelineMatrix

### Three-Part UNION ALL Structure

**Part 1: Real deals from 11 Buy/Sell pipelines**
- `SourcePipeline = 'Buy/Sell Pipeline'`
- Joins silver_Deals to bronze_DealStages on DealStage = stage_id
- Filters: only the 11 B/S pipelines, test deals excluded (TEST, Big Daddy, Bizops Testing), Closed Lost removed
- Stage cleanup: TRIM on all stage labels, "5 Due Diligence / Integration Plan" → cleaned, Wokelo AI → AI Process
- BAC renewal calculations baked in: DaysUntilRenewal, RenewalStatus, DaysAsMember

**Part 2: Placeholder rows**
- `SourcePipeline = 'Buy/Sell Pipeline'`
- NULL DealID — one row per pipeline × stage combo so empty stages still show as columns in the matrix
- All deal columns are NULL; only stage metadata is populated
- GROUP BY collapses duplicates
- This is why every COUNTROWS measure needs the ISBLANK(DealID) guard

**Part 3: CV Sales Pipeline Closed Won deals**
- `SourcePipeline = 'CV Sales Pipeline'`
- Deals from CV Sales Team Pipeline (pipeline_id = '1495708') that have a BSDealType tag identifying them as Buy/Sell products
- Filter: IsClosedWon = 1, BSDealType IS NOT NULL, BSDealType != 'None'
- BSDealType is used as PipelineLabel (groups by Buy/Sell product type)
- All hardcoded to StageGroup = 'Close / Member', StageName = 'Closed Won', StageOrder = 99
- No placeholder rows needed for this part

### Stage Hierarchy (12 groups)

| Order | StageGroup | Stages Inside | Notes |
|---|---|---|---|
| 1 | Sourcing | Sourcing | Single-stage group — StageName = StageGroup |
| 2 | Initial Review / On-board | Initial Review, On-Board + Kick Off | |
| 3 | Wokelo AI | AI Process, Wokelo AI | Wokelo AI renamed to AI Process in StageName |
| 4 | Valuation Methodologies | Valuation Methodologies | Single-stage group |
| 5 | Active Search | Active Search | Single-stage group |
| 6 | Marketing | Marketing | Single-stage group |
| 7 | Negotiation | Negotiation | Single-stage group |
| 8 | Capital Structuring | Capital Structuring | Single-stage group |
| 9 | LOI / Term Sheet | LOI / Term Sheet, Route to Workflow, Renewal | |
| 10 | Due Diligence + Pre-Delivery | Due Diligence / Integration Plan, Pre-Delivery | |
| 11 | Event Engagement | Event/Attendee Conversion, Event/Client Engagement | BAS and BAW stages |
| 12 | Close / Member | Closed / Delivered, Member | Closed Won → "Closed / Delivered" in StageName |

### Normalized StageOrder
StageOrder is hardcoded per stage name (not raw display_order from bronze_DealStages) so shared stage names like "Initial Review" don't create duplicate columns across pipelines. For example, Initial Review = 2 whether it's in Advisory Hours, Buy Side DE, or ERR.

### Single-Stage Group Fix
When a StageGroup has only one StageName inside it, drilling down in the matrix would show a duplicate (e.g., "Sourcing" → "Sourcing"). Fixed by making StageName match StageGroup for single-stage groups so drill-down shows one row, not two.

### Key Columns

| Column | Source | Notes |
|---|---|---|
| SourcePipeline | Hardcoded | 'Buy/Sell Pipeline' or 'CV Sales Pipeline' — used as page-level filter |
| PipelineLabel | bronze_DealStages.pipeline_label (Part 1/2) or BSDealType (Part 3) | Row label in matrix |
| StageName | Cleaned stage_label | Drill-down level in matrix |
| StageGroup | CASE mapped | Top-level matrix columns |
| StageGroupOrder | CASE mapped (1-12) | Sorts groups left to right |
| StageOrder | Hardcoded per stage name | Sorts stages within groups, normalized across pipelines |
| IsClosed | bronze_DealStages.is_closed | 'true'/'false' — used for Open Deal Count filter |
| StageProbability | bronze_DealStages.probability | Per-pipeline per-stage, used for Weighted Pipeline Value |
| CreateDate | CreatedAtUTC | Used for stale/fresh deal calculations and trend charts |
| CreateMonth | FORMAT(CreatedAtUTC, 'yyyy-MM') | Workaround for Direct Lake no date hierarchy |
| CreateYear | YEAR(CreatedAtUTC) | Same workaround |
| BACMemberStatus | silver_Deals | NULL for non-BAC pipelines |
| BACMembershipStartDate | silver_Deals | NULL for non-BAC pipelines |
| BACRenewalDate | silver_Deals | NULL for non-BAC pipelines |
| DaysUntilRenewal | Calculated | DATEDIFF(DAY, GETDATE(), BACRenewalDate) |
| RenewalStatus | Calculated | 'Active', 'Within 90 Days', 'Past Due', 'No Renewal Date' |
| DaysAsMember | Calculated | DATEDIFF(DAY, BACMembershipStartDate, GETDATE()) |

---

## DAX Measures

```dax
-- Core counts
Deal Count = 
CALCULATE(
    COUNTROWS(vw_BuySellPipelineMatrix), 
    NOT(ISBLANK(vw_BuySellPipelineMatrix[DealID]))
)

Open Deal Count = 
CALCULATE(
    [Deal Count], 
    vw_BuySellPipelineMatrix[IsClosed] = "false"
)

Delivered Count = 
CALCULATE(
    COUNTROWS(vw_BuySellPipelineMatrix),
    vw_BuySellPipelineMatrix[StageGroup] = "Close / Member",
    NOT(ISBLANK(vw_BuySellPipelineMatrix[DealID]))
)

-- Pipeline values
Pipeline Value = SUM(vw_BuySellPipelineMatrix[Amount])

Weighted Pipeline Value = 
SUMX(
    FILTER(vw_BuySellPipelineMatrix, NOT(ISBLANK(vw_BuySellPipelineMatrix[DealID]))),
    vw_BuySellPipelineMatrix[Amount] * vw_BuySellPipelineMatrix[StageProbability]
)

Pipeline Confidence = DIVIDE([Weighted Pipeline Value], [Pipeline Value], 0)

-- Deal aging
Stale Deal Count = 
COUNTROWS(
    FILTER(
        vw_BuySellPipelineMatrix,
        NOT(ISBLANK(vw_BuySellPipelineMatrix[DealID]))
        && DATEDIFF(vw_BuySellPipelineMatrix[CreateDate], TODAY(), DAY) > 30
    )
)

Fresh Deal Count = 
COUNTROWS(
    FILTER(
        vw_BuySellPipelineMatrix,
        NOT(ISBLANK(vw_BuySellPipelineMatrix[DealID]))
        && DATEDIFF(vw_BuySellPipelineMatrix[CreateDate], TODAY(), DAY) <= 30
    )
)

Avg Days in Pipeline = 
AVERAGEX(
    FILTER(vw_BuySellPipelineMatrix, NOT(ISBLANK(vw_BuySellPipelineMatrix[DealID]))),
    DATEDIFF(vw_BuySellPipelineMatrix[CreateDate], TODAY(), DAY)
)

-- CV Sales Pipeline measures
CV Sales Deal Count = 
CALCULATE(
    COUNTROWS(vw_BuySellPipelineMatrix),
    vw_BuySellPipelineMatrix[SourcePipeline] = "CV Sales Pipeline"
)

CV Sales Value = 
CALCULATE(
    SUM(vw_BuySellPipelineMatrix[Amount]),
    vw_BuySellPipelineMatrix[SourcePipeline] = "CV Sales Pipeline"
)

-- BAC Renewal Tracker measures
BAC Member Count = 
CALCULATE(
    COUNTROWS(vw_BuySellPipelineMatrix),
    NOT(ISBLANK(vw_BuySellPipelineMatrix[DealID]))
)

Renewal Alert Count = 
CALCULATE(
    COUNTROWS(vw_BuySellPipelineMatrix),
    vw_BuySellPipelineMatrix[RenewalStatus] = "Within 90 Days",
    NOT(ISBLANK(vw_BuySellPipelineMatrix[DealID]))
)

Past Due Count = 
CALCULATE(
    COUNTROWS(vw_BuySellPipelineMatrix),
    vw_BuySellPipelineMatrix[RenewalStatus] = "Past Due",
    NOT(ISBLANK(vw_BuySellPipelineMatrix[DealID]))
)

No Renewal Date Count = 
CALCULATE(
    COUNTROWS(vw_BuySellPipelineMatrix),
    vw_BuySellPipelineMatrix[RenewalStatus] = "No Renewal Date",
    NOT(ISBLANK(vw_BuySellPipelineMatrix[DealID]))
)

-- Data status
Data Status = 
"Data through " &
FORMAT(
    MAX(vw_BuySellPipelineMatrix[CreateDate]) - TIME(7, 0, 0),
    "MMM d, yyyy h:mm AM/PM"
) &
" AZ  •  Viewed " &
FORMAT(NOW() - TIME(7, 0, 0), "MMM d, h:mm AM/PM") & " AZ"
```

---

## Report Pages

### 1. Summary Page
**Page-level filter:** SourcePipeline = "Buy/Sell Pipeline"

**Visuals:**
- 6 KPI cards: Deal Count, Open Deal Count, Pipeline Value, Weighted Pipeline Value, Delivered Count, Stale Deal Count
- Info button tooltips on each card with definitions (Shannon's request)
- Matrix visual: PipelineLabel (rows) × StageGroup (columns) with drill-down to StageName
  - StageGroup sorted by StageGroupOrder, StageName sorted by StageOrder
- Slicers: PipelineLabel, DealOwnerName, CloseDate
- Data Status text card

### 2. Pipeline Health Page
**Page-level filter:** SourcePipeline = "Buy/Sell Pipeline"

**Visuals:**
- Column chart: deals by DealOwnerName split by PipelineLabel
- Funnel: deal count by StageGroup
- Trend line: CreateMonth on X-axis, deal count on Y-axis

### 3. Drill Through Page
**Page-level filter:** SourcePipeline = "Buy/Sell Pipeline"

**Drill-through filters:** PipelineLabel, StageName, StageGroup

**Visuals:**
- Table with deal-level detail: DealName, DealOwnerName, Amount, CloseDate, CreateDate, StageName, StageGroup, PipelineLabel
- Right-click any matrix cell on Summary page → drill through to see actual deals

### 4. Sales Pipeline Page (CV Sales)
**Page-level filter:** SourcePipeline = "CV Sales Pipeline"

**Visuals:**
- 2 KPI cards: CV Sales Deal Count, CV Sales Value
- Summary matrix: BSDealType (rows), Deal Count, Pipeline Value (values)
- Detail table: BSDealType, DealName, DealOwnerName, Amount, CloseDate
- Note: page title should explicitly say "Closed Won" — all deals on this page are Closed Won from the CV Sales Team Pipeline

### 5. BAC Renewal Tracker Page
**Page-level filter:** PipelineLabel = "BAC Members — Club", SourcePipeline = "Buy/Sell Pipeline"

**Visuals:**
- 4 KPI cards: BAC Member Count, Renewal Alert Count, Past Due Count, No Renewal Date Count
- 100% stacked bar chart showing RenewalStatus distribution
- Detail table: DealName, DealOwnerName, BACMemberStatus, BACMembershipTier, BACMembershipStartDate, BACRenewalDate, DaysUntilRenewal, RenewalStatus, Amount
- Conditional formatting on RenewalStatus: Green = Active, Yellow = Within 90 Days, Red = Past Due, Gray = No Renewal Date

**Data quality note:** Only 3 of 14 BAC deals have BACMembershipStartDate and BACRenewalDate populated. The rest show "No Renewal Date." Team needs to populate these in HubSpot.

---

## Key Design Decisions & Gotchas

1. **pipeline_label as row, NOT BSDealType** — BSDealType is semicolon-delimited multi-value (customer-level tag). Each deal lives in exactly one pipeline, so pipeline_label gives clean 1:1 mapping.

2. **Placeholder rows** — the UNION ALL Part 2 ensures empty stages appear as columns. Every COUNTROWS measure MUST include `NOT(ISBLANK(DealID))` or counts will be inflated. SUM-based measures are safe since SUM ignores NULLs.

3. **StageOrder normalized** — hardcoded per stage name, not raw display_order from bronze_DealStages. Without this, "Initial Review" in Advisory Hours (display_order=2) and "Initial Review" in Buy Side DE (display_order=3) create duplicate columns.

4. **Single-stage groups** — StageName = StageGroup when only one stage exists in the group. Prevents drill-down from showing "Sourcing → Sourcing" as two rows.

5. **Test deal exclusion** — `DealName NOT LIKE '%TEST%' AND NOT LIKE '%Big Daddy%' AND NOT LIKE '%Bizops Testing%'`

6. **Closed Lost exclusion** — `TRIM(stage_label) NOT IN ('Closed Lost', 'Closed Lost (Non-Renewed)')` — these are filtered out entirely, not shown as a stage.

7. **SourcePipeline flag** — critical for page-level filtering. Without it, Summary page would include CV Sales Pipeline deals and inflate Pipeline Value. Every page except BAC Renewal Tracker (which filters on PipelineLabel) must have a SourcePipeline filter.

8. **Direct Lake constraints** — no calculated columns, no Power Query transforms, no implicit date hierarchies. CreateMonth and CreateYear are computed in the view as a workaround.

9. **Stage probabilities are pipeline-specific** — Advisory Hours Sourcing = 20%, Buy Side DE Sourcing = 10%. This is already handled since StageProbability travels with each deal row from the bronze_DealStages join.

---

## Data Profile (approximate)

- ~106 real deals across 8-9 of 11 pipelines (BAS and BAW had only test deals)
- Pipeline is early-stage heavy: ~69 in Sourcing, ~37 in Initial Review
- Pipeline Value ~$1.91M raw, heavily concentrated in Sourcing
- 18 CV Sales Pipeline Closed Won deals with B/S deal types, totaling ~$1.85M
- 14 BAC Members deals, only 3 with renewal dates populated
- Weighted Pipeline Value significantly lower than raw due to early-stage concentration

---

## Full View SQL

The view is saved at: `/mnt/user-data/outputs/vw_BuySellPipelineMatrix.sql`

Three-part UNION ALL:
- Part 1 (lines 19-170): Real deals from 11 B/S pipelines with BAC renewal calculations
- Part 2 (lines 175-293): Placeholder rows with GROUP BY
- Part 3 (lines 299-367): CV Sales Pipeline Closed Won deals
