/*=====================================================================
  daily_transaction_processing.sas — Transaction ETL Pipeline
  Purpose: Ingest daily transaction feed, validate, classify,
           compute running balances, detect anomalies, and load
           to curated layer.
  Inputs:  RAW_BANK.TXN_FEED_YYYYMMDD (daily flat file load),
           STG_BANK.CUST_ACCOUNTS_DAILY, BANKING.FORMATS
  Outputs: CURATED.DAILY_TRANSACTIONS, CURATED.TXN_ANOMALIES,
           CURATED.RUNNING_BALANCES
  Schedule: Daily 07:30 via Control-M job BANK_DAILY_02
  Depends: load_customer_accounts.sas (BANK_DAILY_01)
  Last Modified: 2024-01-14
=====================================================================*/

%include "/opt/sas/custom/macros/parmv.sas";
%include "/opt/sas/custom/macros/nobs.sas";
%include "/opt/sas/custom/macros/lock.sas";

%macro daily_transaction_processing(txn_date=&CURR_DT);

  %parmv(txn_date, _req=1)

  %local txn_ds nobs_feed nobs_valid nobs_anom start_tm;
  %let start_tm = %sysfunc(datetime());
  %let txn_ds = TXN_FEED_%sysfunc(putn("&txn_date"d, yymmddn8.));

  %put NOTE: ============================================;
  %put NOTE: daily_transaction_processing started;
  %put NOTE: Transaction Date: &txn_date;
  %put NOTE: Source Dataset: RAW_BANK.&txn_ds;
  %put NOTE: ============================================;

  /* ----------------------------------------------------------
     Step 1: Validate Incoming Feed
     ---------------------------------------------------------- */
  %if %sysfunc(exist(RAW_BANK.&txn_ds)) = 0 %then %do;
    %put ERROR: Feed dataset RAW_BANK.&txn_ds not found;
    %put ERROR: Check upstream file transfer for &txn_date;
    %goto ABORT;
  %end;

  %let nobs_feed = %nobs(RAW_BANK.&txn_ds);
  %put NOTE: Feed record count: &nobs_feed;

  data WORK.TXN_VALIDATED(label="Validated Transactions")
       WORK.TXN_REJECTED(label="Rejected Transactions");

    set RAW_BANK.&txn_ds;

    length REJECT_REASON $200;

    /* Validation: Required fields */
    if missing(TRANSACTION_ID) then do;
      REJECT_REASON = 'Missing TRANSACTION_ID';
      output WORK.TXN_REJECTED;
      return;
    end;

    if missing(ACCOUNT_ID) then do;
      REJECT_REASON = 'Missing ACCOUNT_ID';
      output WORK.TXN_REJECTED;
      return;
    end;

    if missing(TRANSACTION_AMOUNT) then do;
      REJECT_REASON = 'Missing TRANSACTION_AMOUNT';
      output WORK.TXN_REJECTED;
      return;
    end;

    /* Validation: Amount range */
    if abs(TRANSACTION_AMOUNT) > 10000000 then do;
      REJECT_REASON = catx(' ', 'Amount exceeds threshold:',
        put(TRANSACTION_AMOUNT, dollar18.2));
      output WORK.TXN_REJECTED;
      return;
    end;

    /* Validation: Valid transaction type */
    if TRANSACTION_TYPE not in ('DEP','WDR','TRF','PMT','FEE','INT','ADJ','REV','CHG','REF')
    then do;
      REJECT_REASON = catx(' ', 'Invalid transaction type:', TRANSACTION_TYPE);
      output WORK.TXN_REJECTED;
      return;
    end;

    /* Validation: Future-dated check */
    if TRANSACTION_DATE > "&txn_date"d then do;
      REJECT_REASON = catx(' ', 'Future dated:',
        put(TRANSACTION_DATE, date9.));
      output WORK.TXN_REJECTED;
      return;
    end;

    output WORK.TXN_VALIDATED;
    drop REJECT_REASON;
  run;

  %let nobs_valid = %nobs(WORK.TXN_VALIDATED);
  %put NOTE: Validated: &nobs_valid of &nobs_feed;

  /* ----------------------------------------------------------
     Step 2: Enrich with Account and Customer Data
     ---------------------------------------------------------- */
  proc sql;
    create table WORK.TXN_ENRICHED as
    select
      t.*,
      a.ACCOUNT_TYPE,
      a.CUSTOMER_ID,
      a.CUSTOMER_SEGMENT,
      a.REGION_CODE,
      a.BRANCH_ID,
      a.CURRENT_BALANCE as PRE_TXN_BALANCE,
      case
        when t.TRANSACTION_TYPE in ('DEP','INT','REF','REV')
          then a.CURRENT_BALANCE + t.TRANSACTION_AMOUNT
        when t.TRANSACTION_TYPE in ('WDR','PMT','FEE','CHG')
          then a.CURRENT_BALANCE - abs(t.TRANSACTION_AMOUNT)
        when t.TRANSACTION_TYPE in ('TRF','ADJ')
          then a.CURRENT_BALANCE + t.TRANSACTION_AMOUNT
        else a.CURRENT_BALANCE
      end as POST_TXN_BALANCE format=dollar18.2,
      a.RISK_RATING
    from WORK.TXN_VALIDATED t
    left join STG_BANK.CUST_ACCOUNTS_DAILY a
      on t.ACCOUNT_ID = a.ACCOUNT_ID
    order by t.ACCOUNT_ID, t.TRANSACTION_DATE, t.TRANSACTION_ID
    ;
  quit;

  /* ----------------------------------------------------------
     Step 3: Running Balance Calculation
     Compute cumulative balance before anomaly detection so
     OVERDRAFT checks use correct multi-transaction balances.
     ---------------------------------------------------------- */
  data WORK.TXN_WITH_BALANCE;
    set WORK.TXN_ENRICHED;
    by ACCOUNT_ID TRANSACTION_DATE TRANSACTION_ID;

    retain RUNNING_BALANCE;

    if first.ACCOUNT_ID then
      RUNNING_BALANCE = PRE_TXN_BALANCE;

    if TRANSACTION_TYPE in ('DEP','INT','REF','REV') then
      RUNNING_BALANCE = RUNNING_BALANCE + TRANSACTION_AMOUNT;
    else if TRANSACTION_TYPE in ('WDR','PMT','FEE','CHG') then
      RUNNING_BALANCE = RUNNING_BALANCE - abs(TRANSACTION_AMOUNT);
    else if TRANSACTION_TYPE in ('TRF','ADJ') then
      RUNNING_BALANCE = RUNNING_BALANCE + TRANSACTION_AMOUNT;

    format RUNNING_BALANCE dollar18.2;
  run;

  /* ----------------------------------------------------------
     Step 4: Anomaly Detection (uses cumulative RUNNING_BALANCE)
     ---------------------------------------------------------- */
  proc sql;
    create table WORK.TXN_STATS as
    select
      ACCOUNT_ID,
      mean(abs(TRANSACTION_AMOUNT)) as AVG_TXN_AMT,
      std(abs(TRANSACTION_AMOUNT))  as STD_TXN_AMT,
      count(*) as TXN_COUNT
    from CURATED.DAILY_TRANSACTIONS
    where TRANSACTION_DATE >= intnx('day', "&txn_date"d, -90)
    group by ACCOUNT_ID
    ;
  quit;

  proc sql;
    create table WORK.TXN_ANOMALIES as
    select
      e.*,
      s.AVG_TXN_AMT,
      s.STD_TXN_AMT,
      case
        when s.STD_TXN_AMT > 0
          then (abs(e.TRANSACTION_AMOUNT) - s.AVG_TXN_AMT) / s.STD_TXN_AMT
        else .
      end as Z_SCORE,
      case
        when calculated Z_SCORE > 3 then 'HIGH_AMOUNT'
        when e.RUNNING_BALANCE < 0 then 'OVERDRAFT'
        when e.TRANSACTION_TYPE = 'WDR'
          and abs(e.TRANSACTION_AMOUNT) > e.PRE_TXN_BALANCE * 0.9
          then 'LARGE_WITHDRAWAL'
        when missing(e.CUSTOMER_ID) then 'ORPHAN_ACCOUNT'
        else ''
      end as ANOMALY_TYPE length=20
    from WORK.TXN_WITH_BALANCE e
    left join WORK.TXN_STATS s
      on e.ACCOUNT_ID = s.ACCOUNT_ID
    having ANOMALY_TYPE ne ''
    ;
  quit;

  %let nobs_anom = %nobs(WORK.TXN_ANOMALIES);
  %put NOTE: Anomalies detected: &nobs_anom;

  /* ----------------------------------------------------------
     Step 5: Load to Curated Layer
     ---------------------------------------------------------- */
  %lock(CURATED.DAILY_TRANSACTIONS);

  proc append base=CURATED.DAILY_TRANSACTIONS
              data=WORK.TXN_WITH_BALANCE force;
  run;

  %lock(CURATED.DAILY_TRANSACTIONS, unlock);

  %if &nobs_anom > 0 %then %do;
    proc append base=CURATED.TXN_ANOMALIES
                data=WORK.TXN_ANOMALIES force;
    run;
  %end;

  /* ----------------------------------------------------------
     Step 6: Persist Running Balances
     ---------------------------------------------------------- */
  data CURATED.RUNNING_BALANCES;
    set WORK.TXN_WITH_BALANCE;
    keep ACCOUNT_ID TRANSACTION_DATE TRANSACTION_ID RUNNING_BALANCE;
  run;

  %put NOTE: ============================================;
  %put NOTE: daily_transaction_processing completed;
  %put NOTE: Feed: &nobs_feed | Valid: &nobs_valid | Anomalies: &nobs_anom;
  %put NOTE: Duration: %sysfunc(putn(%sysevalf(%sysfunc(datetime())-&start_tm), time8.));
  %put NOTE: ============================================;

  %goto EXIT;

  %ABORT:
  %put ERROR: daily_transaction_processing ABORTED;

  %EXIT:

  proc datasets lib=WORK nolist;
    delete TXN_VALIDATED TXN_REJECTED TXN_ENRICHED TXN_WITH_BALANCE TXN_STATS TXN_ANOMALIES;
  quit;

%mend daily_transaction_processing;

%daily_transaction_processing(txn_date=&CURR_DT);
