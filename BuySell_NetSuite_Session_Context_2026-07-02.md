# Buy/Sell NetSuite Financial Layer — Session Context
**Date:** July 2, 2026

---

## 1. Source Exploration & EDA

**Three sources investigated:**
- `FactGL` — raw GL ledger, source for TCV (Sales Orders)
- `vwCashDefinition` (Aaron's view) — invoice/payment matching, initially considered for cash
- `bzo_CashbyProduct` (Shannon's view) — cash allocated to invoice lines, **final choice for cash**

**Final source decisions:**
- **TCV** → `FactGL` + LEFT JOIN to `bzo_CashbyProduct` for `SOLinkPath` subscription workaround
- **Cash Collected** → `bzo_CashbyProduct` using `CashAllocatedToLine`, excluding `CashType = '4-CustCred'`

---

## 2. Key Filters & Joins

**FactGL product filter:**
```sql
p.ProductCategoryName = '10X Buy Sell'
OR p.ProductSubCategoryName = 'Business Acquisition Summit'
```
Must use `ProductCategoryName` not `ProductSubCategoryName` — early queries using subcategory missed BAC, DE, ARR, ERR, Workshop.

**FactGL TCV filters:**
```sql
gl.SourceTransactionTypeID = 'SalesOrd'
AND gl.GLLineID <> '0'                        -- TEXT comparison, not integer
AND gl.Amount IS NOT NULL
AND (
    gl.IsClosed = 0
    OR gl.IsClosed IS NULL
    OR bzo.SOLinkPath = 'Subscription'        -- subscription workaround
)
```

**bzo_CashbyProduct join to FactGL:**
```sql
LEFT JOIN (
    SELECT DISTINCT SOGLID, SOLinkPath
    FROM [IT_Data_Gateway].[dbo].[bzo_CashbyProduct]
    WHERE SOGLID IS NOT NULL
) bzo ON bzo.SOGLID = gl.GLID
```

**bzo Cash Collected filter:**
```sql
WHERE DepartmentName = 'Buy Sell'
AND CashType <> '4-CustCred'
```

---

## 3. Full List of Catches & Workarounds

1. **`GLLineID <> '0'` — TEXT comparison, not integer.** Header rows have GLLineID = '0' as a string. Using `<> 0` misses them.

2. **`IsClosed = 1` subscription workaround.** DE Buy Side and DE Sell Side SOs are closed (`IsClosed = 1`) intentionally — accounting workaround to auto-generate invoices. Must include these via `SOLinkPath = 'Subscription'` from bzo join. Confirmed by Deepak.

3. **Subscription SOs have NULL `SOLineContractValue`.** Even when included, DE products entered as subscriptions carry no contract value. TCV for DE is partially understated. Structural NetSuite limitation — flag in report footnote.

4. **Product filter must use `ProductCategoryName` not `ProductSubCategoryName`.** Subcategory filter only captured `10X Buy Sell` items directly, missing BAC, DE, ARR, ERR, Workshop which sit under different subcategories but the same category.

5. **Bundled SOs — same GLID, multiple product lines.** Example: Diversified Paving SO20509996902 has $15K Advisory + $15K BAC as separate lines. TCV SUM per product is correct. But `DISTINCTCOUNT(GLID)` and `DISTINCTCOUNT(CVCustomerID)` at total level undercounts across products.

6. **FPA missing 3 SOs vs our pull.** RIBUS ($80K Advisory), Katherine Latham ($35K BAC), Car Commander ($15K BAC Renewal). Our numbers are correct — FPA's NetSuite saved search filter is incomplete. Needs investigation on FPA's end.

7. **`CashAllocatedToLine` is the ONLY safe field to SUM in bzo.** All other amount fields (`AppliedAmount`, `InvoiceLineAmount`, `InvoiceTotalLineAmount`, `SOLineContractValue`) repeat at header level and inflate if summed directly. Confirmed in Shannon's usage guide.

8. **`InvoiceLineID` is positional not unique.** Line 1, 2, 3 on every invoice — not a primary key. Cannot use for deduplication or joining. Root cause of the fanout problem seen during EDA.

9. **Exclude `CashType = '4-CustCred'`.** Credit memos have `CashAllocatedToLine = 0` always — they don't move cash. Filter out for cash reporting. Keep for open balance credit memo deduplication (Shannon's ask).

10. **`SOLineContractValue` requires SOGLID deduplication.** Repeats on every payment row for the same SO line. Always deduplicate with `MAX(SOLineContractValue)` on SOGLID before summing.

11. **`SOLinkPath = 'Subscription'` rows have NULL `SOLineContractValue`.** Same issue as FactGL — DE products entered as subscriptions carry no contract value. TCV gap is structural, not fixable in the view.

12. **`SubsidiaryName` can be NULL on CashSale rows.** Use `InvoiceSubsidiaryKey` as the reliable subsidiary filter, not `SubsidiaryName`.

13. **`DepartmentName = 'Buy Sell'` — exact string.** Confirmed via discovery query. Not `'10X Buy/Sell'`, not `'Buy/Sell'`.

14. **Open balance credit memo deduplication — Shannon's ask, not yet implemented.** Must count each credit memo only once — deduplicate on `CashGLID` for CustCred rows before subtracting from open balance.

15. **`TransactionType = 'Invoice'` mandatory in vwCashDefinition.** Without it, credit memos with negative amounts are included, understating cash collected.

16. **`ProductCategory` unreliable in vwCashDefinition.** Same product can appear under multiple categories. Always filter by `ProductName` not `ProductCategory`.

17. **vwCashDefinition not chosen as primary cash source.** bzo_CashbyProduct is more purpose-built and Shannon-authored. vwCashDefinition better suited for invoice-level aging/collection status work if needed later.

18. **`CVCustomerID` not `CustomerID` for DimCustomer joins.** Raw `CustomerID` in FactGL is unreliable.

19. **`CVProductID` not `ProductID` or `ProductCode` for DimProduct joins.**

20. **Direct Lake — no calculated columns or Power Query transforms.** All logic must live in the SQL view or DAX measures. Everything pre-computed before it hits the model.

21. **T-SQL ORDER BY aliases not allowed.** Use ordinal position (`ORDER BY 2 DESC`) not column aliases.

22. **FactGL + bzo JOIN required for subscription TCV.** FactGL alone cannot distinguish a genuinely voided SO from a subscription workaround SO. bzo is doing double duty: primary cash source AND lookup for `SOLinkPath` subscription flag. Without this join all DE Buy Side and DE Sell Side TCV is lost.

---

## 4. Architecture Decision

**Two separate views, two fact tables in the semantic model.**

### `vw_BuySellNetSuiteFinancials` (TCV — update existing)
- Source: FactGL + bzo LEFT JOIN
- Add `IsValidSO` flag:
```sql
CASE
    WHEN gl.IsClosed = 0 OR gl.IsClosed IS NULL THEN 1
    WHEN bzo.SOLinkPath = 'Subscription'        THEN 1
    ELSE 0
END AS IsValidSO
```

### `vw_BuySellCashCollected` (Cash Collected — new view)
- Source: `bzo_CashbyProduct` directly
- Key fields: `CashAllocatedToLine`, `CashDate`, `CVCustomerID`, `CVProductID`, `CashType`
- Filter: `DepartmentName = 'Buy Sell'` AND `CashType <> '4-CustCred'`

Both views relate to `DimProduct` and `DimCustomer` on `CVProductID` and `CVCustomerID`.

---

## 5. Q2 2026 Validated Numbers

### TCV

| Product | Q2 TCV |
|---|---|
| BAC (all) | $385,000 |
| Advisory Services | $201,000 |
| DE Buy Side | $165,000 |
| DE Sell Side | $145,000 |
| BAC Renewal | $30,000 |
| BAC Add-On | $25,000 |
| ARR | $13,000 |
| ERR | $10,000 |
| Valuation | $5,000 |
| **Total** | **~$926,000** |

### Cash Collected

| Product | Q2 Cash |
|---|---|
| BAC | $289,000 |
| Advisory | $144,000 |
| DE Sell Side | $143,000 |
| DE Buy Side | $124,000 |
| BAC Add-On | $35,000 |
| BAC Renewal | $30,000 |
| ARR | $13,000 |
| ERR | $10,000 |
| Valuation | $5,000 |
| **Total** | **~$793,000** |

**Q2 Collection Rate: ~86%**

---

## 6. FPA Comparison

| Metric | FPA Q2 | Ours Q2 | Gap |
|---|---|---|---|
| TCV | $861,000 | $926,000 | $65,000 net |
| Cash Collected | $700,000 | $793,000 | $93,000 |

### FPA Missing SOs (confirmed by row-level reconcile)

| SO Number | Customer | Product | Amount | Notes |
|---|---|---|---|---|
| SO20509998076 | RIBUS | Advisory | $80,000 | Not in FPA export |
| SO20509997326 | Katherine Latham | BAC | $35,000 | Not in FPA export |
| SO20509997306 | Car Commander Virginia Inc | BAC Renewal | $15,000 | Not in FPA export |

FPA's NetSuite saved search filter is likely excluding these. Needs investigation on FPA's end.

---

## 7. Shannon Tracker — Open Items

1. **Open Balance deduplication** — reduce by unique credit memos, each counted only once
2. **Monthly Cash Collected stacked bar** — segmented by product
3. **Individual business drill-down** — per product performance view
4. **WoW (Mon–Sun) and MoM views** — week-over-week and month-over-month comparisons
5. **FPA missing SOs** — flag SO20509998076, SO20509997326, SO20509997306 to FPA team to fix their saved search

---

## 8. Next Steps

1. Write updated `vw_BuySellNetSuiteFinancials` SQL with `IsValidSO` flag
2. Write new `vw_BuySellCashCollected` SQL from bzo
3. Add both views to semantic model with DimProduct and DimCustomer relationships
4. Write full DAX measure set
5. Build report pages per Shannon's dashboard feedback
