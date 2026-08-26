# vw_BuySellPipelineMatrix — Full Context

## What This View Does

Powers the Buy/Sell Pipeline Matrix report in Power BI. Combines deal data across 11 HubSpot pipelines into a single dataset where pipelines are rows and deal stages are columns. Built on Microsoft Fabric using DirectQuery mode.

**DirectQuery constraints:**
- No calculated columns, no Power Query transforms, no implicit date hierarchies
- All cleanup and logic lives in the SQL view or DAX measures
- Everything consolidated in one view with `SourcePipeline` flag to separate concerns
- Every COUNTROWS measure needs `NOT(ISBLANK(DealID))` guard to skip placeholder rows

---

## Data Sources

| Table | Workspace | Purpose |
|-------|-----------|---------|
| `bronze_DealStages` | `IT_Data_Gateway.HubSpot` | Stage definitions: stage_id, stage_label, display_order, pipeline_id, is_closed, probability |
| `bronze_DealPipelines` | `IT_Data_Gateway.HubSpot` | Pipeline definitions: id, label, display_order (pipeline-level sort) |
| `silver_Deals` | `IT_Data_Gateway.HubSpot` | Deal records — joins on `DealStage = stage_id` |
| `silver_Contacts` | `IT_Data_Gateway.HubSpot` | Contact names |
| `silver_Companies` | `IT_Data_Gateway.HubSpot` | Company names |

**Critical gotcha:** `bronze_DealStages` stores abbreviated pipeline labels (`10XBS | Buy Side DE`), not full names. Any WHERE clause filtering by pipeline must use the abbreviated form. Label expansion happens after filtering inside `bronze_trimmed`.

---

## View Structure

### CTEs

**`bronze_trimmed`**
- Filters to the 11 pipelines using abbreviated labels
- Expands labels to full display names for Power BI row labels
- TRIMs stage_label whitespace once
- Excludes: `Closed Lost`, `Closed Lost (Non-Renewed)`, `Exit Engagement`

**`stage_map`**
- All stage grouping logic lives here and only here — no duplication downstream
- Defines `StageName`, `StageGroup`, `StageGroupOrder` for every stage
- `StageOrder` = `display_order` from bronze_DealStages (not hardcoded)
- `PipelineOrder` = `bronze_DealPipelines.display_order` (not hardcoded)
- New stage in HubSpot? ELSE fallback surfaces it automatically (StageGroup = stage_label, StageGroupOrder = 99). Add one WHEN line here to properly place it — nothing else changes.

### Three-Part UNION ALL

**Part 1 — Real deals from 11 Buy/Sell pipelines**
- `SourcePipeline = 'Buy/Sell Pipeline'`
- INNER JOIN stage_map on DealStage = stage_id
- Excludes test deals: `%TEST%`, `%Big Daddy%`, `%Bizops Testing%`
- BAC renewal calculations baked in

**Part 2 — Placeholder rows**
- `SourcePipeline = 'Buy/Sell Pipeline'`
- NULL DealID — one row per pipeline × stage combo so empty stages still show as columns
- All deal columns are NULL; only stage metadata populated
- GROUP BY collapses duplicates
- Every COUNTROWS measure MUST include `NOT(ISBLANK(DealID))` or counts inflate

**Part 3 — CV Sales Pipeline Closed Won deals**
- `SourcePipeline = 'CV Sales Pipeline'`
- Pipeline id: `1495708`, filter: IsClosedWon = 1, BSDealType IS NOT NULL and != 'None'
- BSDealType used as PipelineLabel
- Hardcoded to StageGroup = 'Close / Member', StageGroupOrder = 13, StageOrder = 99
- No placeholder rows needed for this part

---

## Stage Group Mapping (current)

| StageGroupOrder | StageGroup | Stage Labels Included |
|----------------|-----------|----------------------|
| 1 | Sourcing | Sourcing |
| 2 | Initial Review / On-board | Initial Review, On-Board + Kick Off |
| 3 | AI Process | AI Process, Wokelo AI |
| 4 | Active Search | Active Search |
| 5 | Marketing | Marketing |
| 6 | Negotiation | Negotiation |
| 7 | Capital Structuring | Capital Structuring |
| 8 | Valuation Methodologies | Valuation Methodologies |
| 9 | LOI / Term Sheet | LOI / Term Sheet, Route to Workflow, Renewal |
| 10 | Due Diligence + Pre-Delivery | Due Diligence / Integration Plan, 5 Due Diligence / Integration Plan, Pre-Delivery |
| 11 | Closing | Closing |
| 12 | Event Engagement | Event / Attendee Conversion, Event / Client Engagement |
| 13 | Close / Member | Closed Won, Closed Won (Renewed), Member, Delivered, Active |
| 14 | On Hold | On Hold |
| 99 | (stage_label) | Any unmapped stage — ELSE fallback |

**Active → Close / Member:** Active is an Advisory Hours-only stage meaning the engagement is live and being delivered. Deal is already won — semantically equivalent to Member or Delivered. Rolled into Close/Member to avoid a column only one pipeline populates.

**On Hold → 14 (last):** A pause state, not a progression state. HubSpot puts On Hold at the highest display_order among active stages in every pipeline. Placed at the end of the matrix.

---

## Key Columns

| Column | Source | Notes |
|--------|--------|-------|
| `SourcePipeline` | Hardcoded | 'Buy/Sell Pipeline' or 'CV Sales Pipeline' — page-level filter |
| `PipelineLabel` | bronze_trimmed (expanded) | Row label in matrix |
| `StageName` | stage_map | Drill-down level in matrix |
| `StageGroup` | stage_map | Top-level matrix columns |
| `StageGroupOrder` | stage_map | Cross-pipeline column sort (business logic, not in HubSpot) |
| `StageOrder` | `display_order` from bronze_DealStages | Per-pipeline sequence — not cross-pipeline comparable |
| `PipelineOrder` | `bronze_DealPipelines.display_order` | Pipeline row sort — live, not hardcoded |
| `IsClosed` | bronze_DealStages.is_closed | 'true'/'false' — used for Open Deal Count filter |
| `StageProbability` | bronze_DealStages.probability | Per-pipeline per-stage, used for Weighted Pipeline Value |
| `CreateMonth` | `FORMAT(CreatedAtUTC, 'yyyy-MM')` | Workaround for DirectQuery no date hierarchy |
| `CreateYear` | `YEAR(CreatedAtUTC)` | Same workaround |
| `DaysUntilRenewal` | Calculated | `DATEDIFF(DAY, GETDATE(), BACRenewalDate)` |
| `RenewalStatus` | Calculated | 'Active', 'Within 90 Days', 'Past Due', 'No Renewal Date' |
| `DaysAsMember` | Calculated | `DATEDIFF(DAY, BACMembershipStartDate, GETDATE())` |

---

## The 11 Pipelines

| Abbreviated Label | Full Display Name |
|-------------------|------------------|
| 10XBS \| Buy Side DE | Buy Side Direct Engagement |
| 10XBS \| Sell Side DE | Sell Side Direct Engagement |
| 10XBS \| PBA | Partnership Buyout Advisory |
| 10XBS \| CSA | Capital Structure Advisory |
| 10XBS \| ARR | Acquisition Readiness Review |
| 10XBS \| ERR | Exit Readiness Review |
| 10XBS \| VA | Valuation Analysis |
| 10XBS \| BAC | BAC Members — Club |
| 10XBS \| AH | Advisory Hours |
| 10XBS \| BAS | Business Acquisition Summit |
| 10XBS \| BAW | Business Acquisition Workshop |

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

-- CV Sales Pipeline
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

-- BAC Renewal Tracker
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
**Filter:** SourcePipeline = "Buy/Sell Pipeline"
- 6 KPI cards: Deal Count, Open Deal Count, Pipeline Value, Weighted Pipeline Value, Delivered Count, Stale Deal Count
- Matrix: PipelineLabel (rows) × StageGroup (columns), drill-down to StageName
  - StageGroup sorted by StageGroupOrder, StageName sorted by StageOrder
- Slicers: PipelineLabel, DealOwnerName, CloseDate
- Data Status text card

### 2. Pipeline Health Page
**Filter:** SourcePipeline = "Buy/Sell Pipeline"
- Column chart: deals by DealOwnerName split by PipelineLabel
- Funnel: deal count by StageGroup
- Trend line: CreateMonth on X-axis, deal count on Y-axis

### 3. Drill Through Page
**Filter:** SourcePipeline = "Buy/Sell Pipeline"
- Drill-through filters: PipelineLabel, StageName, StageGroup
- Table: DealName, DealOwnerName, Amount, CloseDate, CreateDate, StageName, StageGroup, PipelineLabel
- Right-click any matrix cell on Summary → drill through to see actual deals

### 4. Sales Pipeline Page (CV Sales)
**Filter:** SourcePipeline = "CV Sales Pipeline"
- KPI cards: CV Sales Deal Count, CV Sales Value
- Summary matrix: BSDealType (rows), Deal Count, Pipeline Value
- Detail table: BSDealType, DealName, DealOwnerName, Amount, CloseDate
- All deals on this page are Closed Won from CV Sales Team Pipeline

### 5. BAC Renewal Tracker Page
**Filter:** PipelineLabel = "BAC Members — Club", SourcePipeline = "Buy/Sell Pipeline"
- KPI cards: BAC Member Count, Renewal Alert Count, Past Due Count, No Renewal Date Count
- 100% stacked bar: RenewalStatus distribution
- Detail table: DealName, DealOwnerName, BACMemberStatus, BACMembershipTier, BACMembershipStartDate, BACRenewalDate, DaysUntilRenewal, RenewalStatus, Amount
- Conditional formatting: Green = Active, Yellow = Within 90 Days, Red = Past Due, Gray = No Renewal Date
- **Data quality note:** Most BAC deals missing BACMembershipStartDate and BACRenewalDate — team needs to populate in HubSpot

---

## Key Design Decisions & Gotchas

1. **pipeline_label as row, NOT BSDealType** — BSDealType is semicolon-delimited multi-value (customer-level tag). Each deal lives in exactly one pipeline, so pipeline_label gives clean 1:1 mapping.

2. **Placeholder rows** — Part 2 ensures empty stages appear as columns. Every COUNTROWS measure MUST include `NOT(ISBLANK(DealID))`. SUM-based measures are safe since SUM ignores NULLs.

3. **StageOrder = display_order** — pulled directly from bronze_DealStages, not hardcoded. Sorts stages within a pipeline. Note: display_order restarts at 0 per pipeline — not cross-pipeline comparable. Cross-pipeline column sort is what StageGroupOrder handles.

4. **PipelineOrder = bronze_DealPipelines.display_order** — pulled live, not hardcoded. Pipeline row sort follows HubSpot's own ordering.

5. **stage_map CTE is the single source of truth** — StageName, StageGroup, and StageGroupOrder all defined once. Parts 1 and 2 both read from it. No duplication.

6. **New stage resilience** — ELSE fallback means any new HubSpot stage surfaces automatically in Power BI rather than silently disappearing. Add one WHEN line to stage_map to properly place it.

7. **Stage label "Closing"** — HubSpot uses "Closing" not "Close". Verify label in bronze_DealStages if confusion arises.

8. **pipeline_label abbreviation mismatch** — WHERE clause must use abbreviated labels. Using full names in the WHERE = zero rows silently.

9. **SourcePipeline flag** — critical for page-level filtering. Without it, Summary page includes CV Sales Pipeline deals and inflates Pipeline Value.

10. **DirectQuery date workaround** — CreateMonth and CreateYear computed in the view since DirectQuery has no implicit date hierarchies.

11. **Stage probabilities are pipeline-specific** — already handled since StageProbability travels with each deal row from the bronze_DealStages join.

---

## Adding a New HubSpot Stage

1. Stage surfaces automatically via the ELSE fallback — its own column, sorted last (99).
2. To properly place it: add one `WHEN stage_label = '...'` line to each of the three CASE expressions in `stage_map` — StageName, StageGroup, StageGroupOrder.
3. Nothing else in the view needs to change.
