# Buy/Sell NetSuite Financial Layer — Session Context
**Date:** July 10, 2026
**Continues from:** BuySell_NetSuite_Session_Context_2026-07-06.md

---

## 1. Status Summary

This session moved from measure-building into full semantic model wiring and Power BI report construction on the Netsuite Report page. Core relationships, DAX measures, and the first two report pages' worth of visuals are built. Two live bugs are actively being debugged — both are **field/relationship binding issues, not DAX or data problems**.

---

## 2. Semantic Model — Relationships (as currently built)

```
DimDate[Date]        (1) → vw_BuySellNetSuiteFinancials[GLDate]     (many) — active
DimDate[Date]        (1) → vw_BuySellCashCollected[CashDate]        (many) — active
DimDate[Date]        (1) → vw_BuySellPipelineMatrix[CreateDate]     (many) — active

DimProduct[CVProductID]  (1) → vw_BuySellNetSuiteFinancials[CVProductID] (many) — active
DimProduct[CVProductID]  (1) → vw_BuySellCashCollected[CVProductID]      (many) — active

DimCustomer[CVCustomerID] (1) → vw_BuySellNetSuiteFinancials[CVCustomerID] (many) — active
DimCustomer[CVCustomerID] (1) → vw_BuySellCashCollected[CVCustomerID]      (many) — active

vw_DimSalesOrder[GLID] (1) → vw_BuySellNetSuiteFinancials[GLID]  (many) — active, BIDIRECTIONAL
vw_DimSalesOrder[GLID] (1) → vw_BuySellCashCollected[SOGLID]     (many) — INACTIVE
```

**`vw_BuySellNetSuiteFinancials[GLID] → vw_BuySellCashCollected[SOGLID]`** (the original direct fact-to-fact relationship) has been **deleted** — replaced by the `vw_DimSalesOrder` bridge below.

### Why the bridge table exists
`GLID` is not unique in `vw_BuySellNetSuiteFinancials` — a single SO can have multiple product lines (e.g., BAC + Advisory on one order), each sharing the same `GLID` with different `GLLineID`s. Confirmed via row-count query: **112 GLIDs have 2+ rows**, one has 9. This makes the original TCV↔Cash relationship many-to-many, which Power BI cannot filter correctly — it was silently returning the grand total on every row instead of a per-SO number.

**Fix:** `vw_DimSalesOrder` — a bridge view of `SELECT DISTINCT GLID FROM vw_BuySellNetSuiteFinancials` — sits between the two facts. It resolves the grain mismatch (TCV is line-level, Cash is SO-level) without collapsing TCV's legitimate per-product detail.

```sql
CREATE VIEW vw_DimSalesOrder AS
SELECT DISTINCT GLID
FROM [IT_Data_Gateway].[dbo].[vw_BuySellNetSuiteFinancials]
```
**Status:** Deployed and wired into the model.

### DimDate fix applied this session
`DimDate[Month]` column is broken — declared `dateTime` in the model but physically stored as `varchar` (bare month-number strings like `"12"`). Throws `QueryUserError` under Direct Lake's strict type enforcement. **Do not use `Month`.** Use `DimDate[MonthYear]` (text) with **Sort by Column → `FirstDayOfMonth`** set in Model view, or `DimDate[FirstDayOfMonth]` directly for a real sortable date axis. This is a `DimDate`-owning-table issue (likely Sai's domain) — not yet flagged to him.

---

## 3. DAX Measures Built This Session

### Core
```dax
Total TCV = SUM('vw_BuySellNetSuiteFinancials'[TCV])
Total Cash Collected = SUM('vw_BuySellCashCollected'[CashAllocatedToLine])
Collection Rate = DIVIDE([Total Cash Collected], [Total TCV])
SO Count = DISTINCTCOUNT('vw_BuySellNetSuiteFinancials'[GLID])
Avg Deal Size = DIVIDE([Total TCV], [SO Count])
```

### SO-linked (uses the bridge — only valid at SO grain, see Section 4)
```dax
Cash Collected (SO-linked) = 
CALCULATE(
    [Total Cash Collected],
    USERELATIONSHIP(vw_DimSalesOrder[GLID], vw_BuySellCashCollected[SOGLID])
)

Collection Rate (SO-linked) = 
DIVIDE([Cash Collected (SO-linked)], [Total TCV])
```

### MoM (Month-over-Month)
```dax
TCV PM = CALCULATE([Total TCV], DATEADD(DimDate[Date], -1, MONTH))
TCV MoM % = DIVIDE([Total TCV] - [TCV PM], [TCV PM])
Cash PM = CALCULATE([Total Cash Collected], DATEADD(DimDate[Date], -1, MONTH))
Cash MoM % = DIVIDE([Total Cash Collected] - [Cash PM], [Cash PM])

Collection Rate PM = CALCULATE([Collection Rate], DATEADD(DimDate[Date], -1, MONTH))
Collection Rate MoM (pp) = [Collection Rate] - [Collection Rate PM]
```

### WoW — rebuilt to calendar Mon–Sun per Shannon's actual spec (superseding original rolling-7-day version)
```dax
TCV PW (Calendar) = 
VAR CurrentWeekStart = MIN(DimDate[FirstDayOfWeek])
VAR PriorWeekStart = CurrentWeekStart - 7
VAR PriorWeekEnd = CurrentWeekStart - 1
RETURN
CALCULATE(
    [Total TCV],
    REMOVEFILTERS(DimDate),
    DimDate[Date] >= PriorWeekStart,
    DimDate[Date] <= PriorWeekEnd
)
TCV WoW % (Calendar) = DIVIDE([Total TCV] - [TCV PW (Calendar)], [TCV PW (Calendar)])

-- Mirror for Cash: Cash PW (Calendar), Cash WoW % (Calendar)
```
**Note:** older `[TCV WoW %]` / `[Cash WoW %]` (rolling 7-day `DATEADD`) measures are deprecated — confirm nothing in the report still references them, then delete.

### "This Month" / "This Week" headline card wrappers (TODAY()-anchored, no slicer required)
```dax
TCV MoM % (This Month) = 
CALCULATE(
    [TCV MoM %],
    DimDate[Date] >= DATE(YEAR(TODAY()), MONTH(TODAY()), 1),
    DimDate[Date] <= TODAY()
)
-- Mirror for Cash MoM % (This Month)

TCV WoW % (This Week) = 
VAR CurrentWeekStart = CALCULATE(MIN(DimDate[FirstDayOfWeek]), DimDate[Date] = TODAY())
RETURN
CALCULATE(
    [TCV WoW % (Calendar)],
    DimDate[Date] >= CurrentWeekStart,
    DimDate[Date] <= TODAY()
)
-- Mirror for Cash WoW % (This Week)
```
**Known DAX gotcha hit twice this session:** nesting `CALCULATE` directly inside another `CALCULATE`'s boolean filter argument throws *"A function 'CALCULATE' has been used in a True/False expression..."*. Fix: compute the date into a `VAR` first, then reference the scalar variable in the filter arguments.

### "No activity yet" text-output Display measures (for headline cards)
```dax
TCV MoM % (This Month) Display = 
VAR CurrentPeriodTCV = 
    CALCULATE([Total TCV], DimDate[Date] >= DATE(YEAR(TODAY()), MONTH(TODAY()), 1), DimDate[Date] <= TODAY())
VAR RawPct = [TCV MoM % (This Month)]
RETURN IF(CurrentPeriodTCV = 0, "No activity yet", FORMAT(RawPct, "0.0%"))

-- Mirrors built: Cash MoM % (This Month) Display, TCV WoW % (This Week) Display,
--                Cash WoW % (This Week) Display, Collection Rate MoM (This Month) Display
```
Why these exist: with zero date filter, MoM/WoW % measures return misleadingly-near-zero (not a bug — shifting an unbounded date range by a month/week produces near-total overlap, so `DIVIDE`'s zero-guard kicks in). These Display measures anchor to TODAY() and show readable text instead of a false "-100%"/"0%" when the current period genuinely has no activity yet.

### Product grouping
```dax
-- Added as a calculated column consideration; landed instead as ProductSubCategoryName usage.
-- ProductGroup (custom BAS-folding CASE logic) was evaluated and REJECTED — see Section 5.
```

---

## 4. Active Bugs Being Debugged (as of this handoff)

### Bug A — Cash Collected repeats the same number across unrelated rows/filters
**Symptom (2 confirmed instances this session):**
1. `CustomerName` slicer filters `SO Count`/`Total TCV` correctly but **`Total Cash Collected` stays at the unfiltered grand total** when a specific customer is selected.
2. Detail table grouped/filtered by `ProductSubCategoryName` shows **identical Cash Collected on every row**, regardless of actual product or SO.

**Root cause:** Slicers and table fields for `CustomerName`/`ProductSubCategoryName` are bound to the **fact table's own columns** (`vw_BuySellNetSuiteFinancials[CustomerName]`, `vw_BuySellNetSuiteFinancials[ProductSubCategoryName]`), not `DimCustomer`/`DimProduct`. Filtering a fact table by its own column doesn't propagate through the model relationships back up to the dimension and down into the *other* fact table — so Cash falls back to unfiltered.

**Fix (not yet fully applied across all visuals):** Rebuild slicers/table category columns to reference **`DimCustomer[CustomerName]`** and **`DimProduct[ProductSubCategoryName]`** instead of the fact-level columns. Once sourced from the dimension (the actively-related "1" side), `Total Cash Collected` and `Total TCV` both filter correctly and independently — no bridge or `USERELATIONSHIP` needed for category/customer-level aggregation.

### Bug B — SO-linked Collection Rate shows nonsensical percentages (up to 7770%+) at non-SO grain
**Symptom:** `Collection Rate (SO-linked)` is wildly wrong (139%–7770%) when displayed at `ProductSubCategoryName` or per-line grain, even after the bridge fix was correctly applied and verified working at the SO level.

**Root cause:** This is NOT a bug in the bridge or the measure — it's a **grain mismatch inherent to the data**. `Cash Collected (SO-linked)` correctly returns "total cash ever paid on this whole SO." But when an SO has multiple product lines (e.g., $497 Workshop line + $24,997 BAC line on the same order), **that same whole-SO cash total gets attributed to every line**, then divided by that one line's small TCV slice — producing e.g. $25,494 ÷ $497 = 5129%. Math is correct; the two numbers just don't represent the same scope.

**Resolution (design decision, not a code fix):**
- `Collection Rate (SO-linked)` / `Cash Collected (SO-linked)` are **only valid on a page/table that is one-row-per-SO** (deduped on `GLID`) — e.g., a dedicated SO-level drill-through table.
- For **any product-category or multi-line-per-SO view** (the summary table, stacked charts, etc.), use the **plain** `[Total Cash Collected]` / `[Collection Rate]` measures instead — once Bug A's dimension-column fix is applied, these aggregate correctly per category without the SO-level attribution problem.

### Open question raised but not yet resolved
Does NetSuite/`bzo_CashbyProduct` actually allocate cash per-product-line when a payment covers a multi-product SO, or does it tag the whole payment to one product (e.g. the first line)? `vw_BuySellCashCollected` already carries `CVProductID` independently of the TCV table, suggesting per-product allocation may already exist at the source — but this hasn't been confirmed. **Flagged to ask Brian or Deepak**, not yet sent.

---

## 5. Design Decisions Made This Session

- **Rejected a custom `ProductGroup` calculated column approach.** Considered folding BAS's 3 tiers into one label via a `DimProduct` calculated column, but Direct Lake doesn't support calculated columns on DirectQuery-sourced tables reliably in this setup, and a composite-model workaround (Import-mode mapping table) was judged more overhead than needed. **Decision: use `DimProduct[ProductSubCategoryName]` directly** — it already collapses to exactly 7 clean values (confirmed via EDA query) and requires no new objects.
- **`vw_BuySellPipelineMatrix`'s `BSDealType`/`PipelineLabel` fields were evaluated for reuse as a shared taxonomy with `ProductSubCategoryName`, and rejected for now.** `PipelineLabel` is purely a cosmetic relabeling of `BSDealType` (same taxonomy, nicer display strings) — but `BSDealType` itself is **multi-valued** (semicolon-delimited combos like `"BAC Member;Business Acquisition Workshop"`), meaning a single HubSpot deal can carry more than one category simultaneously. This is incompatible with `ProductSubCategoryName`'s single-valued-per-SO structure. Unifying pipeline and financial categorization is now considered its own future initiative requiring Shannon's judgment calls on the combo values — not something to fold into current measure-building.
- **Headline cards moved from raw MoM/WoW % cards to a hybrid layout:** trend combo charts (bar + % line) for context, plus small TODAY()-anchored headline cards for the "quick glance" number — cards alone were judged insufficient since rate-of-change metrics need trend context to be meaningful.
- **Collection Rate MoM uses percentage-point change**, not relative percentage change (e.g., 80%→88% displayed as "+8pp," not "+10%") — matches accounting-fluent audience expectations (Shannon).

---

## 6. Report Build Status — "Netsuite Report" Page

**Built and confirmed working:**
- KPI header cards: Total TCV, Total Cash Collected, Collection Rate, SO Count
- MoM/WoW headline cards for TCV and Cash (This Month / This Week), using Display measures with "No activity yet" fallback
- Two trend combo charts: Total Cash Collected + Cash MoM % by MonthYear; Total TCV + TCV MoM % by MonthYear (axis correctly using `MonthYear` with Sort by Column → `FirstDayOfMonth` applied — resolved an earlier alphabetical-sort bug)
- Two stacked column charts: Cash and TCV by MonthYear, segmented by `ProductSubCategoryName` (simplified — per-product MoM% line dropped from these per-line-item, decision above)
- Collection Rate MoM (pp) headline card added, using the Display-wrapper pattern

**Not yet fixed (Bugs A & B above) — page still has these active issues:**
- Product-category summary table (Total TCV / Cash Collected / Collection Rate by `ProductSubCategoryName`) — Cash Collected repeats across all categories, needs field swap to `DimProduct[ProductSubCategoryName]`
- SO/line-level detail table — Cash Collected inconsistently bound (sometimes plain measure showing category totals, sometimes correctly showing SO-linked); needs consistent binding to `Cash Collected (SO-linked)` AND the table needs to be understood as "same SO, same cash, multiple lines is expected" vs. "different SO showing same cash is a bug"
- `CustomerName` slicer — same fix, swap to `DimCustomer[CustomerName]`

**Explicitly deferred to a separate page (per user, this session):**
- The detailed SO-level table — user is treating "detail table" and "business drill-down" as the same deliverable, currently building it as an extension of the Netsuite Report / Netsuite Dashboard page shown in screenshots, filterable by `CustomerName` and `Product` (checkbox list of `ProductSubCategoryName` values)

---

## 7. Asana — Items Logged This Session

**Standalone task** (BI Reporting Pipeline → 10XBuySell section):
- "Clarify WoW definition with Shannon (rolling 7-day vs calendar week)" — **should now be marked resolved/closed**; Shannon's original ask ("WoW (Mon-Sun) and MoM view") was found this session to already specify calendar-week, so this is no longer an open question. WoW measures have been rebuilt accordingly (Section 3).

**Subtasks added under "Add Netsuite Records into the Report Analytics"** (gid `1215634046366065`):
- `[HIGH]` Open balance — deduplicate credit memos (Shannon's ask; blocked on confirming which `bzo_CashbyProduct` field carries the credit memo dollar value, since `CashAllocatedToLine` is always $0 for `CustCred` rows)
- `[MED]` Closed-SO IsValidSO gap — 5 SOs, ~$250K TCV / ~$179.5K cash excluded (carried over from 2026-07-06 session, intentionally still deferred)
- `[LOW]` Collection Rate WoW card — optional, only if Shannon wants WoW/MoM symmetry across all three headline metrics

---

## 8. Shannon's Full Ask List — Status Snapshot

| # | Ask | Status |
|---|---|---|
| 1 | Open balance — dedupe credit memos | ❌ Not started (Asana, HIGH) |
| 2 | Monthly Cash Collected stacked bar by product | ✅ Built |
| 3 | Individual business drill-down | 🟡 In progress — being merged with "detail table" build, filterable by customer/product, currently blocked by Bugs A & B |
| 4 | WoW (Mon–Sun) and MoM view | ✅ Rebuilt to calendar-week this session; Asana item should be closed |
| 5 | Pull TCV/Cash for Q2 2026 | ✅ Done (validated in prior session) |

---

## 9. Environment Reminders (carried forward + new this session)

- `DimDate[Month]` is broken (type mismatch) — use `FirstDayOfMonth` or `MonthYear` (with Sort by Column set to `FirstDayOfMonth`) instead. Never use `Month`.
- Direct Lake tables require exact declared-vs-physical type matches — no implicit conversion, unlike Import/DirectQuery. This is why the `Month` column throws where it might have silently worked elsewhere.
- Composite model confirmed in use: `DimDate`/dimension tables on Direct Lake, fact views on DirectQuery. Working as expected; no issues from the mixed mode itself so far.
- Nested `CALCULATE` inside another `CALCULATE`'s boolean filter argument is invalid DAX — always stage the inner result in a `VAR` first.
- Cash is recorded at the **whole-SO level** in `bzo_CashbyProduct`/`vw_BuySellCashCollected` — not allocated per line item on multi-product SOs (or at least, this needs source-system confirmation — see Section 4 open question). Any measure comparing SO-level cash to line-level TCV will produce nonsensical ratios; this is expected, not a bug, once understood.
- Fact table columns (e.g., `vw_BuySellNetSuiteFinancials[CustomerName]`) should generally NOT be used directly in slicers/visuals when cross-fact filtering (e.g., filtering Cash too) is needed — use the shared dimension table's column instead (`DimCustomer[CustomerName]`, `DimProduct[ProductSubCategoryName]`).

---

## 10. Not Yet Started (unchanged or newly identified)

- Fix Bug A (dimension-column field swaps) across all affected visuals
- Confirm Bug B understanding is correctly reflected in final table design (SO-level only for SO-linked measures)
- Ask Brian/Deepak: does NetSuite allocate cash per-product-line on multi-product SOs, or per-SO/header only?
- Open balance / credit memo dedup (Asana HIGH)
- Closed-SO `IsValidSO` gap (Asana MED, intentionally parked)
- Collection Rate WoW card (Asana LOW, optional)
- Delete deprecated rolling-7-day `TCV WoW %` / `Cash WoW %` measures once confirmed unused
- Flag `DimDate[Month]` column type issue to Sai
- Report pages beyond Netsuite Report/Dashboard (Pipeline Health, Sales Pipeline, BAC Renewal Tracker, Pipeline Probability, Drill Through tabs visible in nav bar — status/ownership of these not covered in this session)
