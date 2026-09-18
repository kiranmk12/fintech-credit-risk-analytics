USE Finance;
GO


-- SET DATA TYPES & PRIMARY KEYS

-- DimBorrower
ALTER TABLE DimBorrower 
ALTER COLUMN BorrowerID VARCHAR(20) NOT NULL;

ALTER TABLE DimBorrower 
ADD CONSTRAINT PK_DimBorrower PRIMARY KEY (BorrowerID);


-- FactLoanApplication
ALTER TABLE FactLoanApplication 
ALTER COLUMN LoanID VARCHAR(20) NOT NULL;

ALTER TABLE FactLoanApplication 
ALTER COLUMN BorrowerID VARCHAR(20) NOT NULL;

ALTER TABLE FactLoanApplication 
ADD CONSTRAINT PK_FactLoanApplication PRIMARY KEY (LoanID);

-- FactLoanPerformance 
ALTER TABLE FactLoanPerformance 
ALTER COLUMN LoanID VARCHAR(20) NOT NULL;

ALTER TABLE FactLoanPerformance 
ALTER COLUMN SnapshotDate DATE NOT NULL;

ALTER TABLE FactLoanPerformance 
ADD CONSTRAINT PK_FactLoanPerformance PRIMARY KEY (LoanID, SnapshotDate);
GO

-- ADD FOREIGN KEYS 
ALTER TABLE FactLoanApplication
ADD CONSTRAINT FK_FactLoanApp_DimBorrower 
FOREIGN KEY (BorrowerID) REFERENCES DimBorrower(BorrowerID);

ALTER TABLE FactLoanPerformance
ADD CONSTRAINT FK_FactLoanPerf_FactLoanApp 
FOREIGN KEY (LoanID) REFERENCES FactLoanApplication(LoanID);
GO

--ADD CHECK CONSTRAINTS & DATA INTEGRITY RULES

-- Annual Income must be positive
ALTER TABLE DimBorrower
ADD CONSTRAINT CHK_Borrower_Income CHECK (AnnualIncome >= 0);

-- Debt-To-Income Ratio must be between 0 and 100%
ALTER TABLE FactLoanApplication
ADD CONSTRAINT CHK_App_DTI CHECK (DebtToIncomeRatio BETWEEN 0 AND 100);



--sp_help DimBorrower
--sp_help fact


CREATE TABLE DataQuality_AuditLog (
    AuditID INT IDENTITY(1,1) PRIMARY KEY,
    ExecutionTimestamp DATETIME DEFAULT GETDATE(),
    TableName VARCHAR(100),
    TotalRowsIngested INT,
    NullCountResolved INT,
    OutliersCappedCount INT,
    DataQualityStatus VARCHAR(20)
);

SELECT * FROM DataQuality_AuditLog

/*What is our overall application approval rate, and 
how much requested capital are we leaving on the table due to rejections and partial approvals?*/

SELECT 
    COUNT(LoanID) AS TotalApplications,
    ROUND(100.0 * AVG(CASE WHEN ApplicationStatus = 'Approved' THEN 1.0 ELSE 0.0 END), 2) AS FullApprovalRate_Pct,
    ROUND(100.0 * AVG(CASE WHEN ApplicationStatus = 'Partially_Approved' THEN 1.0 ELSE 0.0 END), 2) AS PartialApprovalRate_Pct,
    ROUND(100.0 * AVG(CASE WHEN ApplicationStatus IN ('Approved', 'Partially_Approved') THEN 1.0 ELSE 0.0 END), 2) AS OverallOfferRate_Pct,
    ROUND(SUM(RequestedAmount), 2) AS TotalRequestedCapital,
    ROUND(SUM(COALESCE(ApprovedAmount, 0)), 2) AS TotalApprovedCapital,
    ROUND(SUM(CASE WHEN ApplicationStatus = 'Rejected' THEN RequestedAmount ELSE 0 END), 2) AS CapitalLost_Rejections,
    ROUND(SUM(CASE WHEN ApplicationStatus = 'Partially_Approved' THEN RequestedAmount - COALESCE(ApprovedAmount, 0) ELSE 0 END), 2) AS CapitalLost_PartialCutbacks,
    ROUND(SUM(RequestedAmount - COALESCE(ApprovedAmount, 0)), 2) AS TotalUnfulfilledCapital
FROM FactLoanApplication;

SELECT  ROUND( 100.0 * SUM(ApprovedAmount) / NULLIF(SUM(RequestedAmount), 0),2) AS CapitalConversionRate_Pct FROM FactLoanApplication; 


/*
How is our outstanding balance distributed across loan performance statuses today, and what is our current 30+ DPD and 90+ DPD exposure?
*/


WITH LatestPerformance AS (
    SELECT  LoanID, SnapshotDate, DaysPastDue,OutstandingPrincipal, PerformanceStatus,
        ROW_NUMBER() OVER (PARTITION BY LoanID ORDER BY SnapshotDate DESC) AS RowNum
    FROM FactLoanPerformance
)
SELECT 
    COUNT(LoanID) AS ActiveLoansCount,
    ROUND(SUM(OutstandingPrincipal), 2) AS TotalOutstandingPrincipal,
    ROUND(SUM(CASE WHEN DaysPastDue = 0 THEN OutstandingPrincipal ELSE 0 END), 2) AS Current_0DPD_Exposure,
    ROUND(SUM(CASE WHEN DaysPastDue BETWEEN 1 AND 29 THEN OutstandingPrincipal ELSE 0 END), 2) AS EarlyGrace_1to29DPD_Exposure,
    ROUND(SUM(CASE WHEN DaysPastDue BETWEEN 30 AND 89 THEN OutstandingPrincipal ELSE 0 END), 2) AS DPD_30to89_Exposure,
    ROUND(SUM(CASE WHEN DaysPastDue >= 90 THEN OutstandingPrincipal ELSE 0 END), 2) AS DPD_90Plus_Exposure,
    ROUND(SUM(CASE WHEN DaysPastDue >= 30 THEN OutstandingPrincipal ELSE 0 END), 2) AS Total_30PlusDPD_Exposure,
    ROUND(
        100.0 * SUM(CASE WHEN DaysPastDue >= 30 THEN OutstandingPrincipal ELSE 0 END) 
        / NULLIF(SUM(OutstandingPrincipal), 0), 2 ) AS DPD_30Plus_Pct 
 FROM LatestPerformance WHERE RowNum = 1;

 /*Which borrower credit score tiers and loan terms are driving the bulk of our 90+ DPD defaulted exposure, 
 and are high interest rates compensating for this risk?*/

WITH LatestPerformance AS (
    SELECT LoanID, SnapshotDate, DaysPastDue,OutstandingPrincipal,
        ROW_NUMBER() OVER (PARTITION BY LoanID ORDER BY SnapshotDate DESC) AS RowNum FROM FactLoanPerformance
)
SELECT 
    CASE 
        WHEN b.CreditScore < 600 THEN 'Poor (<600)'
        WHEN b.CreditScore BETWEEN 600 AND 659 THEN 'Fair (600-659)'
        WHEN b.CreditScore BETWEEN 660 AND 719 THEN 'Good (660-719)'
        WHEN b.CreditScore >= 720 THEN 'Excellent (720+)'
        ELSE 'Unknown'
    END AS CreditScoreBand,
    COUNT(app.LoanID) AS ActiveLoansCount,
    ROUND(AVG(app.InterestRate), 2) AS AvgInterestRate_Pct,
    ROUND(SUM(lp.OutstandingPrincipal), 2) AS TotalOutstandingBalance,
    ROUND(SUM(CASE WHEN lp.DaysPastDue >= 90 THEN lp.OutstandingPrincipal ELSE 0 END), 2) AS DPD_90Plus_Exposure,
    ROUND( 100.0 * SUM(CASE WHEN lp.DaysPastDue >= 90 THEN lp.OutstandingPrincipal ELSE 0 END) 
        / NULLIF(SUM(lp.OutstandingPrincipal), 0), 2) AS DefaultRate_Pct
FROM FactLoanApplication app
INNER JOIN DimBorrower b   ON app.BorrowerID = b.BorrowerID
INNER JOIN LatestPerformance lp  ON app.LoanID = lp.LoanID AND lp.RowNum = 1
WHERE app.ApplicationStatus IN ('Approved', 'Partially_Approved')
GROUP BY 
    CASE 
        WHEN b.CreditScore < 600 THEN 'Poor (<600)'
        WHEN b.CreditScore BETWEEN 600 AND 659 THEN 'Fair (600-659)'
        WHEN b.CreditScore BETWEEN 660 AND 719 THEN 'Good (660-719)'
        WHEN b.CreditScore >= 720 THEN 'Excellent (720+)'
        ELSE 'Unknown'
    END ORDER BY CreditScoreBand;



/*Why are high-credit borrowers defaulting at such high rates?Are long loan terms (e.g., 60-month terms) or 
high Debt-to-Income (DTI) ratios causing leverage strain among approved borrowers?*/

WITH LatestPerformance AS (
    SELECT  LoanID,SnapshotDate, DaysPastDue,OutstandingPrincipal,ROW_NUMBER() OVER (PARTITION BY LoanID ORDER BY SnapshotDate DESC) AS RowNum
    FROM FactLoanPerformance
    )
SELECT 
    CASE 
        WHEN app.DebtToIncomeRatio <= 20 THEN '1. Low (<=20%)'
        WHEN app.DebtToIncomeRatio BETWEEN 20.01 AND 35 THEN '2. Moderate (20.01-35%)'
        WHEN app.DebtToIncomeRatio BETWEEN 35.01 AND 50 THEN '3. High (35.01-50%)'
        WHEN app.DebtToIncomeRatio > 50 THEN '4. Extreme (>50%)'
        ELSE 'Unknown'
    END AS DTI_Bucket, app.TermMonths,
    COUNT(app.LoanID) AS TotalLoansCount,
    SUM(CASE WHEN lp.DaysPastDue >= 90 THEN 1 ELSE 0 END) AS DefaultedLoansCount,
    ROUND( 100.0 * SUM(CASE WHEN lp.DaysPastDue >= 90 THEN 1 ELSE 0 END) 
        / NULLIF(COUNT(app.LoanID), 0),2) AS LoanDefaultRate_Pct,
    ROUND(SUM(lp.OutstandingPrincipal), 2) AS TotalOutstandingBalance,
    ROUND(SUM(CASE WHEN lp.DaysPastDue >= 90 THEN lp.OutstandingPrincipal ELSE 0 END), 2) AS DPD_90Plus_Exposure,
    ROUND(100.0 * SUM(CASE WHEN lp.DaysPastDue >= 90 THEN lp.OutstandingPrincipal ELSE 0 END) 
        / NULLIF(SUM(lp.OutstandingPrincipal), 0), 2 ) AS BalanceDefaultRate_Pct
FROM FactLoanApplication app
INNER JOIN LatestPerformance lp  ON app.LoanID = lp.LoanID AND lp.RowNum = 1 WHERE app.ApplicationStatus IN ('Approved', 'Partially_Approved')
GROUP BY 
    CASE 
        WHEN app.DebtToIncomeRatio <= 20 THEN '1. Low (<=20%)'
        WHEN app.DebtToIncomeRatio BETWEEN 20.01 AND 35 THEN '2. Moderate (20.01-35%)'
        WHEN app.DebtToIncomeRatio BETWEEN 35.01 AND 50 THEN '3. High (35.01-50%)'
        WHEN app.DebtToIncomeRatio > 50 THEN '4. Extreme (>50%)'
        ELSE 'Unknown'
    END,app.TermMonths ORDER BY DTI_Bucket ASC, app.TermMonths ASC;






   /*Did our underwriting standards collapse in a specific origination year, or 
    are older loan cohorts simply accumulating defaults over time?*/


WITH LatestPerformance AS (
    SELECT LoanID, SnapshotDate,DaysPastDue,OutstandingPrincipal, ROW_NUMBER() OVER (PARTITION BY LoanID ORDER BY SnapshotDate DESC) AS RowNum
    FROM FactLoanPerformance
)
SELECT  YEAR(app.IssueDate) AS OriginationYear,
    COUNT(app.LoanID) AS TotalLoansCount,
    SUM(CASE WHEN lp.DaysPastDue >= 90 THEN 1 ELSE 0 END) AS DefaultedLoansCount,
    ROUND(  100.0 * SUM(CASE WHEN lp.DaysPastDue >= 90 THEN 1 ELSE 0 END)  / NULLIF(COUNT(app.LoanID), 0),2 ) AS LoanDefaultRate_Pct,
    ROUND(SUM(lp.OutstandingPrincipal), 2) AS TotalOutstandingBalance,
    ROUND(SUM(CASE WHEN lp.DaysPastDue >= 90 THEN lp.OutstandingPrincipal ELSE 0 END), 2) AS DPD_90Plus_Exposure,
    ROUND( 100.0 * SUM(CASE WHEN lp.DaysPastDue >= 90 THEN lp.OutstandingPrincipal ELSE 0 END) 
    / NULLIF(SUM(lp.OutstandingPrincipal), 0), 2) AS BalanceDefaultRate_Pct
FROM FactLoanApplication app
INNER JOIN LatestPerformance lp  ON app.LoanID = lp.LoanID AND lp.RowNum = 1
WHERE app.ApplicationStatus IN ('Approved', 'Partially_Approved')
GROUP BY YEAR(app.IssueDate) ORDER BY OriginationYear ASC;



--MOB Cohort Matrix

WITH CohortPerformance AS (
    SELECT  YEAR(app.IssueDate) AS OriginationYear, lp.MonthsOnBook, COUNT(DISTINCT app.LoanID) AS TotalActiveLoans,
        SUM(CASE WHEN lp.DaysPastDue >= 90 THEN 1 ELSE 0 END) AS DefaultedLoansCount
    FROM FactLoanApplication app
    INNER JOIN FactLoanPerformance lp  ON app.LoanID = lp.LoanID
    WHERE app.ApplicationStatus IN ('Approved', 'Partially_Approved')
      AND lp.MonthsOnBook IN (6, 12, 18, 24)
    GROUP BY YEAR(app.IssueDate), lp.MonthsOnBook
)
SELECT  OriginationYear,
    ROUND(
        100.0 * MAX(CASE WHEN MonthsOnBook = 6 THEN DefaultedLoansCount END) 
        / NULLIF(MAX(CASE WHEN MonthsOnBook = 6 THEN TotalActiveLoans END), 0),2) AS DefaultRate_MOB6_Pct,
    ROUND( 100.0 * MAX(CASE WHEN MonthsOnBook = 12 THEN DefaultedLoansCount END) 
        / NULLIF(MAX(CASE WHEN MonthsOnBook = 12 THEN TotalActiveLoans END), 0),2) AS DefaultRate_MOB12_Pct,
    ROUND(100.0 * MAX(CASE WHEN MonthsOnBook = 18 THEN DefaultedLoansCount END) 
        / NULLIF(MAX(CASE WHEN MonthsOnBook = 18 THEN TotalActiveLoans END), 0),2 ) AS DefaultRate_MOB18_Pct,
    ROUND( 100.0 * MAX(CASE WHEN MonthsOnBook = 24 THEN DefaultedLoansCount END) 
    / NULLIF(MAX(CASE WHEN MonthsOnBook = 24 THEN TotalActiveLoans END), 0),2) AS DefaultRate_MOB24_Pct
FROM CohortPerformance
GROUP BY OriginationYear ORDER BY OriginationYear ASC;


----------------------------
WITH OriginatedLoans AS (
    SELECT a.LoanID,  YEAR(a.IssueDate) AS OriginationYear  FROM FactLoanApplication a  WHERE a.ApplicationStatus IN ('Approved', 'Partially_Approved')
),
LoanFirstDefault AS (
    SELECT LoanID, MIN(MonthsOnBook) AS FirstDefaultMOB  FROM FactLoanPerformance WHERE DaysPastDue >= 90  GROUP BY LoanID
),
CohortBase AS (
    SELECT  o.OriginationYear,  o.LoanID, d.FirstDefaultMOB FROM OriginatedLoans o LEFT JOIN LoanFirstDefault d  ON o.LoanID = d.LoanID
),
CohortReach AS (
    SELECT YEAR(a.IssueDate) AS OriginationYear, MAX(lp.MonthsOnBook) AS MaxMOBObserved  FROM FactLoanApplication a
    INNER JOIN FactLoanPerformance lp ON a.LoanID = lp.LoanID   WHERE a.ApplicationStatus IN ('Approved', 'Partially_Approved') GROUP BY YEAR(a.IssueDate)
),
CohortSummary AS (
    SELECT cb.OriginationYear,
        COUNT(DISTINCT cb.LoanID) AS CohortSize,
        SUM(CASE WHEN cb.FirstDefaultMOB <= 6  THEN 1 ELSE 0 END) AS DefaultedByMOB6,
        SUM(CASE WHEN cb.FirstDefaultMOB <= 12 THEN 1 ELSE 0 END) AS DefaultedByMOB12,
        SUM(CASE WHEN cb.FirstDefaultMOB <= 18 THEN 1 ELSE 0 END) AS DefaultedByMOB18,
        SUM(CASE WHEN cb.FirstDefaultMOB <= 24 THEN 1 ELSE 0 END) AS DefaultedByMOB24
    FROM CohortBase cb GROUP BY cb.OriginationYear
)
SELECT  cs.OriginationYear,
    CASE WHEN cr.MaxMOBObserved >= 6
         THEN ROUND(100.0 * cs.DefaultedByMOB6  / NULLIF(cs.CohortSize, 0), 2)
         ELSE NULL END AS DefaultRate_MOB6_Pct,
    CASE WHEN cr.MaxMOBObserved >= 12
         THEN ROUND(100.0 * cs.DefaultedByMOB12 / NULLIF(cs.CohortSize, 0), 2)
         ELSE NULL END AS DefaultRate_MOB12_Pct,
    CASE WHEN cr.MaxMOBObserved >= 18
         THEN ROUND(100.0 * cs.DefaultedByMOB18 / NULLIF(cs.CohortSize, 0), 2)
         ELSE NULL END AS DefaultRate_MOB18_Pct,
    CASE WHEN cr.MaxMOBObserved >= 24
         THEN ROUND(100.0 * cs.DefaultedByMOB24 / NULLIF(cs.CohortSize, 0), 2)
         ELSE NULL END AS DefaultRate_MOB24_Pct
FROM CohortSummary cs INNER JOIN CohortReach cr ON cs.OriginationYear = cr.OriginationYear ORDER BY cs.OriginationYear ASC;

-----------------------

select * from DimBorrower
select * from factloanapplication
select * from FactLoanPerformance



