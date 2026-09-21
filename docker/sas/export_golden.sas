/*=====================================================================
  export_golden.sas — Write the banking pipeline outputs as "golden" CSVs
  Purpose: After Data/run_local_banking.sas has run, dump every output
           table the migration must reproduce, plus a row-count summary,
           to &GOLDEN_ROOT (default /data/sas/golden). The migration
           repository's reconciliation harness compares its Databricks
           tables against these files.
  Submit:  sas -autoexec Config/autoexec_local.sas \
               -sysin docker/sas/export_golden.sas
  Note:    Read-only with respect to the estate: it only SELECTs from the
           libraries the programs wrote.
=====================================================================*/

%let GOLDEN_ROOT = %sysget(SAS_GOLDEN_ROOT);
%if %length(&GOLDEN_ROOT) = 0 %then %let GOLDEN_ROOT = &DATA_ROOT/golden;

%macro golden(lib, member);
  proc export data=&lib..&member
       outfile="&GOLDEN_ROOT/%lowcase(&lib)__%lowcase(&member).csv"
       dbms=csv replace;
  run;
  proc sql noprint;
    select count(*) into :_n trimmed from &lib..&member;
  quit;
  %put NOTE: [golden] &lib..&member -> &GOLDEN_ROOT/%lowcase(&lib)__%lowcase(&member).csv (&_n rows);
%mend golden;

%golden(STG_BANK, CUST_ACCOUNTS_DAILY)
%golden(STG_BANK, ACCT_EXCEPTIONS)
%golden(CURATED,  DAILY_TRANSACTIONS)
%golden(CURATED,  TXN_ANOMALIES)
%golden(CURATED,  RISK_SCORES)
%golden(REPORTS,  MONTHLY_RWA)
%golden(REPORTS,  DELINQUENCY_AGING)
%golden(REPORTS,  LLP_COVERAGE)

/* Row counts — the first thing the reconciliation checks */
proc sql;
  create table work.golden_counts as
  select 'STG_BANK.CUST_ACCOUNTS_DAILY' as TABLE_NAME length=32,
         count(*) as N_ROWS from STG_BANK.CUST_ACCOUNTS_DAILY
  union all select 'STG_BANK.ACCT_EXCEPTIONS',  count(*) from STG_BANK.ACCT_EXCEPTIONS
  union all select 'CURATED.DAILY_TRANSACTIONS', count(*) from CURATED.DAILY_TRANSACTIONS
  union all select 'CURATED.TXN_ANOMALIES',      count(*) from CURATED.TXN_ANOMALIES
  union all select 'CURATED.RISK_SCORES',        count(*) from CURATED.RISK_SCORES
  union all select 'REPORTS.MONTHLY_RWA',        count(*) from REPORTS.MONTHLY_RWA
  union all select 'REPORTS.DELINQUENCY_AGING',  count(*) from REPORTS.DELINQUENCY_AGING
  union all select 'REPORTS.LLP_COVERAGE',       count(*) from REPORTS.LLP_COVERAGE
  ;
quit;
proc export data=work.golden_counts outfile="&GOLDEN_ROOT/row_counts.csv" dbms=csv replace; run;

/* Anomaly mix and the control totals the regulatory report is judged on */
proc sql;
  create table work.golden_controls as
  select 'TXN_ANOMALIES.HIGH_AMOUNT' as CONTROL length=40, count(*) as VALUE
    from CURATED.TXN_ANOMALIES where ANOMALY_TYPE = 'HIGH_AMOUNT'
  union all select 'TXN_ANOMALIES.OVERDRAFT', count(*)
    from CURATED.TXN_ANOMALIES where ANOMALY_TYPE = 'OVERDRAFT'
  union all select 'DAILY_TRANSACTIONS.SUM_AMOUNT', round(sum(TRANSACTION_AMOUNT), 0.01)
    from CURATED.DAILY_TRANSACTIONS
  union all select 'RISK_SCORES.N_ACCOUNTS', count(*) from CURATED.RISK_SCORES
  union all select 'MONTHLY_RWA.SUM_RWA', round(sum(RWA), 0.01) from REPORTS.MONTHLY_RWA
  ;
quit;
proc export data=work.golden_controls outfile="&GOLDEN_ROOT/controls.csv" dbms=csv replace; run;

%put NOTE: [golden] export complete -> &GOLDEN_ROOT;
