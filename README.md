# Legacy SAS Analytics Environment

A representative enterprise SAS codebase for banking and insurance analytics. This repository models the type of SAS estate that organizations typically need to assess and migrate to modern platforms (dbt, Databricks, Snowflake, Python).

## Repository Structure

```
├── Config/
│   ├── autoexec.sas              # Global environment: LIBNAMEs, macro vars, DB connections
│   └── autoexec_local.sas        # Same contract with local libraries instead of Oracle/Teradata
├── Data/                         # Banking seed data — lets the estate run standalone
│   ├── csv/                      # Oracle DW extracts, daily feed, 90-day curated history
│   ├── generate_seed_data.py     # Deterministic regeneration
│   ├── validate_seed_data.py     # Checks the data against the programs' assumptions
│   ├── load_seed_data.sas        # CSV -> ORA_DW / RAW_BANK / CURATED
│   ├── run_local_banking.sas     # Formats -> load -> four banking programs -> row counts
│   └── bootstrap_local_env.sh    # Creates /data/sas and /opt/sas/custom, then runs the pipeline
├── Formats/
│   ├── banking_formats.sas       # Custom formats: account types, risk ratings, delinquency
│   └── insurance_formats.sas     # Custom formats: policy types, claim status, coverage
├── Macro/                        # 92 reusable SAS macros (utility library)
│   ├── parmv.sas                 # Parameter validation
│   ├── nobs.sas                  # Observation counter
│   ├── lock.sas                  # Dataset locking
│   ├── sendmail.sas              # Email notifications
│   ├── export_xlsx.sas           # Excel export
│   ├── logparse.sas              # Log file parser
│   └── ...                       # 86 more utility macros
├── Programs/
│   ├── Banking/
│   │   ├── load_customer_accounts.sas      # Daily account snapshot from Oracle DW
│   │   ├── daily_transaction_processing.sas # Transaction ETL with anomaly detection
│   │   ├── credit_risk_scoring.sas         # PD/LGD/EAD model execution (Basel III)
│   │   └── monthly_regulatory_reporting.sas # RWA, capital adequacy, delinquency aging
│   ├── Insurance/
│   │   ├── claims_processing.sas           # Claims intake, fraud screening, auto-adjudication
│   │   └── policy_valuation.sas            # Policy book valuation, loss ratios, IBNR
│   └── Reports/
│       └── customer_profitability.sas      # Customer P&L, segment/branch profitability
├── BatchJobs/
│   ├── run_daily_banking.sas     # Master batch orchestrator — banking ETL pipeline
│   └── run_daily_insurance.sas   # Master batch orchestrator — insurance pipeline
├── Logs/                         # Sample production log files
│   ├── load_customer_accounts_20240115.log
│   └── daily_transaction_processing_20240115.log
├── EGProjects/                   # Enterprise Guide project files (.egp)
├── AMO/                          # Deployment packages (.spk)
└── Presentations/                # SNUG conference materials
```

## SAS Constructs Used

This codebase exercises the full range of SAS features that migration tools need to handle:

| Construct | Where Used | Migration Target |
|-----------|-----------|-----------------|
| `DATA` steps with business logic | All Programs/ | dbt models (SQL) or Python transforms |
| `PROC SQL` with joins, subqueries, CASE | Banking, Insurance, Reports | Databricks SQL / dbt SQL |
| `%MACRO` / `%MEND` with parameters | All programs, 92 Macro/ utilities | dbt macros, Python functions |
| `PROC MEANS` / `PROC FREQ` | Reports, regulatory | Databricks SQL aggregations |
| `PROC APPEND` with locking | Transaction processing | Delta Lake MERGE operations |
| `PROC FORMAT` (custom formats) | Formats/ directory | dbt seed tables + CASE expressions |
| `PROC EXPORT` to Excel | Regulatory reporting | Databricks notebooks / Python openpyxl |
| Hash objects (`declare hash`) | Claims processing | Python dicts / Spark broadcast joins |
| `LIBNAME` to Oracle, Teradata | autoexec.sas | Databricks external tables / Unity Catalog |
| `%INCLUDE` chains | Batch orchestrators | dbt `ref()` / Databricks Workflows |
| `RETAIN` / `BY` group processing | Running balances | Window functions (LAG/LEAD) |
| Macro variable resolution (`&var`) | Throughout | dbt vars / Jinja templating |
| Error handling (`%GOTO`, `SYSERR`) | Batch orchestrators | dbt on-run-end hooks / Workflows |
| Email notifications (`%sendmail`) | Exception handling | Databricks alerts / PagerDuty |

## Running the Banking Pipeline Standalone

The programs are unmodified production code, so they read from Oracle and write to
`/data/sas`. `Data/` supplies those inputs as CSV and recreates the paths, which is
enough to run the whole daily banking chain on Base SAS with no warehouse:

```bash
./Data/bootstrap_local_env.sh
```

This builds the format catalog, loads `ORA_DW` / `RAW_BANK` / `CURATED` from
`Data/csv/`, runs `load_customer_accounts` → `daily_transaction_processing` →
`credit_risk_scoring` → `monthly_regulatory_reporting` for business date
31JAN2024, and prints the output row counts to reconcile a migrated target
against. The data is seeded to trip every exception, reject and anomaly branch in
the code. See [Data/README.md](Data/README.md).

## External Dependencies

Production dependencies. Each is either stubbed or seeded from `Data/` when the
pipeline runs standalone.

- **Oracle DW** (`ORA_DW`): Customer demographics, loan details, bureau scores, collateral, payment history, cost of funds
- **Teradata Analytics** (`TERA_DW`): Actuarial tables, fraud indicators
- **File-based feeds**: Daily transaction and claims flat files (CSV/fixed-width)
- **Control-M**: Job scheduling and dependency management
- **Email (SMTP)**: Operational alerts and batch status notifications

## License

This macro library is released under the [Unlicense](UNLICENSE.txt). The banking and insurance programs are original content created for migration analysis exercises.
