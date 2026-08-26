# Buy/Sell NetSuite Financial Layer — Session Context
**Date:** July 6, 2026
**Continues from:** BuySell_NetSuite_Session_Context_2026-07-02.md

---

## 1. Status Summary

Two SQL views built and validated against Q2 2026 in `IT_Data_Gateway`:

- **`vw_BuySellNetSuiteFinancials`** (TCV) — rebuilt from a stale pre-EDA draft that was never used in the report. Sources `FactGL`, LEFT JOIN to deduped `bzo_CashbyProduct` for `SOLinkPath`. Applies category fix, `GLLineID <> '0'` fix, `Amount IS NOT NULL`, and the subscription-workaround override on `IsClosed`. Computes `IsValidSO` flag.
- **`vw_BuySellCashCollected`** (Cash) — new view, sourced directly from `bzo_CashbyProduct`. Only exposes `CashAllocatedToLine` as summable (all other amount fields intentionally excluded — they repeat at header level). Filters `DepartmentName = 'Buy Sell'` and excludes `CashType = '4-CustCred'`.

**Validation result:** Total TCV $925,985 vs. expected ~$926,000. Total Cash $793,494 vs. expected ~$793,000. DE Buy Side ($165,000) and DE Sell Side ($145,000) both tied out exactly — confirms the subscription-workaround join/filter logic works correctly.

**Both views' full SQL is below in Section 5.**

---

## 2. Active Open Issue — `IsValidSO` Undercounts Closed-But-Real SOs

### How it was found
Investigating why one of the three known FPA-missing SOs (RIBUS, `SO20509998076`, $80K Advisory) was *also* missing from our own view — not just FPA's export. Traced to: `IsClosed = 1` and `SOLinkPath = 'Direct'` (not `'Subscription'`), so it fails the current `IsValidSO` filter entirely.

### Widening the search
A broader sweep for "closed, not-Subscription-linked, but with real cash attached" turned up **5 distinct SOs**, not just RIBUS:

| SO | Product | Amount | Cash Collected |
|---|---|---|---|
| SO20509998076 (RIBUS) | Advisory Services | $80,000 | $40,000 |
| SO205035216 | Advisory Services | $80,000 | $80,000 |
| SO8698 | Business Acquisition Club | $60,000 | $35,000 |
| SO16552 | Business Acquisition Club | $15,000 | $9,500 |
| SO16594 | Business Acquisition Club | $15,000 | $15,000 |

**Total: $250,000 in Amount, $179,500 in real cash collected — currently invisible to TCV.**

### What we learned about the GL structure
Each of these 5 SOs shows a paired positive/negative `SalesOrd` GL line on the same date (e.g., `SO8698`: +60000 / -60000, both dated 2024-04-15), with `GLLineID = '0'` on the negative line and `GLLineID = '1'` on the positive line. This is the **same mechanical pattern** originally attributed only to the DE Subscription workaround.

**Confirmed by the user (not Deepak yet):** this net-zero paired-line closing mechanism is a **general Cardone Ventures practice**, not DE-specific. So `IsClosed = 1` alone can no longer be trusted as a proxy for "voided" across the board — it also appears on legitimate, cash-collected deals in Advisory and BAC.

**Good news:** the existing `GLLineID <> '0'` filter already correctly isolates the true positive TCV line (`GLLineID = '1'`) for all 5 SOs — that part of the view doesn't need to change. The only gap is the `IsClosed = 1` exclusion being too broad.

### No credit memo activity found
Checked all 5 SOs for `CustCred`/refund activity in both `FactGL` and `bzo_CashbyProduct` — **none found**. Every GL row on these 5 SOs is `SourceTransactionTypeID = 'SalesOrd'`. Rules out "credit memo closed it back out" as the explanation.

### Proposed fix (NOT YET APPLIED to the view)
```sql
CASE
    WHEN gl.IsClosed = 0 OR gl.IsClosed IS NULL THEN 1
    WHEN bzo.SOLinkPath = 'Subscription'        THEN 1
    WHEN bzo.TotalCashAllocated > 0             THEN 1   -- NEW
    ELSE 0
END AS IsValidSO
```
Requires changing the `bzo` join subquery from `SELECT DISTINCT SOGLID, SOLinkPath` to also `SUM(CashAllocatedToLine) AS TotalCashAllocated` grouped by `SOGLID`.

### Why this hasn't been applied yet
Need to validate the inverse population first — closed SOs with **zero** cash collected — to confirm those really are genuine voids, not some other edge case that would make "cash > 0" an unsafe general rule. Two queries were just written to investigate this (Section 4) — **results not yet seen as of this handoff.**

### After validation, still need
- Deepak conversation: confirm this general net-zero closing mechanism and get sign-off on the cash-based `IsValidSO` rule (framed as "is this a general Cardone Ventures pattern, and does 'real cash collected' safely distinguish valid from void closed SOs" — not framed as DE-specific like the original ask).
- Re-run Q2 validation after the fix — expect TCV to increase by close to $250K (Amount basis), and the FPA gap to shrink.

---

## 3. Known Data Quirks Discovered This Session (in addition to the original EDA list)

- **`GLID` is an internal surrogate key** (e.g., `2781192`), not the human-readable SO number. The SO number (`SO20509998076`) lives in `GLDisplayName` as `"Sales Order #SO..."`. Use `LIKE '%SO...%'` on `GLDisplayName`, not `GLID =`, when looking up a specific SO.
- **A `ProductGroup` value `"Buy Side - Success Fee"`** surfaced during testing — not one of the 9 products in the original validated Q2 table. Not yet resolved whether it should roll into "DE Buy Side" or is a distinct, previously-missing line. Flagged for Shannon, not yet raised.
- **Operator precedence bug risk:** `WHERE x LIKE 'A' OR x LIKE 'B' AND date >= ... AND date < ...` evaluates `AND` before `OR` — silently drops the date filter on the first condition. Always parenthesize `OR` groups explicitly when combining with date range filters.
- **`bzo_CashbyProduct` fans out per SO** (multiple cash rows per `SOGLID`) — any diagnostic query joining `FactGL` to raw `bzo` without deduping/aggregating will inflate row counts and can make a single SO look like multiple. Always `GROUP BY` the SO and `SUM`/`MAX` the `bzo` columns in ad hoc queries, not just in the views.
- **ARR (Acquisition Readiness Review)** showed $12,500 in the new view vs. $13,000 in the original EDA doc — small $500 gap, likely rounding in the manual EDA pass, not yet fully reconciled. Low priority.
- **Total-match ≠ correctness:** the view's Q2 total ($925,985) landed within $15 of the original manual EDA total ($926,000) *despite* the view being incomplete by ~$250K in Amount on the 5-SO issue above. Likely means the original manual EDA total was built with different, less consistent inclusion logic (e.g., manually including known FPA-gap SOs by name). Lesson: matching totals should not be treated as proof of correctness — edge-case sweeps (like the closed-SO check) are the real test.

---

## 4. Queries Written But Not Yet Resolved (run these first in the new chat)

### Query 1 — Full attribute profile of the 5 known SOs
```sql
SELECT
    gl.GLID,
    gl.GLDisplayName,
    p.ProductName,
    gl.Amount,
    gl.IsClosed,
    gl.GLStatus,
    gl.PaymentStatus,
    gl.AmountPaid,
    gl.SalesOrderCashCollected,
    gl.SalesOrderCashCollectedSameMonth,
    gl.CreateDate,
    gl.ModifyDate,
    gl.GLDate,
    bzo.SOLinkPath,
    SUM(bzo.CashAllocatedToLine)   AS TotalCashAllocated,
    COUNT(bzo.CashGLID)            AS CashRowCount
FROM [IT_Data_Gateway].[DWH].[FactGL] gl
JOIN [IT_Data_Gateway].[DWH].[DimProduct] p
    ON gl.CVProductID = p.CVProductID
LEFT JOIN [IT_Data_Gateway].[dbo].[bzo_CashbyProduct] bzo
    ON bzo.SOGLID = gl.GLID
WHERE gl.GLID IN (2781192, 2115542, 681594, 1552760, 1554741)
  AND gl.GLLineID = '1'
GROUP BY
    gl.GLID, gl.GLDisplayName, p.ProductName, gl.Amount, gl.IsClosed,
    gl.GLStatus, gl.PaymentStatus, gl.AmountPaid, gl.SalesOrderCashCollected,
    gl.SalesOrderCashCollectedSameMonth, gl.CreateDate, gl.ModifyDate,
    gl.GLDate, bzo.SOLinkPath
ORDER BY gl.Amount DESC
```

### Query 2 — Inverse population: closed, zero-cash SOs, with any voiding evidence
```sql
;WITH ZeroCashClosedSOs AS (
    SELECT
        gl.GLID,
        gl.GLDisplayName,
        p.ProductName,
        gl.Amount,
        gl.GLStatus,
        gl.PaymentStatus,
        gl.GLDate
    FROM [IT_Data_Gateway].[DWH].[FactGL] gl
    JOIN [IT_Data_Gateway].[DWH].[DimProduct] p
        ON gl.CVProductID = p.CVProductID
    LEFT JOIN [IT_Data_Gateway].[dbo].[bzo_CashbyProduct] bzo
        ON bzo.SOGLID = gl.GLID
    WHERE gl.SourceTransactionTypeID = 'SalesOrd'
      AND gl.GLLineID = '1'
      AND gl.IsClosed = 1
      AND (p.ProductCategoryName = '10X Buy Sell' OR p.ProductSubCategoryName = 'Business Acquisition Summit')
    GROUP BY gl.GLID, gl.GLDisplayName, p.ProductName, gl.Amount, gl.GLStatus, gl.PaymentStatus, gl.GLDate
    HAVING COALESCE(SUM(bzo.CashAllocatedToLine), 0) = 0
)
SELECT
    z.GLID,
    z.GLDisplayName,
    z.ProductName,
    z.Amount,
    z.GLStatus,
    z.PaymentStatus,
    z.GLDate,
    bzo.CashType,
    bzo.CashAllocatedToLine,
    bzo.CashDate
FROM ZeroCashClosedSOs z
LEFT JOIN [IT_Data_Gateway].[dbo].[bzo_CashbyProduct] bzo
    ON bzo.SOGLID = z.GLID
ORDER BY z.GLID, bzo.CashDate
```

**What to look for:** `CashType` codes indicating credit/refund even at `$0` allocated (the void signature), SOs with zero `bzo` rows at all (never invoiced/paid — cleaner void), and whether `GLStatus`/`PaymentStatus` reliably differ from the 5 known valid-but-closed SOs in Query 1.

---

## 5. Full Current View SQL

### `vw_BuySellNetSuiteFinancials`
```sql
CREATE VIEW vw_BuySellNetSuiteFinancials AS

SELECT
    gl.GLID,
    gl.GLLineID,
    gl.GLDisplayName,
    gl.GLDate,
    FORMAT(gl.GLDate, 'yyyy-MM')                           AS GLMonth,
    YEAR(gl.GLDate)                                        AS GLYear,
    gl.ReportingPeriod,
    gl.GLDescription,
    gl.GLLineDescription,
    gl.GLStatus,
    gl.SourceTransactionTypeID,
    gl.Amount                                              AS TCV,
    gl.AmountPaid,
    gl.SalesOrderCashCollected,
    gl.SalesOrderCashCollectedSameMonth,
    gl.PaymentStatus,
    gl.Quantity,
    gl.Price,
    gl.IsClosed,
    bzo.SOLinkPath,
    CASE
        WHEN gl.IsClosed = 0 OR gl.IsClosed IS NULL THEN 1
        WHEN bzo.SOLinkPath = 'Subscription'        THEN 1
        ELSE 0
    END                                                     AS IsValidSO,
    p.ProductName,
    p.ProductCode,
    p.SKU,
    p.ProductCategoryName,
    p.ProductSubCategoryName,
    p.ProductClassName,
    p.DepartmentName,
    p.SubsidiaryName,
    CASE
        WHEN p.ProductSubCategoryName = 'Business Acquisition Summit'
            THEN 'Business Acquisition Summit'
        ELSE p.ProductName
    END                                                     AS ProductGroup,
    CASE
        WHEN p.ProductSubCategoryName = 'Business Acquisition Summit'
            THEN 'BAS (CV Subsidiary)'
        ELSE '10X Buy Sell'
    END                                                     AS ProductSource,
    gl.CVCustomerID,
    c.CustomerName,
    gl.SalesRepID,
    gl.SalesRep2ID,
    gl.Elite,
    gl.CreateDate,
    gl.ModifyDate,
    gl.SubsidiaryID,
    gl.CVEventID

FROM [IT_Data_Gateway].[DWH].[FactGL] gl
JOIN [IT_Data_Gateway].[DWH].[DimProduct] p
    ON gl.CVProductID = p.CVProductID
LEFT JOIN [IT_Data_Gateway].[DWH].[DimCustomer] c
    ON gl.CVCustomerID = c.CVCustomerID
LEFT JOIN (
    SELECT DISTINCT SOGLID, SOLinkPath
    FROM [IT_Data_Gateway].[dbo].[bzo_CashbyProduct]
    WHERE SOGLID IS NOT NULL
) bzo
    ON bzo.SOGLID = gl.GLID

WHERE
    (p.ProductCategoryName = '10X Buy Sell'
        OR p.ProductSubCategoryName = 'Business Acquisition Summit')
    AND gl.SourceTransactionTypeID = 'SalesOrd'
    AND gl.GLLineID <> '0'
    AND gl.Amount IS NOT NULL
    AND (
        gl.IsClosed = 0
        OR gl.IsClosed IS NULL
        OR bzo.SOLinkPath = 'Subscription'
    )
```
**⚠ KNOWN GAP:** `IsValidSO` and the `WHERE` clause do not yet include the cash-based override discussed in Section 2. This view currently excludes the 5 SOs listed above ($250K Amount, $179.5K cash).

### `vw_BuySellCashCollected`
```sql
CREATE VIEW vw_BuySellCashCollected AS

SELECT
    bzo.CashGLID,
    bzo.SOGLID,
    bzo.SOLinkPath,
    bzo.CashDate,
    FORMAT(bzo.CashDate, 'yyyy-MM')                        AS CashMonth,
    YEAR(bzo.CashDate)                                     AS CashYear,
    bzo.CashType,
    bzo.CashAllocatedToLine,
    bzo.CVProductID,
    p.ProductName,
    p.ProductCategoryName,
    p.ProductSubCategoryName,
    p.DepartmentName,
    bzo.CVCustomerID,
    c.CustomerName

FROM [IT_Data_Gateway].[dbo].[bzo_CashbyProduct] bzo
JOIN [IT_Data_Gateway].[DWH].[DimProduct] p
    ON bzo.CVProductID = p.CVProductID
LEFT JOIN [IT_Data_Gateway].[DWH].[DimCustomer] c
    ON bzo.CVCustomerID = c.CVCustomerID

WHERE
    bzo.DepartmentName = 'Buy Sell'
    AND bzo.CashType <> '4-CustCred'
```

---

## 6. Not Yet Started

- Resolve `DimDate` relationship — `GLMonth`/`CashMonth` are string columns (`FORMAT(date, 'yyyy-MM')`), won't support time intelligence (WoW/MoM) without a real date key/dimension join.
- Open balance credit memo deduplication (Shannon's ask) — `CustCred` rows are fully excluded from `vw_BuySellCashCollected` right now, so this hasn't been addressed at all yet. Needs its own logic keyed on `CashGLID` dedup.
- Semantic model: add both views as separate fact tables, relate to `DimProduct`/`DimCustomer` on `CVProductID`/`CVCustomerID`. No direct relationship between the two fact views — Collection Rate is a cross-table DAX measure.
- Full DAX measure set (TCV, Cash Collected, Collection Rate, WoW/MoM, monthly stacked-by-product).
- Report pages per Shannon's dashboard feedback.
- Confirmed to be DirectQuery (not Direct Lake) — user confirmed this is an acceptable tradeoff, no need to revisit with Sai.

---

## 7. Environment Reminders

- Database: `IT_Data_Gateway`, DirectQuery mode. `[DWH]` schema for `FactGL`/`DimProduct`/`DimCustomer`; `[dbo]` schema for `bzo_CashbyProduct`.
- T-SQL: no `ORDER BY` aliases — use ordinal position.
- `GLLineID` comparisons must be text (`<> '0'`, not `<> 0`).
- `CashAllocatedToLine` is the only safe field to `SUM` in `bzo_CashbyProduct`.
- `InvoiceLineID` is positional, never use for joins/dedup.
- SO number is in `GLDisplayName` ("Sales Order #SO..."), not `GLID`.
