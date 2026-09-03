/*=====================================================================
  load_customer_accounts.sas — Daily Customer Account Snapshot
  Purpose: Extract customer account data from Oracle DW, apply
           business rules, compute derived metrics, and load
           into the staging layer for downstream reporting.
  Inputs:  ORA_DW.CUST_ACCOUNTS, ORA_DW.CUST_DEMOGRAPHICS,
           RAW_BANK.DAILY_RATES
  Outputs: STG_BANK.CUST_ACCOUNTS_DAILY, STG_BANK.ACCT_EXCEPTIONS
  Schedule: Daily 06:00 via Control-M job BANK_DAILY_01
  Last Modified: 2024-01-14
=====================================================================*/

%include "/opt/sas/custom/macros/parmv.sas";
%include "/opt/sas/custom/macros/nobs.sas";
%include "/opt/sas/custom/macros/lock.sas";

%macro load_customer_accounts(run_date=&CURR_DT, region=ALL);

  %parmv(run_date, _req=1, _msg=Run date is required)
  %parmv(region,   _req=0, _val=ALL NE SE MW SW W NW)

  %local dsid nobs_raw nobs_out nobs_except start_tm;
  %let start_tm = %sysfunc(datetime());

  %put NOTE: ============================================;
  %put NOTE: load_customer_accounts started;
  %put NOTE: Run Date: &run_date;
  %put NOTE: Region Filter: &region;
  %put NOTE: ============================================;

  /* ----------------------------------------------------------
     Step 1: Extract from Oracle — Customer Account Base
     ---------------------------------------------------------- */
  proc sql;
    create table WORK.ACCT_RAW as
    select
      a.ACCOUNT_ID,
      a.CUSTOMER_ID,
      a.ACCOUNT_TYPE,
      a.ACCOUNT_STATUS,
      a.OPEN_DATE,
      a.CLOSE_DATE,
      a.CURRENT_BALANCE,
      a.AVAILABLE_BALANCE,
      a.CREDIT_LIMIT,
      a.INTEREST_RATE,
      a.BRANCH_ID,
      a.OFFICER_ID,
      a.LAST_ACTIVITY_DATE,
      d.FIRST_NAME,
      d.LAST_NAME,
      d.SSN_HASH,
      d.DATE_OF_BIRTH,
      d.CUSTOMER_SEGMENT,
      d.RISK_RATING,
      d.REGION_CODE,
      d.PRIMARY_EMAIL,
      d.PHONE_NUMBER
    from ORA_DW.CUST_ACCOUNTS a
    inner join ORA_DW.CUST_DEMOGRAPHICS d
      on a.CUSTOMER_ID = d.CUSTOMER_ID
    where a.ACCOUNT_STATUS not in ('W', 'C')
      and a.OPEN_DATE <= "&run_date"d
      %if &region ne ALL %then %do;
        and d.REGION_CODE = "&region"
      %end;
    order by a.CUSTOMER_ID, a.ACCOUNT_ID
    ;
  quit;

  %let nobs_raw = %nobs(WORK.ACCT_RAW);
  %put NOTE: Raw extract rows: &nobs_raw;

  %if &nobs_raw = 0 %then %do;
    %put WARNING: No records extracted. Aborting.;
    %goto EXIT;
  %end;

  /* ----------------------------------------------------------
     Step 2: Apply Business Rules and Derive Metrics
     ---------------------------------------------------------- */
  data STG_BANK.CUST_ACCOUNTS_DAILY(label="Daily Customer Account Snapshot")
       WORK.ACCT_EXCEPTIONS(label="Account Data Quality Exceptions");

    set WORK.ACCT_RAW;

    format ACCOUNT_TYPE $ACCTTYPE.
           ACCOUNT_STATUS $ACCTSTAT.
           RISK_RATING RISKRATE.
           CUSTOMER_SEGMENT $CUSTSEG.
           REGION_CODE $REGION.
           CURRENT_BALANCE AVAILABLE_BALANCE CREDIT_LIMIT
             dollar18.2
           OPEN_DATE CLOSE_DATE LAST_ACTIVITY_DATE date9.
    ;

    length EXCEPTION_CODE $10 EXCEPTION_DESC $200;

    /* Derived: Account age in months */
    ACCT_AGE_MONTHS = intck('month', OPEN_DATE, "&run_date"d);

    /* Derived: Days since last activity */
    DAYS_INACTIVE = "&run_date"d - LAST_ACTIVITY_DATE;

    /* Derived: Utilization ratio for revolving accounts */
    if ACCOUNT_TYPE in ('CC', 'LOC', 'HELC') and CREDIT_LIMIT > 0 then
      UTILIZATION_PCT = (CURRENT_BALANCE / CREDIT_LIMIT) * 100;
    else
      UTILIZATION_PCT = .;

    /* Derived: Dormancy flag */
    if DAYS_INACTIVE > 365 and ACCOUNT_STATUS = 'A' then
      DORMANCY_FLAG = 'Y';
    else
      DORMANCY_FLAG = 'N';

    /* Derived: High-balance flag */
    if CURRENT_BALANCE >= 250000 then
      HIGH_BALANCE_FLAG = 'Y';
    else
      HIGH_BALANCE_FLAG = 'N';

    /* Business Rule: Negative balance on deposit accounts */
    if ACCOUNT_TYPE in ('CHK', 'SAV', 'MMA', 'CD') and CURRENT_BALANCE < 0 then do;
      EXCEPTION_CODE = 'NEG_BAL';
      EXCEPTION_DESC = catx(' ', 'Negative balance',
        put(CURRENT_BALANCE, dollar18.2),
        'on deposit account', ACCOUNT_ID);
      output WORK.ACCT_EXCEPTIONS;
    end;

    /* Business Rule: Credit utilization > 95% */
    if UTILIZATION_PCT > 95 then do;
      EXCEPTION_CODE = 'HIGH_UTIL';
      EXCEPTION_DESC = catx(' ', 'Utilization at',
        put(UTILIZATION_PCT, 5.1), '%',
        'for account', ACCOUNT_ID);
      output WORK.ACCT_EXCEPTIONS;
    end;

    /* Business Rule: Missing risk rating */
    if RISK_RATING = . then do;
      EXCEPTION_CODE = 'NO_RISK';
      EXCEPTION_DESC = catx(' ', 'Missing risk rating for customer',
        CUSTOMER_ID);
      output WORK.ACCT_EXCEPTIONS;
    end;

    /* Snapshot metadata */
    SNAPSHOT_DATE = "&run_date"d;
    LOAD_TIMESTAMP = datetime();
    format LOAD_TIMESTAMP datetime20.;

    output STG_BANK.CUST_ACCOUNTS_DAILY;

    drop EXCEPTION_CODE EXCEPTION_DESC;
  run;

  /* ----------------------------------------------------------
     Step 3: Exception Report
     ---------------------------------------------------------- */
  %let nobs_except = %nobs(WORK.ACCT_EXCEPTIONS);

  %if &nobs_except > 0 %then %do;
    %put WARNING: &nobs_except data quality exceptions found;

    proc sql;
      insert into STG_BANK.ACCT_EXCEPTIONS
      select * from WORK.ACCT_EXCEPTIONS;
    quit;

    /* Email notification for critical exceptions */
    %if &nobs_except > 100 %then %do;
      %include "/opt/sas/custom/macros/sendmail.sas";
      %sendmail(
        to=&EMAIL_ONCALL,
        subject=ALERT: &nobs_except account exceptions on &run_date,
        body=Critical volume of account exceptions. Review STG_BANK.ACCT_EXCEPTIONS.
      );
    %end;
  %end;

  /* ----------------------------------------------------------
     Step 4: Summary Statistics
     ---------------------------------------------------------- */
  %let nobs_out = %nobs(STG_BANK.CUST_ACCOUNTS_DAILY);

  proc means data=STG_BANK.CUST_ACCOUNTS_DAILY noprint nway;
    class ACCOUNT_TYPE REGION_CODE;
    var CURRENT_BALANCE UTILIZATION_PCT ACCT_AGE_MONTHS;
    output out=WORK.ACCT_SUMMARY(drop=_TYPE_ _FREQ_)
      n=N_ACCOUNTS
      sum(CURRENT_BALANCE)=TOTAL_BALANCE
      mean(CURRENT_BALANCE)=AVG_BALANCE
      mean(UTILIZATION_PCT)=AVG_UTILIZATION
      mean(ACCT_AGE_MONTHS)=AVG_AGE_MONTHS
    ;
  run;

  %put NOTE: ============================================;
  %put NOTE: load_customer_accounts completed;
  %put NOTE: Records loaded: &nobs_out;
  %put NOTE: Exceptions: &nobs_except;
  %put NOTE: Duration: %sysfunc(putn(%sysevalf(%sysfunc(datetime())-&start_tm), time8.));
  %put NOTE: ============================================;

  %EXIT:

  proc datasets lib=WORK nolist;
    delete ACCT_RAW ACCT_EXCEPTIONS ACCT_SUMMARY;
  quit;

%mend load_customer_accounts;

/* Execute */
%load_customer_accounts(run_date=&CURR_DT);
