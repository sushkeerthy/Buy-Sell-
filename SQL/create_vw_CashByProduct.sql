-- =============================================================================
-- View  : dbo.vw_CashbyProduct
-- Purpose: Cash applied to invoices at invoice-line level.
--          One row per cash transaction × invoice line.
-- Streams:
--   1) Regular cash     — CustPymt, DepAppl, Deposit, CustRfnd
--   2) Credit memo      — CustCred applied to invoices; CashAllocatedToLine = 0
--                         (diagnostic confirmed all CMs are AR write-offs, not cash reversals)
--   3) Cash Sale        — self-contained SO/Invoice/Payment in one transaction
--   4) Cash Sale Refund — 4-CashRfnd reversals of CashSale transactions (SaleRet/CostRtrn)
--                         CashAllocatedToLine is negative. 4-RtnAuth path pending.
--   5) Journal Entry    — Invoice → JE → Cash bridges (cross-entity deposits/payments)
--                         Write-off JEs excluded via EXISTS check on outgoing cash link.
-- Subsidiary scope : Cardone Ventures, LLC (4-11), 10X Roofing Management, LLC (4-17),
--                    10X Buy/Sell, LLC (4-3), 10X HomeServe, LLC (4-20)
--                    Resolved dynamically from [Netsuite].[dbo].silver_Subsidiary by name.
-- Date scope       : 2023-01-01 forward
-- Architecture     : 22 CTEs + UNION ALL (no outer wrapper)
--
-- Change log (vs. original):
--   - All SourceTransactionTypeID filters replaced with SourceTransactionTypeKey
--     using 4-prefixed values (TransactionTypeID is NULL across all FactGL rows).
--   - CustRefund corrected to 4-CustRfnd (abbreviated key).
--   - GLLineID comparisons changed to VARCHAR literals ('0', <> '0').
--   - InvoiceLines filtered to 4-CustInvc only — excludes 18-Bill lines.
--   - Subsidiary whitelist added to InvoiceHeader, CreditMemoHeader, CashSaleHeader.
--   - GLDate >= '2023-01-01' applied to output streams (not credit CTEs).
--   - Stream 2: CashAllocatedToLine = 0 (FIFO logic removed — all CMs are AR write-offs).
--   - Stream 3: CashSale added (3 new CTEs + UNION ALL).
--   - Multi-currency: AppliedAmount × ExchangeRate converts FactGLLink source currency → USD.
--
-- Key Design Notes:
--   - GLIDs and GLLineID are VARCHAR — string literals used throughout.
--   - DepAppl date = the application event date (naturally correct via CashDetail).
--   - Stream 2 CashAllocatedToLine is always 0 — credit memos reduce AR, not cash.
--     AppliedAmount and CreditMemoAppliedToInvoice are populated for reference.
--   - SOLineContractValue repeats per payment row by design — do NOT aggregate.
--   - Credit memos report in the period the credit is issued.
-- =============================================================================

CREATE   VIEW dbo.vw_CashbyProduct AS
WITH

-- ============================================================================
-- SECTION 1 — CASH STREAM CTEs
-- ============================================================================

CashApplications AS (
-- FactGLLink Payment links at header level: Invoice (Prev) → Cash (Next).
-- No date filter — full history required for accurate FIFO ceiling.
    SELECT
        link.PrevGLID        AS InvoiceGLID,
        link.NextGLID        AS CashGLID,
        link.AppliedAmount
    FROM dbo.FactGLLink link
    WHERE link.LinkType     = 'Payment'
      AND link.PrevGLLineID = 0
),

CashDetail AS (
-- Header attributes for every cash-type transaction.
-- ExchangeRate converts FactGLLink.AppliedAmount (source currency) → USD.
    SELECT
        gl.GLID,
        gl.GLDisplayName             AS CashDisplayName,
        gl.GLDate                    AS CashDate,
        gl.ReportingPeriod           AS CashReportingPeriod,
        gl.SourceTransactionTypeKey  AS CashType,
        gl.PaymentMethod,
        gl.CVCustomerID              AS CashCVCustomerID,
        gl.SourceSubsidiaryKey       AS CashSubsidiaryKey,
        gl.SourceCurrencyID,
        gl.SourceSalesRepID,
        gl.SourceSalesRep2ID,
        gl.GLURL                     AS CashURL,
        COALESCE(gl.ExchangeRate, 1) AS ExchangeRate   -- used to convert AppliedAmount → USD
    FROM dbo.FactGL gl
    WHERE gl.GLLineID = '0'
      AND gl.SourceTransactionTypeKey IN (
            '4-CustPymt', '4-DepAppl', '4-Deposit', '4-CustRfnd'
          )
),

-- ============================================================================
-- SECTION 2 — CREDIT MEMO CTEs
-- ============================================================================

CreditApps AS (
-- CustCred transactions applied to invoices via Payment links.
-- AppliedAmount × ExchangeRate converts source currency → USD.
    SELECT
        link.PrevGLID                                              AS InvoiceGLID,
        link.NextGLID                                              AS CreditGLID,
        link.AppliedAmount * COALESCE(gl.ExchangeRate, 1)         AS CreditAppliedAmount,  -- USD
        gl.GLDate                                                  AS CreditDate
    FROM dbo.FactGLLink link
    JOIN dbo.FactGL gl
      ON gl.GLID     = link.NextGLID
     AND gl.GLLineID = '0'
    WHERE link.LinkType     = 'Payment'
      AND link.PrevGLLineID = 0
      AND gl.SourceTransactionTypeKey = '4-CustCred'
),

CreditMemoHeader AS (
    SELECT
        gl.GLID,
        gl.GLDisplayName             AS CreditMemoDisplayName,
        gl.GLDate                    AS CreditMemoDate,
        gl.ReportingPeriod           AS CreditMemoReportingPeriod,
        gl.CVCustomerID,
        gl.SourceSubsidiaryKey,
        gl.SourceSalesRepID,
        gl.SourceSalesRep2ID,
        gl.SourceCurrencyID,
        gl.GLURL                     AS CreditMemoURL,
        ABS(gl.Amount)               AS CreditMemoTotalAmount
    FROM dbo.FactGL gl
    WHERE gl.GLLineID = '0'
      AND gl.SourceTransactionTypeKey = '4-CustCred'
      AND gl.SourceSubsidiaryKey IN (
              SELECT '4-' + CAST(SubsidiaryID AS VARCHAR)
              FROM [Netsuite].[dbo].silver_Subsidiary
              WHERE SubsidiaryName IN (
                    'Cardone Ventures, LLC',
                    '10X Roofing Management, LLC',
                    '10X Buy/Sell, LLC',
                    '10X HomeServe, LLC'
              )
          )
),

CreditMemoLines AS (
    SELECT
        gl.GLID,
        gl.GLLineID,
        gl.CVProductID,
        gl.SourceClassKey,
        gl.ClassID,
        ABS(gl.Amount)               AS CreditLineAmount
    FROM dbo.FactGL gl
    WHERE gl.GLLineID <> '0'
      AND gl.SourceTransactionTypeKey = '4-CustCred'
),

CreditMemoLineTotals AS (
    SELECT
        GLID,
        SUM(CreditLineAmount)        AS CreditTotalLineAmount
    FROM CreditMemoLines
    GROUP BY GLID
),

-- ============================================================================
-- SECTION 3 — INVOICE CTEs
-- ============================================================================

InvoiceHeader AS (
    SELECT
        gl.GLID,
        gl.GLDisplayName             AS InvoiceDisplayName,
        gl.GLDate                    AS InvoiceDate,
        gl.ReportingPeriod           AS InvoiceReportingPeriod,
        gl.GLStatus                  AS InvoiceStatus,
        gl.CVCustomerID,
        gl.SourceSubsidiaryKey       AS InvoiceSubsidiaryKey,
        gl.SourceCurrencyID          AS InvoiceCurrencyID,
        gl.SourceSalesRepID,
        gl.SourceSalesRep2ID,
        gl.IsClosed                  AS InvoiceIsClosed,
        gl.Elite,
        gl.GLURL                     AS InvoiceURL
    FROM dbo.FactGL gl
    WHERE gl.GLLineID = '0'
      AND gl.SourceTransactionTypeKey = '4-CustInvc'
      AND gl.SourceSubsidiaryKey IN (
              SELECT '4-' + CAST(SubsidiaryID AS VARCHAR)
              FROM [Netsuite].[dbo].silver_Subsidiary
              WHERE SubsidiaryName IN (
                    'Cardone Ventures, LLC',
                    '10X Roofing Management, LLC',
                    '10X Buy/Sell, LLC',
                    '10X HomeServe, LLC'
              )
          )
),

InvoiceLines AS (
-- AR amounts are stored negative — ABS() normalises to positive.
-- Filtered to 4-CustInvc only — excludes 18-Bill and other non-invoice lines.
    SELECT
        gl.GLID,
        gl.GLLineID,
        gl.CVProductID,
        gl.SourceClassKey,
        gl.ClassID,
        ABS(gl.Amount)               AS InvoiceLineAmount
    FROM dbo.FactGL gl
    WHERE gl.GLLineID <> '0'
      AND gl.SourceTransactionTypeKey = '4-CustInvc'
),

InvoiceLineTotals AS (
    SELECT
        GLID,
        SUM(InvoiceLineAmount)       AS InvoiceTotalLineAmount
    FROM InvoiceLines
    GROUP BY GLID
),

-- ============================================================================
-- SECTION 4 — SO LINKAGE CTEs
-- ============================================================================

SOInvoiceLineMap AS (
-- Direct OrdBill links: SO (Prev) → Invoice (Next), exact line-to-line mapping.
    SELECT
        link.PrevGLID                AS SOGLID,
        link.NextGLID                AS InvoiceGLID,
        link.PrevGLLineID            AS SOLineID,
        link.NextGLLineID            AS InvoiceLineID
    FROM dbo.FactGLLink link
    WHERE link.LinkType = 'OrdBill'
),

SubInvoicePath AS (
-- Subscription path: bridge via FactSubscription when no direct OrdBill link exists.
-- ROW_NUMBER DESC on CreateDate resolves overlapping subscription records.
    SELECT
        CAST(fs.SalesOrderID AS VARCHAR(50))  AS SOGLID,
        il.GLID                  AS InvoiceGLID,
        il.GLLineID              AS InvoiceLineID,
        il.CVProductID,
        ROW_NUMBER() OVER (
            PARTITION BY fs.SalesOrderID, il.GLID, il.GLLineID
            ORDER BY fs.CreateDate DESC
        )                        AS rn
    FROM dbo.FactSubscription fs
    JOIN InvoiceHeader ih
      ON ih.CVCustomerID  = fs.CVCustomerID
    JOIN InvoiceLines il
      ON il.GLID           = ih.GLID
     AND il.CVProductID    = fs.CVProductID
    WHERE ih.InvoiceDate BETWEEN fs.LineStartDate AND fs.LineEndDate
),

InvoiceSOMap AS (
-- Merge Direct + Subscription paths; prefer Direct; deduplicate per invoice line.
    SELECT
        InvoiceGLID,
        InvoiceLineID,
        SOGLID,
        SOLineID,
        LinkPath,
        ROW_NUMBER() OVER (
            PARTITION BY InvoiceGLID, InvoiceLineID
            ORDER BY CASE WHEN LinkPath = 'Direct' THEN 1 ELSE 2 END
        )                        AS rn
    FROM (
        SELECT
            d.InvoiceGLID,
            d.InvoiceLineID,
            d.SOGLID,
            d.SOLineID,
            'Direct'             AS LinkPath
        FROM SOInvoiceLineMap d

        UNION ALL

        SELECT
            s.InvoiceGLID,
            s.InvoiceLineID,
            s.SOGLID,
            NULL                 AS SOLineID,
            'Subscription'       AS LinkPath
        FROM SubInvoicePath s
        WHERE s.rn = 1
    ) combined
),

SOHeader AS (
    SELECT
        gl.GLID,
        gl.GLDisplayName             AS SODisplayName,
        gl.GLDate                    AS SODate,
        gl.ReportingPeriod           AS SOReportingPeriod,
        gl.GLStatus                  AS SOStatus,
        gl.GLURL                     AS SOURL
    FROM dbo.FactGL gl
    WHERE gl.GLLineID = '0'
      AND gl.SourceTransactionTypeKey = '4-SalesOrd'
),

SOLines AS (
    SELECT
        gl.GLID,
        gl.GLLineID,
        gl.CVProductID,
        ABS(gl.Amount)               AS SOLineContractValue
    FROM dbo.FactGL gl
    WHERE gl.GLLineID <> '0'
      AND gl.SourceTransactionTypeKey = '4-SalesOrd'
),

-- ============================================================================
-- SECTION 5 — CASH SALE CTEs
-- ============================================================================

CashSaleHeader AS (
-- Header row (GLLineID = '0'): positive Amount = total cash collected.
-- Product is not on the header — it lives on the line rows.
    SELECT
        gl.GLID                      AS CashGLID,
        gl.GLDisplayName             AS CashDisplayName,
        gl.GLDate                    AS CashDate,
        gl.ReportingPeriod           AS CashReportingPeriod,
        gl.SourceTransactionTypeKey  AS CashType,
        gl.PaymentMethod,
        gl.Amount                    AS TotalCashAmount,
        gl.CVCustomerID,
        gl.SourceSubsidiaryKey       AS CashSubsidiaryKey,
        gl.SourceCurrencyID,
        gl.SourceSalesRepID,
        gl.SourceSalesRep2ID,
        gl.GLURL                     AS CashURL
    FROM dbo.FactGL gl
    WHERE gl.SourceTransactionTypeKey = '4-CashSale'
      AND gl.GLLineID                 = '0'
      AND gl.GLDate                   >= '2023-01-01'
      AND gl.SourceSubsidiaryKey      IN (
              SELECT '4-' + CAST(SubsidiaryID AS VARCHAR)
              FROM [Netsuite].[dbo].silver_Subsidiary
              WHERE SubsidiaryName IN (
                    'Cardone Ventures, LLC',
                    '10X Roofing Management, LLC',
                    '10X Buy/Sell, LLC',
                    '10X HomeServe, LLC'
              )
          )
),

CashSaleLines AS (
-- Line rows (GLLineID <> '0'): negative Amount (revenue side) — ABS() normalises.
    SELECT
        gl.GLID                      AS CashGLID,
        gl.GLLineID,
        ABS(gl.Amount)               AS LineAmount,
        gl.CVProductID,
        gl.SourceClassKey,
        gl.ClassID
    FROM dbo.FactGL gl
    WHERE gl.SourceTransactionTypeKey = '4-CashSale'
      AND gl.GLLineID                 <> '0'
      AND gl.GLDate                   >= '2023-01-01'
      AND gl.SourceSubsidiaryKey      IN (
              SELECT '4-' + CAST(SubsidiaryID AS VARCHAR)
              FROM [Netsuite].[dbo].silver_Subsidiary
              WHERE SubsidiaryName IN (
                    'Cardone Ventures, LLC',
                    '10X Roofing Management, LLC',
                    '10X Buy/Sell, LLC',
                    '10X HomeServe, LLC'
              )
          )
),

CashSaleLineTotals AS (
-- Denominator for multi-line Cash Sale allocation ratio.
    SELECT
        CashGLID,
        SUM(LineAmount)              AS TotalLineAmount
    FROM CashSaleLines
    GROUP BY CashGLID
),

-- ============================================================================
-- SECTION 6 — CASH REFUND CTEs (4-CashRfnd: reversal of CashSale transactions)
-- ============================================================================

CashRfndSaleLink AS (
-- Header-level SaleRet/CostRtrn links: CashSale (Prev) → CashRfnd (Next).
-- AppliedAmount is NULL on SaleRet links — amounts come from the refund transaction.
    SELECT
        link.PrevGLID                AS CashSaleGLID,
        link.NextGLID                AS CashRfndGLID
    FROM dbo.FactGLLink link
    WHERE link.LinkType     IN ('SaleRet', 'CostRtrn')
      AND link.PrevGLLineID = 0
      AND link.NextGLLineID = 0
),

CashRfndHeader AS (
-- Header row (GLLineID = '0'): Amount is negative (cash going out).
    SELECT
        gl.GLID                      AS CashRfndGLID,
        gl.GLDisplayName             AS CashRfndDisplayName,
        gl.GLDate                    AS CashRfndDate,
        gl.ReportingPeriod           AS CashRfndReportingPeriod,
        gl.Amount                    AS TotalRefundAmount,   -- negative
        gl.CVCustomerID,
        gl.SourceSubsidiaryKey       AS CashRfndSubsidiaryKey,
        gl.SourceCurrencyID,
        gl.SourceSalesRepID,
        gl.SourceSalesRep2ID,
        gl.PaymentMethod,
        gl.GLURL                     AS CashRfndURL,
        COALESCE(gl.ExchangeRate, 1) AS ExchangeRate
    FROM dbo.FactGL gl
    WHERE gl.SourceTransactionTypeKey = '4-CashRfnd'
      AND gl.GLLineID                 = '0'
      AND gl.GLDate                   >= '2023-01-01'
      AND gl.SourceSubsidiaryKey      IN (
              SELECT '4-' + CAST(SubsidiaryID AS VARCHAR)
              FROM [Netsuite].[dbo].silver_Subsidiary
              WHERE SubsidiaryName IN (
                    'Cardone Ventures, LLC',
                    '10X Roofing Management, LLC',
                    '10X Buy/Sell, LLC',
                    '10X HomeServe, LLC'
              )
          )
),

CashRfndLines AS (
-- Line rows (GLLineID <> '0'): Amount is positive (debit to revenue — reversal of sale).
    SELECT
        gl.GLID                      AS CashRfndGLID,
        gl.GLLineID,
        gl.Amount                    AS LineAmount,          -- positive
        gl.CVProductID,
        gl.SourceClassKey,
        gl.ClassID
    FROM dbo.FactGL gl
    WHERE gl.SourceTransactionTypeKey = '4-CashRfnd'
      AND gl.GLLineID                 <> '0'
      AND gl.GLDate                   >= '2023-01-01'
      AND gl.SourceSubsidiaryKey      IN (
              SELECT '4-' + CAST(SubsidiaryID AS VARCHAR)
              FROM [Netsuite].[dbo].silver_Subsidiary
              WHERE SubsidiaryName IN (
                    'Cardone Ventures, LLC',
                    '10X Roofing Management, LLC',
                    '10X Buy/Sell, LLC',
                    '10X HomeServe, LLC'
              )
          )
),

CashRfndLineTotals AS (
    SELECT
        CashRfndGLID,
        SUM(LineAmount)              AS TotalLineAmount
    FROM CashRfndLines
    GROUP BY CashRfndGLID
),

-- ============================================================================
-- SECTION 7 — JOURNAL ENTRY CASH CTEs
-- ============================================================================

JECashApplications AS (
-- Invoice → JE Payment links where the JE also has an outgoing link to a real
-- cash transaction (CustPymt, DepAppl, Deposit, CustRfnd).
-- EXISTS filter excludes write-off JEs, which have no outgoing cash link.
-- AppliedAmount is taken from the Invoice→JE link (how much was applied to the invoice).
    SELECT
        inv_je.PrevGLID                                          AS InvoiceGLID,
        inv_je.NextGLID                                          AS JournalGLID,
        inv_je.AppliedAmount * COALESCE(je_gl.ExchangeRate, 1)  AS AppliedAmount,   -- USD
        je_gl.GLDisplayName                                      AS JEDisplayName,
        je_gl.GLDate                                             AS JEDate,
        je_gl.ReportingPeriod                                    AS JEReportingPeriod,
        je_gl.CVCustomerID,
        je_gl.SourceSubsidiaryKey,
        je_gl.SourceCurrencyID,
        je_gl.SourceSalesRepID,
        je_gl.SourceSalesRep2ID,
        je_gl.GLURL                                              AS JEURL
    FROM dbo.FactGLLink inv_je
    JOIN dbo.FactGL je_gl
      ON je_gl.GLID     = inv_je.NextGLID
     AND je_gl.GLLineID = '0'
     AND je_gl.SourceTransactionTypeKey = '4-Journal'
    WHERE inv_je.LinkType     = 'Payment'
      AND inv_je.PrevGLLineID = 0
      AND EXISTS (
          SELECT 1
          FROM dbo.FactGLLink je_out
          JOIN dbo.FactGL cash_gl
            ON cash_gl.GLID     = je_out.NextGLID
           AND cash_gl.GLLineID  = '0'
           AND cash_gl.SourceTransactionTypeKey IN (
                 '4-CustPymt', '4-DepAppl', '4-Deposit', '4-CustRfnd'
               )
          WHERE je_out.PrevGLID     = inv_je.NextGLID
            AND je_out.PrevGLLineID = 0
            AND je_out.LinkType     = 'Payment'
      )
)

-- ============================================================================
-- STREAM 1 — Regular Cash (CustPymt, DepAppl, Deposit, CustRfnd)
--   Grain  : 1 row per cash transaction × invoice line
--   Formula: CashAllocatedToLine = AppliedAmount × (LineAmt / TotalLineAmt)
-- ============================================================================
SELECT
    -- ── Cash ──────────────────────────────────────────────────────────────
    ca.CashGLID,
    cd.CashDisplayName,
    cd.CashDate,
    cd.CashReportingPeriod,
    cd.CashType,
    cd.PaymentMethod,
    -- ── Amounts (AppliedAmount × ExchangeRate = USD) ─────────────────────
    CAST(ca.AppliedAmount * cd.ExchangeRate AS DECIMAL(18,4))  AS AppliedAmount,
    CAST(
        (ca.AppliedAmount * cd.ExchangeRate)
        * (il.InvoiceLineAmount / NULLIF(ilt.InvoiceTotalLineAmount, 0))
        AS DECIMAL(18,4)
    )                                AS CashAllocatedToLine,
    CAST(NULL AS DECIMAL(18,4))      AS CreditMemoTotalAmount,
    CAST(NULL AS DECIMAL(18,4))      AS CreditMemoAppliedToInvoice,
    -- ── Invoice ───────────────────────────────────────────────────────────
    ih.GLID                          AS InvoiceGLID,
    ih.InvoiceDisplayName,
    ih.InvoiceDate,
    ih.InvoiceReportingPeriod,
    ih.InvoiceStatus,
    ih.InvoiceIsClosed,
    ih.Elite,
    ih.InvoiceURL,
    il.GLLineID                      AS InvoiceLineID,
    il.InvoiceLineAmount,
    ilt.InvoiceTotalLineAmount,
    il.SourceClassKey,
    il.ClassID,
    -- ── Sales Order ───────────────────────────────────────────────────────
    soh.GLID                         AS SOGLID,
    soh.SODisplayName,
    soh.SODate,
    soh.SOReportingPeriod,
    soh.SOStatus,
    soh.SOURL,
    sol.SOLineContractValue,
    ism.LinkPath                     AS SOLinkPath,
    -- ── Product ───────────────────────────────────────────────────────────
    prod.CVProductID,
    prod.ProductName,
    prod.ProductCode,
    prod.ProductCategoryName         AS ProductCategory,
    prod.ProductSubCategoryName,
    prod.DepartmentName,
    prod.ProductClassName,
    prod.ProductTypeName,
    -- ── Customer ──────────────────────────────────────────────────────────
    cust.CVCustomerID,
    cust.CustomerName,
    cust.NetSuiteID,
    -- ── Subsidiary / Currency / Reps ──────────────────────────────────────
    sub.SubsidiaryName,
    ih.InvoiceSubsidiaryKey,
    cd.SourceCurrencyID,
    cd.SourceSalesRepID,
    cd.SourceSalesRep2ID,
    cd.CashURL
FROM CashApplications  ca
JOIN CashDetail         cd   ON cd.GLID              = ca.CashGLID
JOIN InvoiceHeader      ih   ON ih.GLID              = ca.InvoiceGLID
JOIN InvoiceLines       il   ON il.GLID              = ih.GLID
JOIN InvoiceLineTotals  ilt  ON ilt.GLID             = il.GLID
LEFT JOIN dbo.DimProduct  prod ON prod.CVProductID    = il.CVProductID
LEFT JOIN dbo.DimCustomer cust ON cust.CVCustomerID  = ih.CVCustomerID
LEFT JOIN [Netsuite].[dbo].silver_Subsidiary sub ON '4-' + CAST(sub.SubsidiaryID AS VARCHAR) = ih.InvoiceSubsidiaryKey
LEFT JOIN InvoiceSOMap  ism  ON ism.InvoiceGLID      = il.GLID
                             AND ism.InvoiceLineID    = il.GLLineID
                             AND ism.rn               = 1
LEFT JOIN SOHeader      soh  ON soh.GLID             = ism.SOGLID
LEFT JOIN SOLines       sol  ON sol.GLID             = ism.SOGLID
                             AND sol.GLLineID          = ism.SOLineID
WHERE cd.CashType IN ('4-CustPymt', '4-DepAppl', '4-Deposit', '4-CustRfnd')
  AND cd.CashDate >= '2023-01-01'

UNION ALL

-- ============================================================================
-- STREAM 2 — Credit Memos (AR write-offs)
--   Grain  : 1 row per credit memo line × invoice
--   CashAllocatedToLine = 0 (diagnostic confirmed CMs reduce AR, not cash)
--   AppliedAmount and CreditMemoAppliedToInvoice populated for reference.
--   Date   : Credit issuance date used (not original payment date).
-- ============================================================================
SELECT
    -- ── Cash (credit memo) ────────────────────────────────────────────────
    ca.CreditGLID                    AS CashGLID,
    cmh.CreditMemoDisplayName        AS CashDisplayName,
    ca.CreditDate                    AS CashDate,
    cmh.CreditMemoReportingPeriod    AS CashReportingPeriod,
    '4-CustCred'                     AS CashType,
    CAST(NULL AS NVARCHAR(50))       AS PaymentMethod,
    -- ── Amounts ───────────────────────────────────────────────────────────
    CAST(ca.CreditAppliedAmount      AS DECIMAL(18,4)) AS AppliedAmount,
    CAST(0                           AS DECIMAL(18,4)) AS CashAllocatedToLine,
    CAST(cmh.CreditMemoTotalAmount   AS DECIMAL(18,4)) AS CreditMemoTotalAmount,
    CAST(ca.CreditAppliedAmount      AS DECIMAL(18,4)) AS CreditMemoAppliedToInvoice,
    -- ── Invoice ───────────────────────────────────────────────────────────
    ih.GLID                          AS InvoiceGLID,
    ih.InvoiceDisplayName,
    ih.InvoiceDate,
    ih.InvoiceReportingPeriod,
    ih.InvoiceStatus,
    ih.InvoiceIsClosed,
    ih.Elite,
    ih.InvoiceURL,
    cml.GLLineID                     AS InvoiceLineID,
    cml.CreditLineAmount             AS InvoiceLineAmount,
    cmlt.CreditTotalLineAmount       AS InvoiceTotalLineAmount,
    cml.SourceClassKey,
    cml.ClassID,
    -- ── Sales Order (via credit product → matching invoice line) ──────────
    soh.GLID                         AS SOGLID,
    soh.SODisplayName,
    soh.SODate,
    soh.SOReportingPeriod,
    soh.SOStatus,
    soh.SOURL,
    sol.SOLineContractValue,
    ism.LinkPath                     AS SOLinkPath,
    -- ── Product ───────────────────────────────────────────────────────────
    prod.CVProductID,
    prod.ProductName,
    prod.ProductCode,
    prod.ProductCategoryName         AS ProductCategory,
    prod.ProductSubCategoryName,
    prod.DepartmentName,
    prod.ProductClassName,
    prod.ProductTypeName,
    -- ── Customer ──────────────────────────────────────────────────────────
    cust.CVCustomerID,
    cust.CustomerName,
    cust.NetSuiteID,
    -- ── Subsidiary / Currency / Reps ──────────────────────────────────────
    sub.SubsidiaryName,
    ih.InvoiceSubsidiaryKey,
    cmh.SourceCurrencyID,
    cmh.SourceSalesRepID,
    cmh.SourceSalesRep2ID,
    cmh.CreditMemoURL                AS CashURL
FROM CreditApps          ca
JOIN CreditMemoHeader    cmh  ON cmh.GLID             = ca.CreditGLID
JOIN CreditMemoLines     cml  ON cml.GLID             = ca.CreditGLID
JOIN CreditMemoLineTotals cmlt ON cmlt.GLID           = ca.CreditGLID
JOIN InvoiceHeader       ih   ON ih.GLID              = ca.InvoiceGLID
LEFT JOIN dbo.DimProduct  prod ON prod.CVProductID    = cml.CVProductID
LEFT JOIN dbo.DimCustomer cust ON cust.CVCustomerID   = ih.CVCustomerID
LEFT JOIN [Netsuite].[dbo].silver_Subsidiary sub ON '4-' + CAST(sub.SubsidiaryID AS VARCHAR) = ih.InvoiceSubsidiaryKey
LEFT JOIN InvoiceLines   il_so ON il_so.GLID          = ih.GLID
                               AND il_so.CVProductID   = cml.CVProductID
LEFT JOIN InvoiceSOMap   ism   ON ism.InvoiceGLID     = ih.GLID
                               AND ism.InvoiceLineID   = il_so.GLLineID
                               AND ism.rn              = 1
LEFT JOIN SOHeader       soh  ON soh.GLID             = ism.SOGLID
LEFT JOIN SOLines        sol  ON sol.GLID             = ism.SOGLID
                              AND sol.GLLineID          = ism.SOLineID
WHERE ca.CreditDate >= '2023-01-01'

UNION ALL

-- ============================================================================
-- STREAM 3 — Cash Sales (4-CashSale: self-contained SO/Invoice/Payment)
--   Grain  : 1 row per Cash Sale × line item
--   Formula: CashAllocatedToLine = TotalCashAmount × (LineAmt / TotalLineAmt)
--   Note   : No Invoice or SO columns — CashSale is its own atomic transaction.
--            SubsidiaryName is NULL (SubsidiaryID not populated in FactGL for CashSale).
-- ============================================================================
SELECT
    -- ── Cash ──────────────────────────────────────────────────────────────
    csh.CashGLID,
    csh.CashDisplayName,
    csh.CashDate,
    csh.CashReportingPeriod,
    csh.CashType,
    csh.PaymentMethod,
    -- ── Amounts ───────────────────────────────────────────────────────────
    csh.TotalCashAmount              AS AppliedAmount,
    CAST(
        csh.TotalCashAmount
        * (csl.LineAmount / NULLIF(cslt.TotalLineAmount, 0))
        AS DECIMAL(18,4)
    )                                AS CashAllocatedToLine,
    CAST(NULL AS DECIMAL(18,4))      AS CreditMemoTotalAmount,
    CAST(NULL AS DECIMAL(18,4))      AS CreditMemoAppliedToInvoice,
    -- ── Invoice (CashSale — GLID and DisplayName carried from cash record) ──
    csh.CashGLID                     AS InvoiceGLID,
    csh.CashDisplayName              AS InvoiceDisplayName,
    CAST(NULL AS DATE)               AS InvoiceDate,
    CAST(NULL AS NVARCHAR(50))       AS InvoiceReportingPeriod,
    CAST(NULL AS NVARCHAR(50))       AS InvoiceStatus,
    CAST(NULL AS BIT)                AS InvoiceIsClosed,
    CAST(NULL AS NVARCHAR(50))       AS Elite,
    csh.CashURL                      AS InvoiceURL,
    csl.GLLineID                     AS InvoiceLineID,
    csl.LineAmount                   AS InvoiceLineAmount,
    cslt.TotalLineAmount             AS InvoiceTotalLineAmount,
    csl.SourceClassKey,
    csl.ClassID,
    -- ── Sales Order (CashSale — DisplayName carried from cash record) ──────
    csh.CashGLID                     AS SOGLID,
    csh.CashDisplayName              AS SODisplayName,
    CAST(NULL AS DATE)               AS SODate,
    CAST(NULL AS NVARCHAR(50))       AS SOReportingPeriod,
    CAST(NULL AS NVARCHAR(50))       AS SOStatus,
    CAST(NULL AS NVARCHAR(500))      AS SOURL,
    CAST(NULL AS DECIMAL(18,4))      AS SOLineContractValue,
    'CashSale'                       AS SOLinkPath,
    -- ── Product ───────────────────────────────────────────────────────────
    prod.CVProductID,
    prod.ProductName,
    prod.ProductCode,
    prod.ProductCategoryName         AS ProductCategory,
    prod.ProductSubCategoryName,
    prod.DepartmentName,
    prod.ProductClassName,
    prod.ProductTypeName,
    -- ── Customer ──────────────────────────────────────────────────────────
    cust.CVCustomerID,
    cust.CustomerName,
    cust.NetSuiteID,
    -- ── Subsidiary / Currency / Reps ──────────────────────────────────────
    sub.SubsidiaryName,
    csh.CashSubsidiaryKey            AS InvoiceSubsidiaryKey,
    csh.SourceCurrencyID,
    csh.SourceSalesRepID,
    csh.SourceSalesRep2ID,
    csh.CashURL
FROM CashSaleHeader      csh
JOIN CashSaleLines       csl   ON csl.CashGLID      = csh.CashGLID
JOIN CashSaleLineTotals  cslt  ON cslt.CashGLID     = csh.CashGLID
LEFT JOIN dbo.DimProduct  prod ON prod.CVProductID  = csl.CVProductID
LEFT JOIN dbo.DimCustomer cust ON cust.CVCustomerID = csh.CVCustomerID
LEFT JOIN [Netsuite].[dbo].silver_Subsidiary sub ON '4-' + CAST(sub.SubsidiaryID AS VARCHAR) = csh.CashSubsidiaryKey

UNION ALL

-- ============================================================================
-- STREAM 4 — Cash Sale Refunds (4-CashRfnd → 4-CashSale via SaleRet/CostRtrn)
--   Grain  : 1 row per refund transaction × refund line
--   Formula: CashAllocatedToLine = TotalRefundAmount × (LineAmt / TotalLineAmt)
--            TotalRefundAmount is negative → CashAllocatedToLine is negative.
--   Note   : InvoiceGLID and SOGLID both carry the originating CashSale GLID.
--            4-RtnAuth → 4-CashRfnd path (169 rows) not included — pending investigation.
-- ============================================================================
SELECT
    -- ── Cash ──────────────────────────────────────────────────────────────
    crh.CashRfndGLID                 AS CashGLID,
    crh.CashRfndDisplayName          AS CashDisplayName,
    crh.CashRfndDate                 AS CashDate,
    crh.CashRfndReportingPeriod      AS CashReportingPeriod,
    '4-CashRfnd'                     AS CashType,
    crh.PaymentMethod,
    -- ── Amounts (TotalRefundAmount is negative; CashAllocatedToLine inherits sign) ─
    CAST(ABS(crh.TotalRefundAmount)  AS DECIMAL(18,4)) AS AppliedAmount,
    CAST(
        crh.TotalRefundAmount
        * (crl.LineAmount / NULLIF(crlt.TotalLineAmount, 0))
        AS DECIMAL(18,4)
    )                                AS CashAllocatedToLine,
    CAST(NULL AS DECIMAL(18,4))      AS CreditMemoTotalAmount,
    CAST(NULL AS DECIMAL(18,4))      AS CreditMemoAppliedToInvoice,
    -- ── Invoice (original CashSale carried as InvoiceGLID) ────────────────
    crsl.CashSaleGLID                AS InvoiceGLID,
    cs_orig.GLDisplayName            AS InvoiceDisplayName,
    CAST(NULL AS DATE)               AS InvoiceDate,
    CAST(NULL AS NVARCHAR(50))       AS InvoiceReportingPeriod,
    CAST(NULL AS NVARCHAR(50))       AS InvoiceStatus,
    CAST(NULL AS BIT)                AS InvoiceIsClosed,
    CAST(NULL AS NVARCHAR(50))       AS Elite,
    cs_orig.GLURL                    AS InvoiceURL,
    crl.GLLineID                     AS InvoiceLineID,
    crl.LineAmount                   AS InvoiceLineAmount,
    crlt.TotalLineAmount             AS InvoiceTotalLineAmount,
    crl.SourceClassKey,
    crl.ClassID,
    -- ── Sales Order (same CashSale GLID) ─────────────────────────────────
    crsl.CashSaleGLID                AS SOGLID,
    cs_orig.GLDisplayName            AS SODisplayName,
    CAST(NULL AS DATE)               AS SODate,
    CAST(NULL AS NVARCHAR(50))       AS SOReportingPeriod,
    CAST(NULL AS NVARCHAR(50))       AS SOStatus,
    CAST(NULL AS NVARCHAR(500))      AS SOURL,
    CAST(NULL AS DECIMAL(18,4))      AS SOLineContractValue,
    'CashSaleRefund'                 AS SOLinkPath,
    -- ── Product ───────────────────────────────────────────────────────────
    prod.CVProductID,
    prod.ProductName,
    prod.ProductCode,
    prod.ProductCategoryName         AS ProductCategory,
    prod.ProductSubCategoryName,
    prod.DepartmentName,
    prod.ProductClassName,
    prod.ProductTypeName,
    -- ── Customer ──────────────────────────────────────────────────────────
    cust.CVCustomerID,
    cust.CustomerName,
    cust.NetSuiteID,
    -- ── Subsidiary / Currency / Reps ──────────────────────────────────────
    sub.SubsidiaryName,
    crh.CashRfndSubsidiaryKey        AS InvoiceSubsidiaryKey,
    crh.SourceCurrencyID,
    crh.SourceSalesRepID,
    crh.SourceSalesRep2ID,
    crh.CashRfndURL                  AS CashURL
FROM CashRfndHeader      crh
JOIN CashRfndSaleLink    crsl  ON crsl.CashRfndGLID  = crh.CashRfndGLID
JOIN CashRfndLines       crl   ON crl.CashRfndGLID   = crh.CashRfndGLID
JOIN CashRfndLineTotals  crlt  ON crlt.CashRfndGLID  = crh.CashRfndGLID
JOIN dbo.FactGL          cs_orig ON cs_orig.GLID      = crsl.CashSaleGLID
                                AND cs_orig.GLLineID   = '0'
LEFT JOIN dbo.DimProduct  prod ON prod.CVProductID    = crl.CVProductID
LEFT JOIN dbo.DimCustomer cust ON cust.CVCustomerID   = crh.CVCustomerID
LEFT JOIN [Netsuite].[dbo].silver_Subsidiary sub ON '4-' + CAST(sub.SubsidiaryID AS VARCHAR) = crh.CashRfndSubsidiaryKey

UNION ALL

-- ============================================================================
-- STREAM 5 — Journal Entry Cash Bridges (Invoice → JE → Cash)
--   Grain  : 1 row per JE × invoice line
--   Formula: CashAllocatedToLine = AppliedAmount × (LineAmt / TotalLineAmt)
--   Scope  : JEs that bridge cross-entity deposits or payments to invoices.
--            Write-off JEs excluded via EXISTS (no outgoing cash link).
--   Note   : CashGLID = JournalGLID. Subsidiary filter applied via InvoiceHeader.
-- ============================================================================
SELECT
    -- ── Cash ──────────────────────────────────────────────────────────────
    jca.JournalGLID                  AS CashGLID,
    jca.JEDisplayName                AS CashDisplayName,
    jca.JEDate                       AS CashDate,
    jca.JEReportingPeriod            AS CashReportingPeriod,
    '4-Journal'                      AS CashType,
    CAST(NULL AS NVARCHAR(50))       AS PaymentMethod,
    -- ── Amounts ───────────────────────────────────────────────────────────
    CAST(jca.AppliedAmount           AS DECIMAL(18,4)) AS AppliedAmount,
    CAST(
        jca.AppliedAmount
        * (il.InvoiceLineAmount / NULLIF(ilt.InvoiceTotalLineAmount, 0))
        AS DECIMAL(18,4)
    )                                AS CashAllocatedToLine,
    CAST(NULL AS DECIMAL(18,4))      AS CreditMemoTotalAmount,
    CAST(NULL AS DECIMAL(18,4))      AS CreditMemoAppliedToInvoice,
    -- ── Invoice ───────────────────────────────────────────────────────────
    ih.GLID                          AS InvoiceGLID,
    ih.InvoiceDisplayName,
    ih.InvoiceDate,
    ih.InvoiceReportingPeriod,
    ih.InvoiceStatus,
    ih.InvoiceIsClosed,
    ih.Elite,
    ih.InvoiceURL,
    il.GLLineID                      AS InvoiceLineID,
    il.InvoiceLineAmount,
    ilt.InvoiceTotalLineAmount,
    il.SourceClassKey,
    il.ClassID,
    -- ── Sales Order ───────────────────────────────────────────────────────
    soh.GLID                         AS SOGLID,
    soh.SODisplayName,
    soh.SODate,
    soh.SOReportingPeriod,
    soh.SOStatus,
    soh.SOURL,
    sol.SOLineContractValue,
    ism.LinkPath                     AS SOLinkPath,
    -- ── Product ───────────────────────────────────────────────────────────
    prod.CVProductID,
    prod.ProductName,
    prod.ProductCode,
    prod.ProductCategoryName         AS ProductCategory,
    prod.ProductSubCategoryName,
    prod.DepartmentName,
    prod.ProductClassName,
    prod.ProductTypeName,
    -- ── Customer ──────────────────────────────────────────────────────────
    cust.CVCustomerID,
    cust.CustomerName,
    cust.NetSuiteID,
    -- ── Subsidiary / Currency / Reps ──────────────────────────────────────
    sub.SubsidiaryName,
    ih.InvoiceSubsidiaryKey,
    jca.SourceCurrencyID,
    jca.SourceSalesRepID,
    jca.SourceSalesRep2ID,
    jca.JEURL                        AS CashURL
FROM JECashApplications  jca
JOIN InvoiceHeader       ih   ON ih.GLID              = jca.InvoiceGLID
JOIN InvoiceLines        il   ON il.GLID              = ih.GLID
JOIN InvoiceLineTotals   ilt  ON ilt.GLID             = il.GLID
LEFT JOIN dbo.DimProduct  prod ON prod.CVProductID    = il.CVProductID
LEFT JOIN dbo.DimCustomer cust ON cust.CVCustomerID   = ih.CVCustomerID
LEFT JOIN [Netsuite].[dbo].silver_Subsidiary sub ON '4-' + CAST(sub.SubsidiaryID AS VARCHAR) = ih.InvoiceSubsidiaryKey
LEFT JOIN InvoiceSOMap   ism  ON ism.InvoiceGLID      = il.GLID
                              AND ism.InvoiceLineID    = il.GLLineID
                              AND ism.rn               = 1
LEFT JOIN SOHeader       soh  ON soh.GLID             = ism.SOGLID
LEFT JOIN SOLines        sol  ON sol.GLID             = ism.SOGLID
                              AND sol.GLLineID          = ism.SOLineID
WHERE jca.JEDate >= '2023-01-01';
