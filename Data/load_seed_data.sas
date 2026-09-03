/*=====================================================================
  load_seed_data.sas — Seed the local libraries from Data/csv
  Purpose: Read the CSV extracts in Data/csv into the BASE libraries
           declared by Config/autoexec_local.sas, so that the banking
           programs find the same members and columns they expect from
           Oracle (ORA_DW), the daily feed (RAW_BANK) and the curated
           history (CURATED).
  Inputs:  &REPO_ROOT/Data/csv/{oracle_dw,raw_bank,curated}/*.csv
  Outputs: ORA_DW.CUST_ACCOUNTS, ORA_DW.CUST_DEMOGRAPHICS,
           ORA_DW.BUREAU_SCORES, ORA_DW.PAYMENT_HISTORY,
           ORA_DW.COLLATERAL, ORA_DW.LOAN_DETAILS,
           RAW_BANK.TXN_FEED_20240131, RAW_BANK.DAILY_RATES,
           CURATED.DAILY_TRANSACTIONS,
           STG_BANK.ACCT_EXCEPTIONS (empty shell)
  Prereq:  %include the format catalogs first (see Data/README.md)
=====================================================================*/

%let CSV_ROOT = &REPO_ROOT/Data/csv;

%put NOTE: Loading seed data from &CSV_ROOT;

/* ----------------------------------------------------------
   ORA_DW.CUST_DEMOGRAPHICS
   ---------------------------------------------------------- */
data ORA_DW.CUST_DEMOGRAPHICS(label="Customer Demographics");
  infile "&CSV_ROOT/oracle_dw/CUST_DEMOGRAPHICS.csv"
    dsd dlm=',' firstobs=2 truncover;
  length CUSTOMER_ID $10 FIRST_NAME $30 LAST_NAME $30 SSN_HASH $32
         CUSTOMER_SEGMENT $4 REGION_CODE $2 PRIMARY_EMAIL $80 PHONE_NUMBER $16;
  informat DATE_OF_BIRTH date9.;
  format DATE_OF_BIRTH date9. RISK_RATING RISKRATE. CUSTOMER_SEGMENT $CUSTSEG.
         REGION_CODE $REGION.;
  input CUSTOMER_ID $ FIRST_NAME $ LAST_NAME $ SSN_HASH $ DATE_OF_BIRTH
        CUSTOMER_SEGMENT $ RISK_RATING REGION_CODE $ PRIMARY_EMAIL $
        PHONE_NUMBER $;
run;

/* ----------------------------------------------------------
   ORA_DW.CUST_ACCOUNTS
   ---------------------------------------------------------- */
data ORA_DW.CUST_ACCOUNTS(label="Customer Accounts");
  infile "&CSV_ROOT/oracle_dw/CUST_ACCOUNTS.csv"
    dsd dlm=',' firstobs=2 truncover;
  length ACCOUNT_ID $12 CUSTOMER_ID $10 ACCOUNT_TYPE $4 ACCOUNT_STATUS $1
         BRANCH_ID $6 OFFICER_ID $6;
  informat OPEN_DATE CLOSE_DATE LAST_ACTIVITY_DATE date9.;
  format OPEN_DATE CLOSE_DATE LAST_ACTIVITY_DATE date9.
         CURRENT_BALANCE AVAILABLE_BALANCE CREDIT_LIMIT dollar18.2
         ACCOUNT_TYPE $ACCTTYPE. ACCOUNT_STATUS $ACCTSTAT.;
  input ACCOUNT_ID $ CUSTOMER_ID $ ACCOUNT_TYPE $ ACCOUNT_STATUS $ OPEN_DATE
        CLOSE_DATE CURRENT_BALANCE AVAILABLE_BALANCE CREDIT_LIMIT
        INTEREST_RATE BRANCH_ID $ OFFICER_ID $ LAST_ACTIVITY_DATE;
run;

/* ----------------------------------------------------------
   ORA_DW.BUREAU_SCORES
   ---------------------------------------------------------- */
data ORA_DW.BUREAU_SCORES(label="Credit Bureau Scores");
  infile "&CSV_ROOT/oracle_dw/BUREAU_SCORES.csv"
    dsd dlm=',' firstobs=2 truncover;
  length CUSTOMER_ID $10;
  informat SCORE_DATE date9.;
  format SCORE_DATE date9.;
  input CUSTOMER_ID $ SCORE_DATE FICO_SCORE VANTAGE_SCORE BUREAU_INQS_6MO
        BUREAU_TRADES_OPEN BUREAU_DEROGS BUREAU_UTIL_PCT BUREAU_OLDEST_TRADE_MO;
run;

/* ----------------------------------------------------------
   ORA_DW.PAYMENT_HISTORY
   ---------------------------------------------------------- */
data ORA_DW.PAYMENT_HISTORY(label="Account Payment Behaviour");
  infile "&CSV_ROOT/oracle_dw/PAYMENT_HISTORY.csv"
    dsd dlm=',' firstobs=2 truncover;
  length ACCOUNT_ID $12;
  input ACCOUNT_ID $ PMT_ONTIME_12MO PMT_LATE_30_12MO PMT_LATE_60_12MO
        PMT_LATE_90_12MO MAX_DAYS_PAST_DUE_EVER MONTHS_SINCE_LAST_DPD
        AVG_PMT_RATIO_12MO;
run;

/* ----------------------------------------------------------
   ORA_DW.COLLATERAL
   ---------------------------------------------------------- */
data ORA_DW.COLLATERAL(label="Secured Loan Collateral");
  infile "&CSV_ROOT/oracle_dw/COLLATERAL.csv"
    dsd dlm=',' firstobs=2 truncover;
  length ACCOUNT_ID $12;
  informat LAST_APPRAISAL_DATE date9.;
  format LAST_APPRAISAL_DATE date9. COLLATERAL_VALUE dollar18.2;
  input ACCOUNT_ID $ COLLATERAL_VALUE LAST_APPRAISAL_DATE;
run;

/* ----------------------------------------------------------
   ORA_DW.LOAN_DETAILS
   ---------------------------------------------------------- */
data ORA_DW.LOAN_DETAILS(label="Loan Servicing Detail");
  infile "&CSV_ROOT/oracle_dw/LOAN_DETAILS.csv"
    dsd dlm=',' firstobs=2 truncover;
  length ACCOUNT_ID $12 LOAN_PURPOSE $8;
  informat ORIG_DATE date9.;
  format ORIG_DATE date9. ORIG_AMOUNT PAST_DUE_AMOUNT ALLOWANCE_AMT dollar18.2
         LOAN_PURPOSE $LNPURP. DAYS_PAST_DUE DELQBKT. LTV 8.4;
  input ACCOUNT_ID $ LOAN_PURPOSE $ ORIG_AMOUNT ORIG_DATE TERM_MONTHS LTV
        DAYS_PAST_DUE PAST_DUE_AMOUNT ALLOWANCE_AMT;
run;

/* ----------------------------------------------------------
   RAW_BANK.TXN_FEED_YYYYMMDD — the daily flat-file landing table
   ---------------------------------------------------------- */
%macro load_txn(lib=, member=, path=, label=);
  data &lib..&member(label="&label");
    infile "&path" dsd dlm=',' firstobs=2 truncover;
    length TRANSACTION_ID $12 ACCOUNT_ID $12 TRANSACTION_TYPE $4 CHANNEL $8
           MERCHANT_CATEGORY $4 DESCRIPTION $60 CURRENCY_CODE $3;
    informat TRANSACTION_DATE POST_DATE date9.;
    format TRANSACTION_DATE POST_DATE date9. TRANSACTION_AMOUNT dollar18.2
           TRANSACTION_TYPE $TXNCAT.;
    input TRANSACTION_ID $ ACCOUNT_ID $ TRANSACTION_DATE TRANSACTION_TYPE $
          TRANSACTION_AMOUNT CHANNEL $ MERCHANT_CATEGORY $ DESCRIPTION $
          POST_DATE CURRENCY_CODE $;
  run;
%mend load_txn;

%load_txn(lib=RAW_BANK, member=TXN_FEED_20240131,
          path=&CSV_ROOT/raw_bank/TXN_FEED_20240131.csv,
          label=Daily Transaction Feed 31JAN2024)

/* 90 days of prior activity — the baseline the anomaly z-scores read */
%load_txn(lib=CURATED, member=DAILY_TRANSACTIONS,
          path=&CSV_ROOT/curated/DAILY_TRANSACTIONS.csv,
          label=Curated Daily Transactions History)

/* ----------------------------------------------------------
   RAW_BANK.DAILY_RATES
   ---------------------------------------------------------- */
data RAW_BANK.DAILY_RATES(label="Daily Reference Rates");
  infile "&CSV_ROOT/raw_bank/DAILY_RATES.csv"
    dsd dlm=',' firstobs=2 truncover;
  length RATE_TYPE $12;
  informat RATE_DATE date9.;
  format RATE_DATE date9. RATE_VALUE percent10.4;
  input RATE_DATE RATE_TYPE $ RATE_VALUE;
run;

/* ----------------------------------------------------------
   Empty shells the programs append to on first run
   ---------------------------------------------------------- */
data STG_BANK.ACCT_EXCEPTIONS(label="Account Data Quality Exceptions");
  length ACCOUNT_ID $12 CUSTOMER_ID $10 EXCEPTION_CODE $10 EXCEPTION_DESC $200;
  format SNAPSHOT_DATE date9.;
  stop;
run;

proc sql noprint;
  select count(*) into :n_accounts trimmed from ORA_DW.CUST_ACCOUNTS;
  select count(*) into :n_feed     trimmed from RAW_BANK.TXN_FEED_20240131;
  select count(*) into :n_hist     trimmed from CURATED.DAILY_TRANSACTIONS;
quit;

%put NOTE: ============================================;
%put NOTE: Seed data loaded;
%put NOTE: ORA_DW.CUST_ACCOUNTS: &n_accounts rows;
%put NOTE: RAW_BANK.TXN_FEED_20240131: &n_feed rows;
%put NOTE: CURATED.DAILY_TRANSACTIONS: &n_hist rows;
%put NOTE: ============================================;
