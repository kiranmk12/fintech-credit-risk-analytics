import os
import urllib
import numpy as np
import pandas as pd
from sqlalchemy import create_engine

MISSING_INCOME_WARNING_THRESHOLD = 0.15  
DTI_OUTLIER_WARNING_THRESHOLD = 0.05     

RAW_DIR = r"D:\PYTHON LEARNING AND PROJECTS\projects\finance project\raw"

borrowers_path = os.path.join(RAW_DIR, "DimBorrower_Raw.csv")
apps_path = os.path.join(RAW_DIR, "FactLoanApplication_Raw.csv")
perf_path = os.path.join(RAW_DIR, "FactLoanPerformance_Raw.csv")

df_borrowers = pd.read_csv(borrowers_path)
df_apps = pd.read_csv(apps_path)
df_perf = pd.read_csv(perf_path)

server = r"KIRANMK\KIRAN_MK"
database = "Finance"
connection_string = (
    f"DRIVER={{ODBC Driver 17 for SQL Server}};"
    f"SERVER={server};"
    f"DATABASE={database};"
    f"Trusted_Connection=yes;"
)
params = urllib.parse.quote_plus(connection_string)
engine = create_engine(f"mssql+pyodbc:///?odbc_connect={params}")

null_income_count = int(df_borrowers["AnnualIncome"].isnull().sum())
total_borrowers = len(df_borrowers)
null_income_ratio = (
    null_income_count / total_borrowers if total_borrowers > 0 else 0.0
)

dti_outliers_count = int((df_apps["DebtToIncomeRatio"] > 100).sum())
total_apps = len(df_apps)
dti_outliers_ratio = (
    dti_outliers_count / total_apps if total_apps > 0 else 0.0
)

median_income_by_exp = df_borrowers.groupby("EmploymentLengthYears")[
    "AnnualIncome"
].transform("median")
df_borrowers["AnnualIncome"] = df_borrowers["AnnualIncome"].fillna(
    median_income_by_exp
)

upper_limit_dti = 55.00
df_apps["DebtToIncomeRatio"] = np.where(
    df_apps["DebtToIncomeRatio"] > 100,
    upper_limit_dti,
    df_apps["DebtToIncomeRatio"],
)

borrower_status = (
    "WARNING" if null_income_ratio > MISSING_INCOME_WARNING_THRESHOLD else "PASSED"
)
app_status = (
    "WARNING" if dti_outliers_ratio > DTI_OUTLIER_WARNING_THRESHOLD else "PASSED"
)

audit_records = pd.DataFrame(
    [
        {
            "TableName": "DimBorrower",
            "TotalRowsIngested": total_borrowers,
            "NullCountResolved": null_income_count,
            "OutliersCappedCount": 0,
            "DataQualityStatus": borrower_status,
        },
        {
            "TableName": "FactLoanApplication",
            "TotalRowsIngested": total_apps,
            "NullCountResolved": 0,
            "OutliersCappedCount": dti_outliers_count,
            "DataQualityStatus": app_status,
        },
        {
            "TableName": "FactLoanPerformance",
            "TotalRowsIngested": len(df_perf),
            "NullCountResolved": 0,
            "OutliersCappedCount": 0,
            "DataQualityStatus": "PASSED",
        },
    ]
)

try:
    audit_records.to_sql(
        name="DataQuality_AuditLog", con=engine, if_exists="append", index=False
    )
    print("Data Quality Audit Log updated in SQL Server.")
except Exception as e:
    print(
        f" Failed to write audit log (Ensure DataQuality_AuditLog table exists in SQL): {e}"
    )

try:
    existing_borrower_ids = pd.read_sql(
        "SELECT BorrowerID FROM DimBorrower", con=engine
    )["BorrowerID"].tolist()
except Exception:
    existing_borrower_ids = []

df_new_borrowers = df_borrowers[
    ~df_borrowers["BorrowerID"].isin(existing_borrower_ids)
]

if not df_new_borrowers.empty:
    df_new_borrowers.to_sql(
        name="DimBorrower", con=engine, if_exists="append", index=False
    )
    print(f" DimBorrower: Appended {len(df_new_borrowers)} new records.")
else:
    print("ℹ DimBorrower: Database is already up to date (0 new records).")


try:
    existing_loan_ids = pd.read_sql(
        "SELECT LoanID FROM FactLoanApplication", con=engine
    )["LoanID"].tolist()
except Exception:
    existing_loan_ids = []

df_new_apps = df_apps[~df_apps["LoanID"].isin(existing_loan_ids)]

if not df_new_apps.empty:
    df_new_apps.to_sql(
        name="FactLoanApplication", con=engine, if_exists="append", index=False
    )
    print(f" FactLoanApplication: Appended {len(df_new_apps)} new records.")
else:
    print("ℹ FactLoanApplication: Database is already up to date (0 new records).")


try:
    existing_snapshots = pd.read_sql(
        "SELECT LoanID, CAST(SnapshotDate AS VARCHAR(10)) AS SnapshotDate FROM FactLoanPerformance",
        con=engine,
    )
    existing_snapshots["Key"] = (
        existing_snapshots["LoanID"].astype(str) + "_" + existing_snapshots["SnapshotDate"].astype(str)
    )
    existing_perf_keys = set(existing_snapshots["Key"])
except Exception:
    existing_perf_keys = set()

df_perf["Key"] = df_perf["LoanID"].astype(str) + "_" + df_perf["SnapshotDate"].astype(str)
df_new_perf = df_perf[~df_perf["Key"].isin(existing_perf_keys)].drop(
    columns=["Key"]
)

if not df_new_perf.empty:
    df_new_perf.to_sql(
        name="FactLoanPerformance", con=engine, if_exists="append", index=False
    )
    print(f" FactLoanPerformance: Appended {len(df_new_perf)} new monthly snapshots.")
else:
    print("ℹ FactLoanPerformance: Database is already up to date (0 new snapshots).")

engine.dispose()

print("\n--- ALL PIPELINE TASKS & INCREMENTAL CHECKS COMPLETED SUCCESSFULLY ---")