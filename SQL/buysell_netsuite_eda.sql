-- ============================================================
-- Buy/Sell NetSuite EDA
-- Goal: Understand FactGL data for Buy/Sell subsidiary
-- Key: Buy/Sell is its own subsidiary (NOT Cardone Ventures)
-- Exception: BAS is under Cardone Ventures
-- ============================================================

-- 1. Find all subsidiaries — identify Buy/Sell and Cardone Ventures IDs
SELECT *
FROM [IT_Data_Gateway].[DWH].[DimSubsidiary]
ORDER BY SubsidiaryName;

-- 2. What products exist? Look for Buy/Sell related ones
SELECT 
    ProductCode,
    ProductName,
    ShortName,
    DepartmentName,
    ProductSubCategoryName,
    ProductClassName,
    SubsidiaryName,
    JourneyTypeName,
    IsActive
FROM [IT_Data_Gateway].[DWH].[DimProduct]
WHERE ProductName LIKE '%Buy%'
   OR ProductName LIKE '%Sell%'
   OR ProductName LIKE '%BAC%'
   OR ProductName LIKE '%Acquisition%'
   OR ProductName LIKE '%Advisory%'
   OR ProductName LIKE '%Readiness%'
   OR ProductName LIKE '%Valuation%'
   OR ProductName LIKE '%Capital Structure%'
   OR ProductName LIKE '%Partnership Buyout%'
   OR ShortName LIKE '%BS%'
   OR ShortName LIKE '%Buy%'
   OR ShortName LIKE '%Sell%'
ORDER BY ProductName;

-- 3. FactGL for Buy/Sell subsidiary — what does the data look like?
--    (Replace XX with the Buy/Sell subsidiary ID from query 1)
--    Starting broad to see what's there
SELECT TOP 100
    gl.GLDate,
    gl.GLDescription,
    gl.GLLineDescription,
    gl.Amount,
    gl.CustomerID,
    gl.ProductID,
    gl.SubsidiaryID,
    gl.TransactionTypeID,
    gl.GLStatus,
    gl.IsGLPosting
FROM [IT_Data_Gateway].[DWH].[FactGL] gl
WHERE gl.SubsidiaryID IN (
    SELECT SubsidiaryID 
    FROM [IT_Data_Gateway].[DWH].[DimSubsidiary] 
    WHERE SubsidiaryName LIKE '%Buy%Sell%'
       OR SubsidiaryName LIKE '%B/S%'
       OR SubsidiaryName LIKE '%BS%'
)
ORDER BY gl.GLDate DESC;

-- 4. FactGL summary by product for Buy/Sell subsidiary
SELECT 
    p.ProductName,
    p.ProductCode,
    p.ShortName,
    COUNT(*) AS line_count,
    SUM(gl.Amount) AS total_amount,
    MIN(gl.GLDate) AS earliest_date,
    MAX(gl.GLDate) AS latest_date
FROM [IT_Data_Gateway].[DWH].[FactGL] gl
LEFT JOIN [IT_Data_Gateway].[DWH].[DimProduct] p
    ON gl.ProductID = p.ProductCode
WHERE gl.SubsidiaryID IN (
    SELECT SubsidiaryID 
    FROM [IT_Data_Gateway].[DWH].[DimSubsidiary] 
    WHERE SubsidiaryName LIKE '%Buy%Sell%'
       OR SubsidiaryName LIKE '%B/S%'
       OR SubsidiaryName LIKE '%BS%'
)
AND gl.IsGLPosting = 1
GROUP BY p.ProductName, p.ProductCode, p.ShortName
ORDER BY total_amount DESC;

-- 5. BAS exception — find Business Acquisition Summit under Cardone Ventures
SELECT TOP 50
    gl.GLDate,
    gl.GLDescription,
    gl.GLLineDescription,
    gl.Amount,
    gl.ProductID,
    p.ProductName,
    gl.SubsidiaryID,
    s.SubsidiaryName
FROM [IT_Data_Gateway].[DWH].[FactGL] gl
LEFT JOIN [IT_Data_Gateway].[DWH].[DimProduct] p
    ON gl.ProductID = p.ProductCode
LEFT JOIN [IT_Data_Gateway].[DWH].[DimSubsidiary] s
    ON gl.SubsidiaryID = s.SubsidiaryID
WHERE (p.ProductName LIKE '%Acquisition Summit%'
    OR p.ProductName LIKE '%BAS%'
    OR p.ProductCode LIKE '%BAS%')
AND gl.IsGLPosting = 1
ORDER BY gl.GLDate DESC;

-- 6. What transaction types exist in FactGL for Buy/Sell?
--    (Sales Order, Invoice, Cash Sale, etc.)
SELECT 
    gl.TransactionTypeID,
    COUNT(*) AS line_count,
    SUM(gl.Amount) AS total_amount
FROM [IT_Data_Gateway].[DWH].[FactGL] gl
WHERE gl.SubsidiaryID IN (
    SELECT SubsidiaryID 
    FROM [IT_Data_Gateway].[DWH].[DimSubsidiary] 
    WHERE SubsidiaryName LIKE '%Buy%Sell%'
       OR SubsidiaryName LIKE '%B/S%'
       OR SubsidiaryName LIKE '%BS%'
)
AND gl.IsGLPosting = 1
GROUP BY gl.TransactionTypeID
ORDER BY total_amount DESC;

-- 7. Customer dimension — can we link FactGL customers to HubSpot companies?
SELECT TOP 20
    gl.CustomerID,
    dc.CustomerName,
    dc.CVCustomerID,
    dc.NetSuiteID,
    gl.Amount,
    gl.GLDate
FROM [IT_Data_Gateway].[DWH].[FactGL] gl
LEFT JOIN [IT_Data_Gateway].[DWH].[DimCustomer] dc
    ON gl.CustomerID = dc.CustomerCode
WHERE gl.SubsidiaryID IN (
    SELECT SubsidiaryID 
    FROM [IT_Data_Gateway].[DWH].[DimSubsidiary] 
    WHERE SubsidiaryName LIKE '%Buy%Sell%'
       OR SubsidiaryName LIKE '%B/S%'
       OR SubsidiaryName LIKE '%BS%'
)
AND gl.IsGLPosting = 1
ORDER BY gl.GLDate DESC;



-- 1. Brian's query — Buy/Sell transactions
SELECT *
FROM [IT_Data_Gateway].[DWH].[FactGL] g
JOIN [IT_Data_Gateway].[DWH].[DimProduct] p 
    ON g.CVProductID = p.CVProductID
WHERE SourceTransactionTypeID IN ('SalesOrd', 'CashSale')
  AND p.ProductSubCategoryName = '10X Buy Sell';

-- 2. What products come back?
SELECT 
    p.ProductName,
    p.ProductCode,
    p.ProductSubCategoryName,
    p.ProductClassName,
    COUNT(*) AS line_count,
    SUM(g.Amount) AS total_amount,
    MIN(g.GLDate) AS earliest,
    MAX(g.GLDate) AS latest
FROM [IT_Data_Gateway].[DWH].[FactGL] g
JOIN [IT_Data_Gateway].[DWH].[DimProduct] p 
    ON g.CVProductID = p.CVProductID
WHERE g.SourceTransactionTypeID IN ('SalesOrd', 'CashSale')
  AND p.ProductSubCategoryName = '10X Buy Sell'
GROUP BY p.ProductName, p.ProductCode, p.ProductSubCategoryName, p.ProductClassName
ORDER BY total_amount DESC;

-- 3. What about BAS? (the exception under CV)
SELECT 
    p.ProductName,
    p.ProductSubCategoryName,
    p.ProductClassName,
    COUNT(*) AS line_count,
    SUM(g.Amount) AS total_amount
FROM [IT_Data_Gateway].[DWH].[FactGL] g
JOIN [IT_Data_Gateway].[DWH].[DimProduct] p 
    ON g.CVProductID = p.CVProductID
WHERE g.SourceTransactionTypeID IN ('SalesOrd', 'CashSale')
  AND p.ProductName LIKE '%Acquisition Summit%'
GROUP BY p.ProductName, p.ProductSubCategoryName, p.ProductClassName;

-- 4. Can we link to customers?
SELECT TOP 20
    g.GLDate,
    g.Amount,
    g.CustomerID,
    c.CustomerName,
    p.ProductName,
    g.SourceTransactionTypeID
FROM [IT_Data_Gateway].[DWH].[FactGL] g
JOIN [IT_Data_Gateway].[DWH].[DimProduct] p 
    ON g.CVProductID = p.CVProductID
LEFT JOIN [IT_Data_Gateway].[DWH].[DimCustomer] c
    ON g.CustomerID = c.CustomerCode
WHERE g.SourceTransactionTypeID IN ('SalesOrd', 'CashSale')
  AND p.ProductSubCategoryName = '10X Buy Sell'
ORDER BY g.GLDate DESC;


-- What's IsGLPosting = 1 for Buy/Sell products?
SELECT 
    p.ProductName,
    g.SourceTransactionTypeID,
    g.IsGLPosting,
    COUNT(*) AS line_count,
    SUM(g.Amount) AS total_amount
FROM [IT_Data_Gateway].[DWH].[FactGL] g
JOIN [IT_Data_Gateway].[DWH].[DimProduct] p 
    ON g.CVProductID = p.CVProductID
WHERE p.ProductSubCategoryName = '10X Buy Sell'
GROUP BY p.ProductName, g.SourceTransactionTypeID, g.IsGLPosting
ORDER BY p.ProductName, g.IsGLPosting DESC;


SELECT TOP 5 g.CVCustomerID, c.CVCustomerID, c.CustomerName
FROM [IT_Data_Gateway].[DWH].[FactGL] g
JOIN [IT_Data_Gateway].[DWH].[DimProduct] p ON g.CVProductID = p.CVProductID
LEFT JOIN [IT_Data_Gateway].[DWH].[DimCustomer] c ON g.CVCustomerID = c.CVCustomerID
WHERE p.ProductSubCategoryName = '10X Buy Sell'
  AND g.CVCustomerID IS NOT NULL;