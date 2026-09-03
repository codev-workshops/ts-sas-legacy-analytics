/*=====================================================================
  run_local_banking.sas — Standalone driver for the banking pipeline
  Purpose: Build the format catalogs, load the CSV seed data, then run
           the four banking programs in dependency order against local
           libraries only. The production orchestrator
           (BatchJobs/run_daily_banking.sas) does the same thing via
           Control-M and /opt/sas paths; this driver is the equivalent
           for a laptop, SAS OnDemand session or container.
  Submit:  sas -autoexec Config/autoexec_local.sas \
               -set SAS_REPO_ROOT <repo> -sysin Data/run_local_banking.sas
=====================================================================*/

%put NOTE: Running local banking pipeline for &CURR_DT;

/* Format catalogs must exist before any program formats a column */
%include "&REPO_ROOT/Formats/banking_formats.sas";

/* ORA_DW / RAW_BANK / CURATED stand-ins */
%include "&REPO_ROOT/Data/load_seed_data.sas";

/* Email is a no-op locally — see Data/local/sendmail.sas */
%include "&REPO_ROOT/Data/local/sendmail.sas";

%include "&REPO_ROOT/Programs/Banking/load_customer_accounts.sas";
%include "&REPO_ROOT/Programs/Banking/daily_transaction_processing.sas";
%include "&REPO_ROOT/Programs/Banking/credit_risk_scoring.sas";
%include "&REPO_ROOT/Programs/Banking/monthly_regulatory_reporting.sas";

/* ----------------------------------------------------------
   Run summary — the numbers to compare against a migrated
   target when validating a Snowflake / Databricks conversion
   ---------------------------------------------------------- */
proc sql;
  title "Local banking pipeline — output row counts (&CURR_DT)";
  select 'STG_BANK.CUST_ACCOUNTS_DAILY' as TABLE_NAME length=32,
         count(*) as N_ROWS from STG_BANK.CUST_ACCOUNTS_DAILY
  union all
  select 'STG_BANK.ACCT_EXCEPTIONS', count(*) from STG_BANK.ACCT_EXCEPTIONS
  union all
  select 'CURATED.DAILY_TRANSACTIONS', count(*) from CURATED.DAILY_TRANSACTIONS
  union all
  select 'CURATED.TXN_ANOMALIES', count(*) from CURATED.TXN_ANOMALIES
  union all
  select 'CURATED.RISK_SCORES', count(*) from CURATED.RISK_SCORES
  union all
  select 'REPORTS.MONTHLY_RWA', count(*) from REPORTS.MONTHLY_RWA
  union all
  select 'REPORTS.DELINQUENCY_AGING', count(*) from REPORTS.DELINQUENCY_AGING
  union all
  select 'REPORTS.LLP_COVERAGE', count(*) from REPORTS.LLP_COVERAGE
  ;
  title;
quit;
