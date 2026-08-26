CREATE    VIEW dbo.vwCashDefinition AS

WITH SalesOrderLinks AS (
    SELECT DISTINCT
        link.NextGLID   AS InvoiceGLID,
        link.PrevGLID   AS SalesOrderGLID
    FROM dbo.FactGLLink link
    WHERE link.LinkType = 'OrdBill'
),

SalesOrderHeader AS (
    SELECT
        gl.GLID          AS SalesOrderGLID,
        gl.GLDisplayName AS SalesOrderName,
        gl.GLDate        AS SalesOrderDate,
        gl.GLStatus      AS SalesOrderStatus,
        ROW_NUMBER() OVER (
            PARTITION BY gl.GLID
            ORDER BY gl.GLStatus
        ) AS rn
    FROM dbo.FactGL gl
    WHERE gl.SourceTransactionTypeID = 'SalesOrd'
    GROUP BY gl.GLID, gl.GLDisplayName, gl.GLDate, gl.GLStatus
),

PaymentLinks AS (
    SELECT DISTINCT
        link.PrevGLID AS InvoiceGLID,
        link.NextGLID AS PaymentGLID
    FROM dbo.FactGLLink link
    WHERE link.LinkType = 'Payment'
),

PaymentTxn AS (
    SELECT DISTINCT
        gl.GLID,
        gl.GLDate        AS PaymentDate,
        gl.PaymentMethod
    FROM dbo.FactGL gl
    WHERE gl.SourceTransactionTypeID = 'CustPymt'
),

PaymentSummary AS (
    SELECT
        pl.InvoiceGLID,
        COUNT(DISTINCT pl.PaymentGLID)  AS PaymentCount,
        MIN(pt.PaymentDate)             AS FirstPaymentDate,
        MAX(pt.PaymentDate)             AS LastPaymentDate
    FROM PaymentLinks pl
    JOIN PaymentTxn pt ON pl.PaymentGLID = pt.GLID
    GROUP BY pl.InvoiceGLID
),

LatestPaymentMethod AS (
    SELECT
        pl.InvoiceGLID,
        pt.PaymentMethod,
        ROW_NUMBER() OVER (
            PARTITION BY pl.InvoiceGLID
            ORDER BY pt.PaymentDate DESC, pt.GLID DESC
        ) AS rn
    FROM PaymentLinks pl
    JOIN PaymentTxn pt ON pl.PaymentGLID = pt.GLID
    WHERE pt.PaymentMethod IS NOT NULL
),

-- Payment method on the EARLIEST payment (mirror of LatestPaymentMethod, ASC)
FirstPaymentMethod AS (
    SELECT
        pl.InvoiceGLID,
        pt.PaymentMethod,
        ROW_NUMBER() OVER (
            PARTITION BY pl.InvoiceGLID
            ORDER BY pt.PaymentDate ASC, pt.GLID ASC
        ) AS rn
    FROM PaymentLinks pl
    JOIN PaymentTxn pt ON pl.PaymentGLID = pt.GLID
    WHERE pt.PaymentMethod IS NOT NULL
),

DepositAppTxn AS (
    SELECT DISTINCT
        gl.GLID,
        gl.GLDisplayName AS DepositAppName,
        gl.GLDate        AS DepositAppDate
    FROM dbo.FactGL gl
    WHERE gl.SourceTransactionTypeID = 'DepAppl'
),

InvoiceDepositAppLinks AS (
    SELECT DISTINCT
        pl.PrevGLID AS InvoiceGLID,
        pl.NextGLID AS DepositAppGLID
    FROM dbo.FactGLLink pl
    WHERE pl.LinkType = 'Payment'
        AND EXISTS (
            SELECT 1 FROM DepositAppTxn da WHERE da.GLID = pl.NextGLID
        )
),

CustomerDepositLinks AS (
    SELECT DISTINCT
        link.PrevGLID AS CustomerDepositGLID,
        link.NextGLID AS DepositAppGLID
    FROM dbo.FactGLLink link
    WHERE link.LinkType = 'DepAppl'
),

DepositSummary AS (
    SELECT
        idl.InvoiceGLID,
        COUNT(DISTINCT idl.DepositAppGLID)      AS DepositApplicationCount,
        COUNT(DISTINCT cdl.CustomerDepositGLID)  AS CustomerDepositCount,
        MIN(da.DepositAppDate)                   AS FirstDepositAppDate,
        MAX(da.DepositAppDate)                   AS LastDepositAppDate
    FROM InvoiceDepositAppLinks idl
    JOIN DepositAppTxn da ON idl.DepositAppGLID = da.GLID
    LEFT JOIN CustomerDepositLinks cdl ON idl.DepositAppGLID = cdl.DepositAppGLID
    GROUP BY idl.InvoiceGLID
),

-- Product count per transaction (from sibling lines)
TxnProductCounts AS (
    SELECT GLID, COUNT(DISTINCT CVProductID) AS ProductCount
    FROM dbo.FactGL
    WHERE SourceTransactionTypeID IN ('CustInvc', 'CustCred') AND CVProductID IS NOT NULL
    GROUP BY GLID
),

-- Primary product from sibling lines (highest absolute amount wins)
TxnProducts AS (
    SELECT
        item.GLID       AS TxnGLID,
        item.CVProductID,
        ROW_NUMBER() OVER (
            PARTITION BY item.GLID
            ORDER BY ABS(item.Amount) DESC, item.CVProductID
        ) AS rn
    FROM dbo.FactGL item
    WHERE item.SourceTransactionTypeID IN ('CustInvc', 'CustCred')
        AND item.CVProductID IS NOT NULL
),

-- IsNewSubscription from sibling invoice lines
InvoiceSubscription AS (
    SELECT
        GLID AS InvoiceGLID,
        MAX(CAST(IsNewSubscription AS INT)) AS IsNewSubscription
    FROM dbo.FactGL
    WHERE SourceTransactionTypeID = 'CustInvc'
        AND IsNewSubscription IS NOT NULL
    GROUP BY GLID
)

-- =====================================================================
-- INVOICES (CustInvc) — full enrichment
-- =====================================================================
SELECT
    'Invoice'                           AS TransactionType,

    -- === Sales Order ===
    soh.SalesOrderGLID                  AS SalesOrderID,
    soh.SalesOrderName,
    soh.SalesOrderDate,
    soh.SalesOrderStatus,

    -- === Transaction ===
    inv.GLID                            AS TransactionID,
    inv.GLDisplayName                   AS TransactionName,
    inv.GLDate                          AS TransactionDate,
    inv.ReportingPeriod                 AS PostingPeriod,
    inv.GLStatus                        AS TransactionStatus,
    inv.GLURL                           AS TransactionURL,

    -- === Customer ===
    inv.CVCustomerID,
    cust.CustomerName,
    cust.NetSuiteID                     AS CustomerNetSuiteID,

    -- === Subsidiary / Currency ===
    inv.SourceSubsidiaryID              AS SubsidiaryID,
    sub.SourceSubsidiaryName            AS SubsidiaryName,
    inv.SourceCurrencyID                AS Currency,

    -- === Product / Classification ===
    tp.CVProductID,
    prod.ProductName,
    prod.ProductCode,
    prod.DepartmentName,
    COALESCE(tpc.ProductCount, 0)       AS ProductCount,
    cls.SourceClassName                 AS ClassName,
    CASE
        WHEN cls.SourceClassName IN ('SBU Services', 'SBU Partnerships Management Fees') THEN 'SBU'
        WHEN cls.SourceClassName = 'Platform Review' THEN 'Platform Review'
        WHEN cls.SourceClassName IN ('10X Business Academy', '10X BA Coaching', '10X Business Advisor', '10X BA Online Program', '10X BA Lab') THEN 'Business Academy'
        WHEN cls.SourceClassName IN ('10X360', 'Elite Edge', 'Essentials', 'BEW', 'PEW', 'Cardone U', 'BMLP', 'BMLP Retreat', 'Elevate', 'GrowthCon', 'CTTI Essentials', 'CTTI Events', 'Mastery Events', 'Vertical Events', 'CV Events', 'REW', 'OEW', 'SEW', 'LEW', 'FEW', 'MEW', '10X Business Summit (CV)', 'Business Summit', 'Business Bootcamp', 'Real Estate Summit', 'Masterminds') THEN 'Events & Programs'
        WHEN cls.SourceClassName IN ('FAAS', 'Bookkeeping', 'Financial Services', 'Business Services') THEN 'CVAS'
        WHEN cls.SourceClassName IN ('10X Recruiting', '10X Human Resources', 'R3 Hiring Tool') THEN 'Recruiting'
        WHEN cls.SourceClassName IN ('Marketing Shared Services', 'Scale CRM') THEN 'Marketing'
        WHEN cls.SourceClassName IN ('10X Buy Sell', 'DE - Sell Side', 'DE-Buy Side', 'Private Coaching', 'PC - Elite250', 'ELITE 125', 'ELITE 250', 'PC SALES', 'PC - Brandon Dawson') THEN 'M&A / Elite / Coaching'
        WHEN cls.SourceClassName = 'Online Programs' THEN 'Online Programs'
        WHEN cls.SourceClassName IN ('Other Revenue', 'People', 'Revenue', 'Operations', 'Book Sales', 'Revified') THEN 'Other'
        ELSE 'Unclassified'
    END                                 AS ProductCategory,

    -- === Sales Rep ===
    inv.SourceSalesRepID                AS SalesRepID,
    inv.SourceSalesRep2ID               AS SalesRep2ID,

    -- === Amounts ===
    inv.Amount                          AS Amount,
    inv.AmountLocal,

    -- === Payment / Collection ===
    inv.AmountPaid,
    inv.AmountPaidLocal,
    inv.Amount - inv.AmountPaid         AS AmountUnpaid,
    CASE
        WHEN inv.AmountPaid >= inv.Amount THEN 'Fully Paid'
        WHEN inv.AmountPaid > 0          THEN 'Partially Paid'
        ELSE 'Unpaid'
    END                                 AS CollectionStatus,
    COALESCE(pmt.PaymentCount, 0)       AS PaymentCount,
    pmt.FirstPaymentDate,
    pmt.LastPaymentDate,
    lpm.PaymentMethod                   AS LastPaymentMethod,
    fpm.PaymentMethod                   AS FirstPaymentMethod,
    CASE
        WHEN pmt.FirstPaymentDate IS NOT NULL
        THEN DATEDIFF(day, inv.GLDate, pmt.FirstPaymentDate)
    END                                 AS DaysToFirstPayment,

    -- === Deposit / Application ===
    COALESCE(dep.DepositApplicationCount, 0) AS DepositApplicationCount,
    COALESCE(dep.CustomerDepositCount, 0)    AS CustomerDepositCount,
    dep.FirstDepositAppDate,
    dep.LastDepositAppDate,
    CAST(CASE WHEN dep.DepositApplicationCount > 0 THEN 1 ELSE 0 END AS BIT) AS HasDepositApplied,

    -- === Subscription ===
    CAST(COALESCE(isub.IsNewSubscription, 0) AS BIT) AS IsNewSubscription,
    prod.IsSubscriptionName             AS IsSubscriptionProduct,
    inv.Elite                           AS EliteTier,

    -- === Aging ===
    DATEDIFF(day, inv.GLDate, GETDATE()) AS DaysSinceTransaction,
    CASE
        WHEN inv.AmountPaid >= inv.Amount             THEN 'Paid'
        WHEN DATEDIFF(day, inv.GLDate, GETDATE()) <= 30  THEN 'Current'
        WHEN DATEDIFF(day, inv.GLDate, GETDATE()) <= 60  THEN '31-60 Days'
        WHEN DATEDIFF(day, inv.GLDate, GETDATE()) <= 90  THEN '61-90 Days'
        ELSE '90+ Days'
    END                                 AS AgingBucket,

    -- === Metadata ===
    inv.IsGLPosting                     AS IsPosted,
    inv.IsClosed,
    inv.CreateDate                      AS CreateDate,
    inv.ModifyDate                      AS ModifyDate

FROM dbo.FactGL inv
JOIN dbo.SourceDimGLAccount inv_acct
    ON inv.SourceGLAccountKey = inv_acct.SourceGLAccountKey
    AND inv_acct.SourceGLAccountName = 'Accounts Receivable'
LEFT JOIN dbo.SourceDimClass cls ON inv.SourceClassKey = cls.SourceClassKey
LEFT JOIN dbo.DimCustomer cust ON inv.CVCustomerID = cust.CVCustomerID
LEFT JOIN dbo.SourceDimSubsidiary sub ON inv.SourceSubsidiaryID = sub.SourceSubsidiaryID
LEFT JOIN TxnProducts tp ON inv.GLID = tp.TxnGLID AND tp.rn = 1
LEFT JOIN TxnProductCounts tpc ON inv.GLID = tpc.GLID
LEFT JOIN dbo.DimProduct prod ON tp.CVProductID = prod.CVProductID
LEFT JOIN InvoiceSubscription isub ON inv.GLID = isub.InvoiceGLID
LEFT JOIN SalesOrderLinks sol ON inv.GLID = sol.InvoiceGLID
LEFT JOIN SalesOrderHeader soh ON sol.SalesOrderGLID = soh.SalesOrderGLID AND soh.rn = 1
LEFT JOIN PaymentSummary pmt ON inv.GLID = pmt.InvoiceGLID
LEFT JOIN LatestPaymentMethod lpm ON inv.GLID = lpm.InvoiceGLID AND lpm.rn = 1
LEFT JOIN FirstPaymentMethod fpm ON inv.GLID = fpm.InvoiceGLID AND fpm.rn = 1
LEFT JOIN DepositSummary dep ON inv.GLID = dep.InvoiceGLID
WHERE inv.SourceTransactionTypeID = 'CustInvc'
    AND inv.Amount > 0

UNION ALL

-- =====================================================================
-- CREDIT MEMOS (CustCred) — customer, product (from siblings), class
-- =====================================================================
SELECT
    'Credit Memo'                       AS TransactionType,

    NULL AS SalesOrderID, NULL AS SalesOrderName, NULL AS SalesOrderDate, NULL AS SalesOrderStatus,

    cm.GLID                             AS TransactionID,
    cm.GLDisplayName                    AS TransactionName,
    cm.GLDate                           AS TransactionDate,
    cm.ReportingPeriod                  AS PostingPeriod,
    cm.GLStatus                         AS TransactionStatus,
    cm.GLURL                            AS TransactionURL,

    cm.CVCustomerID,
    cust.CustomerName,
    cust.NetSuiteID                     AS CustomerNetSuiteID,

    cm.SourceSubsidiaryID              AS SubsidiaryID,
    sub.SourceSubsidiaryName           AS SubsidiaryName,
    cm.SourceCurrencyID                AS Currency,

    tp.CVProductID,
    prod.ProductName,
    prod.ProductCode,
    prod.DepartmentName,
    COALESCE(tpc.ProductCount, 0)      AS ProductCount,
    cls.SourceClassName                AS ClassName,
    CASE
        WHEN cls.SourceClassName IN ('SBU Services', 'SBU Partnerships Management Fees') THEN 'SBU'
        WHEN cls.SourceClassName = 'Platform Review' THEN 'Platform Review'
        WHEN cls.SourceClassName IN ('10X Business Academy', '10X BA Coaching', '10X Business Advisor', '10X BA Online Program', '10X BA Lab') THEN 'Business Academy'
        WHEN cls.SourceClassName IN ('10X360', 'Elite Edge', 'Essentials', 'BEW', 'PEW', 'Cardone U', 'BMLP', 'BMLP Retreat', 'Elevate', 'GrowthCon', 'CTTI Essentials', 'CTTI Events', 'Mastery Events', 'Vertical Events', 'CV Events', 'REW', 'OEW', 'SEW', 'LEW', 'FEW', 'MEW', '10X Business Summit (CV)', 'Business Summit', 'Business Bootcamp', 'Real Estate Summit', 'Masterminds') THEN 'Events & Programs'
        WHEN cls.SourceClassName IN ('FAAS', 'Bookkeeping', 'Financial Services', 'Business Services') THEN 'CVAS'
        WHEN cls.SourceClassName IN ('10X Recruiting', '10X Human Resources', 'R3 Hiring Tool') THEN 'Recruiting'
        WHEN cls.SourceClassName IN ('Marketing Shared Services', 'Scale CRM') THEN 'Marketing'
        WHEN cls.SourceClassName IN ('10X Buy Sell', 'DE - Sell Side', 'DE-Buy Side', 'Private Coaching', 'PC - Elite250', 'ELITE 125', 'ELITE 250', 'PC SALES', 'PC - Brandon Dawson') THEN 'M&A / Elite / Coaching'
        WHEN cls.SourceClassName = 'Online Programs' THEN 'Online Programs'
        WHEN cls.SourceClassName IN ('Other Revenue', 'People', 'Revenue', 'Operations', 'Book Sales', 'Revified') THEN 'Other'
        ELSE 'Unclassified'
    END                                AS ProductCategory,

    cm.SourceSalesRepID                AS SalesRepID,
    cm.SourceSalesRep2ID               AS SalesRep2ID,

    cm.Amount                          AS Amount,
    cm.AmountLocal,

    NULL AS AmountPaid, NULL AS AmountPaidLocal, NULL AS AmountUnpaid,
    cm.GLStatus                        AS CollectionStatus,
    0 AS PaymentCount,
    NULL AS FirstPaymentDate, NULL AS LastPaymentDate, NULL AS LastPaymentMethod, NULL AS FirstPaymentMethod, NULL AS DaysToFirstPayment,

    0 AS DepositApplicationCount, 0 AS CustomerDepositCount,
    NULL AS FirstDepositAppDate, NULL AS LastDepositAppDate,
    CAST(0 AS BIT)                     AS HasDepositApplied,

    CAST(0 AS BIT)                     AS IsNewSubscription,
    prod.IsSubscriptionName            AS IsSubscriptionProduct,
    cm.Elite                           AS EliteTier,

    DATEDIFF(day, cm.GLDate, GETDATE()) AS DaysSinceTransaction,
    NULL                               AS AgingBucket,

    cm.IsGLPosting                     AS IsPosted,
    cm.IsClosed,
    cm.CreateDate,
    cm.ModifyDate

FROM dbo.FactGL cm
JOIN dbo.SourceDimGLAccount cm_acct
    ON cm.SourceGLAccountKey = cm_acct.SourceGLAccountKey
    AND cm_acct.SourceGLAccountName = 'Accounts Receivable'
LEFT JOIN dbo.SourceDimClass cls ON cm.SourceClassKey = cls.SourceClassKey
LEFT JOIN dbo.DimCustomer cust ON cm.CVCustomerID = cust.CVCustomerID
LEFT JOIN dbo.SourceDimSubsidiary sub ON cm.SourceSubsidiaryID = sub.SourceSubsidiaryID
LEFT JOIN TxnProducts tp ON cm.GLID = tp.TxnGLID AND tp.rn = 1
LEFT JOIN TxnProductCounts tpc ON cm.GLID = tpc.GLID
LEFT JOIN dbo.DimProduct prod ON tp.CVProductID = prod.CVProductID
WHERE cm.SourceTransactionTypeID = 'CustCred'

UNION ALL

-- =====================================================================
-- JOURNAL ENTRIES (Journal + Journal Entry) — customer, class only
-- =====================================================================
SELECT
    'Journal Entry'                    AS TransactionType,

    NULL AS SalesOrderID, NULL AS SalesOrderName, NULL AS SalesOrderDate, NULL AS SalesOrderStatus,

    je.GLID                            AS TransactionID,
    je.GLDisplayName                   AS TransactionName,
    je.GLDate                          AS TransactionDate,
    je.ReportingPeriod                 AS PostingPeriod,
    je.GLStatus                        AS TransactionStatus,
    je.GLURL                           AS TransactionURL,

    je.CVCustomerID,
    cust.CustomerName,
    cust.NetSuiteID                    AS CustomerNetSuiteID,

    je.SourceSubsidiaryID             AS SubsidiaryID,
    sub.SourceSubsidiaryName          AS SubsidiaryName,
    je.SourceCurrencyID               AS Currency,

    NULL AS CVProductID, NULL AS ProductName, NULL AS ProductCode, NULL AS DepartmentName,
    0                                  AS ProductCount,
    cls.SourceClassName                AS ClassName,
    CASE
        WHEN cls.SourceClassName IN ('SBU Services', 'SBU Partnerships Management Fees') THEN 'SBU'
        WHEN cls.SourceClassName = 'Platform Review' THEN 'Platform Review'
        WHEN cls.SourceClassName IN ('10X Business Academy', '10X BA Coaching', '10X Business Advisor', '10X BA Online Program', '10X BA Lab') THEN 'Business Academy'
        WHEN cls.SourceClassName IN ('10X360', 'Elite Edge', 'Essentials', 'BEW', 'PEW', 'Cardone U', 'BMLP', 'BMLP Retreat', 'Elevate', 'GrowthCon', 'CTTI Essentials', 'CTTI Events', 'Mastery Events', 'Vertical Events', 'CV Events', 'REW', 'OEW', 'SEW', 'LEW', 'FEW', 'MEW', '10X Business Summit (CV)', 'Business Summit', 'Business Bootcamp', 'Real Estate Summit', 'Masterminds') THEN 'Events & Programs'
        WHEN cls.SourceClassName IN ('FAAS', 'Bookkeeping', 'Financial Services', 'Business Services') THEN 'CVAS'
        WHEN cls.SourceClassName IN ('10X Recruiting', '10X Human Resources', 'R3 Hiring Tool') THEN 'Recruiting'
        WHEN cls.SourceClassName IN ('Marketing Shared Services', 'Scale CRM') THEN 'Marketing'
        WHEN cls.SourceClassName IN ('10X Buy Sell', 'DE - Sell Side', 'DE-Buy Side', 'Private Coaching', 'PC - Elite250', 'ELITE 125', 'ELITE 250', 'PC SALES', 'PC - Brandon Dawson') THEN 'M&A / Elite / Coaching'
        WHEN cls.SourceClassName = 'Online Programs' THEN 'Online Programs'
        WHEN cls.SourceClassName IN ('Other Revenue', 'People', 'Revenue', 'Operations', 'Book Sales', 'Revified') THEN 'Other'
        ELSE 'Unclassified'
    END                                AS ProductCategory,

    NULL AS SalesRepID, NULL AS SalesRep2ID,

    je.Amount                          AS Amount,
    je.AmountLocal,

    NULL AS AmountPaid, NULL AS AmountPaidLocal, NULL AS AmountUnpaid,
    NULL                               AS CollectionStatus,
    0 AS PaymentCount,
    NULL AS FirstPaymentDate, NULL AS LastPaymentDate, NULL AS LastPaymentMethod, NULL AS FirstPaymentMethod, NULL AS DaysToFirstPayment,

    0 AS DepositApplicationCount, 0 AS CustomerDepositCount,
    NULL AS FirstDepositAppDate, NULL AS LastDepositAppDate,
    CAST(0 AS BIT)                     AS HasDepositApplied,

    CAST(0 AS BIT)                     AS IsNewSubscription,
    NULL                               AS IsSubscriptionProduct,
    je.Elite                           AS EliteTier,

    DATEDIFF(day, je.GLDate, GETDATE()) AS DaysSinceTransaction,
    NULL                               AS AgingBucket,

    je.IsGLPosting                     AS IsPosted,
    je.IsClosed,
    je.CreateDate,
    je.ModifyDate

FROM dbo.FactGL je
JOIN dbo.SourceDimGLAccount je_acct
    ON je.SourceGLAccountKey = je_acct.SourceGLAccountKey
    AND je_acct.SourceGLAccountName = 'Accounts Receivable'
LEFT JOIN dbo.SourceDimClass cls ON je.SourceClassKey = cls.SourceClassKey
LEFT JOIN dbo.DimCustomer cust ON je.CVCustomerID = cust.CVCustomerID
LEFT JOIN dbo.SourceDimSubsidiary sub ON je.SourceSubsidiaryID = sub.SourceSubsidiaryID
WHERE je.SourceTransactionTypeID IN ('Journal', 'Journal Entry')
