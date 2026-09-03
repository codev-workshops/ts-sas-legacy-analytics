/*=====================================================================
  customer_profitability.sas — Customer P&L and Profitability
  Purpose: Calculate customer-level profitability by combining
           interest income, fee income, cost of funds, operating
           costs, and credit losses. Produces segment-level and
           branch-level profitability summaries.
  Inputs:  STG_BANK.CUST_ACCOUNTS_DAILY, CURATED.DAILY_TRANSACTIONS,
           CURATED.RISK_SCORES, ORA_DW.COST_OF_FUNDS
  Outputs: REPORTS.CUSTOMER_PNL, REPORTS.SEGMENT_PROFITABILITY,
           REPORTS.BRANCH_PROFITABILITY
  Schedule: Monthly 10th business day via Control-M BANK_MONTHLY_03
  Last Modified: 2024-01-06
=====================================================================*/

%include "/opt/sas/custom/macros/parmv.sas";
%include "/opt/sas/custom/macros/nobs.sas";
%include "/opt/sas/custom/macros/export_xlsx.sas";

%macro customer_profitability(report_month=&PREV_YM);

  %parmv(report_month, _req=1)

  %local month_start month_end;
  %let month_start = %sysfunc(inputn(&report_month.01, yymmdd8.), date9.);
  %let month_end   = %sysfunc(intnx(month, "&month_start"d, 0, E), date9.);

  %put NOTE: ============================================;
  %put NOTE: customer_profitability;
  %put NOTE: Period: &report_month;
  %put NOTE: ============================================;

  /* ----------------------------------------------------------
     Step 1: Interest Income by Customer
     ---------------------------------------------------------- */
  proc sql;
    create table WORK.INTEREST_INCOME as
    select
      a.CUSTOMER_ID,
      /* Primary segment/region/branch (from largest account) */
      max(a.CUSTOMER_SEGMENT) as CUSTOMER_SEGMENT,
      max(a.REGION_CODE) as REGION_CODE,
      max(a.BRANCH_ID) as BRANCH_ID,
      /* Lending income */
      sum(case when a.ACCOUNT_TYPE in ('MTG','AUTO','PERS','CC','LOC','HELC')
        then a.CURRENT_BALANCE * a.INTEREST_RATE / 12 else 0 end)
        as LENDING_INCOME format=dollar18.2,
      /* Deposit cost */
      sum(case when a.ACCOUNT_TYPE in ('CHK','SAV','MMA','CD','IRA')
        then a.CURRENT_BALANCE * a.INTEREST_RATE / 12 else 0 end)
        as DEPOSIT_COST format=dollar18.2,
      /* Net interest margin */
      calculated LENDING_INCOME - calculated DEPOSIT_COST
        as NET_INTEREST_INCOME format=dollar18.2,
      count(distinct a.ACCOUNT_ID) as NUM_ACCOUNTS,
      sum(a.CURRENT_BALANCE) as TOTAL_RELATIONSHIP format=dollar18.2
    from STG_BANK.CUST_ACCOUNTS_DAILY a
    where a.SNAPSHOT_DATE = "&month_end"d
    group by a.CUSTOMER_ID
    ;
  quit;

  /* ----------------------------------------------------------
     Step 2: Fee Income from Transactions
     ---------------------------------------------------------- */
  proc sql;
    create table WORK.FEE_INCOME as
    select
      t.CUSTOMER_ID,
      sum(case when t.TRANSACTION_TYPE = 'FEE'
        then abs(t.TRANSACTION_AMOUNT) else 0 end) as FEE_INCOME
        format=dollar18.2,
      sum(case when t.TRANSACTION_TYPE = 'INT'
        then abs(t.TRANSACTION_AMOUNT) else 0 end) as INT_CREDITED
        format=dollar18.2,
      count(*) as TXN_VOLUME
    from CURATED.DAILY_TRANSACTIONS t
    where t.TRANSACTION_DATE between "&month_start"d and "&month_end"d
    group by t.CUSTOMER_ID
    ;
  quit;

  /* ----------------------------------------------------------
     Step 3: Expected Credit Loss by Customer
     ---------------------------------------------------------- */
  proc sql;
    create table WORK.ECL as
    select
      r.CUSTOMER_ID,
      sum(r.EXPECTED_LOSS) as TOTAL_ECL format=dollar18.2
    from CURATED.RISK_SCORES r
    where r.SCORE_DATE = (select max(SCORE_DATE) from CURATED.RISK_SCORES
                          where SCORE_DATE <= "&month_end"d)
    group by r.CUSTOMER_ID
    ;
  quit;

  /* ----------------------------------------------------------
     Step 4: Customer P&L Assembly
     ---------------------------------------------------------- */
  data REPORTS.CUSTOMER_PNL(label="Customer Profitability &report_month");
    merge WORK.INTEREST_INCOME(in=a)
          WORK.FEE_INCOME(in=b)
          WORK.ECL(in=c);
    by CUSTOMER_ID;

    if a;

    /* Operating cost allocation (simplified: $15/account/month) */
    OPERATING_COST = NUM_ACCOUNTS * 15;
    format OPERATING_COST dollar18.2;

    /* Total Revenue */
    TOTAL_REVENUE = sum(NET_INTEREST_INCOME, FEE_INCOME, 0);
    format TOTAL_REVENUE dollar18.2;

    /* Net Profit */
    NET_PROFIT = TOTAL_REVENUE - OPERATING_COST - coalesce(TOTAL_ECL, 0);
    format NET_PROFIT dollar18.2;

    /* ROA (annualized) */
    if TOTAL_RELATIONSHIP > 0 then
      ROA = (NET_PROFIT * 12) / TOTAL_RELATIONSHIP;
    else
      ROA = .;
    format ROA percent8.4;

    /* Profitability tier */
    length PROFIT_TIER $20;
    if NET_PROFIT >= 500    then PROFIT_TIER = 'Highly Profitable';
    else if NET_PROFIT >= 100 then PROFIT_TIER = 'Profitable';
    else if NET_PROFIT >= 0   then PROFIT_TIER = 'Marginal';
    else PROFIT_TIER = 'Unprofitable';

    REPORT_MONTH = "&report_month";
  run;

  /* ----------------------------------------------------------
     Step 5: Segment and Branch Summaries
     ---------------------------------------------------------- */
  proc means data=REPORTS.CUSTOMER_PNL noprint nway;
    class CUSTOMER_SEGMENT;
    var TOTAL_REVENUE OPERATING_COST TOTAL_ECL NET_PROFIT TOTAL_RELATIONSHIP;
    output out=REPORTS.SEGMENT_PROFITABILITY(drop=_TYPE_ _FREQ_)
      n=N_CUSTOMERS
      sum=
      mean(NET_PROFIT)=AVG_PROFIT_PER_CUSTOMER
    ;
  run;

  proc means data=REPORTS.CUSTOMER_PNL noprint nway;
    class BRANCH_ID REGION_CODE;
    var TOTAL_REVENUE OPERATING_COST TOTAL_ECL NET_PROFIT;
    output out=REPORTS.BRANCH_PROFITABILITY(drop=_TYPE_ _FREQ_)
      n=N_CUSTOMERS
      sum=
    ;
  run;

  %export_xlsx(
    data=REPORTS.SEGMENT_PROFITABILITY,
    file=&REPORT_PATH/PROFITABILITY_&report_month..xlsx,
    sheet=By_Segment
  );

  %put NOTE: ============================================;
  %put NOTE: customer_profitability completed;
  %put NOTE: Customers analyzed: %nobs(REPORTS.CUSTOMER_PNL);
  %put NOTE: ============================================;

  proc datasets lib=WORK nolist;
    delete INTEREST_INCOME FEE_INCOME ECL;
  quit;

%mend customer_profitability;

%customer_profitability(report_month=&PREV_YM);
