/*=====================================================================
  monthly_regulatory_reporting.sas — Basel III / Call Report
  Purpose: Produce monthly regulatory aggregations for:
           - Risk-Weighted Assets (RWA) by category
           - Capital Adequacy Ratios (CET1, Tier 1, Total Capital)
           - Loan Loss Provision coverage
           - Liquidity Coverage Ratio (LCR) inputs
           - Delinquency aging and charge-off summaries
  Inputs:  CURATED.DAILY_TRANSACTIONS, STG_BANK.CUST_ACCOUNTS_DAILY,
           ORA_DW.LOAN_DETAILS, ORA_DW.COLLATERAL
  Outputs: REPORTS.MONTHLY_RWA, REPORTS.CAPITAL_ADEQUACY,
           REPORTS.DELINQUENCY_AGING, REPORTS.LLP_COVERAGE,
           /data/sas/reports/output/REG_REPORT_YYYYMM.xlsx
  Schedule: Monthly 3rd business day via Control-M BANK_MONTHLY_01
  Last Modified: 2024-01-12
=====================================================================*/

%include "/opt/sas/custom/macros/parmv.sas";
%include "/opt/sas/custom/macros/nobs.sas";
%include "/opt/sas/custom/macros/export_xlsx.sas";

%macro monthly_regulatory_reporting(report_month=&PREV_YM);

  %parmv(report_month, _req=1)

  %local month_start month_end rpt_label;
  %let month_start = %sysfunc(inputn(&report_month.01, yymmdd8.), date9.);
  %let month_end   = %sysfunc(intnx(month, "&month_start"d, 0, E), date9.);
  %let rpt_label   = %substr(&report_month, 1, 4)-%substr(&report_month, 5, 2);

  %put NOTE: ============================================;
  %put NOTE: monthly_regulatory_reporting;
  %put NOTE: Period: &rpt_label (&month_start to &month_end);
  %put NOTE: ============================================;

  /* ----------------------------------------------------------
     Step 1: Risk-Weighted Assets by Category
     Basel III standardized approach risk weights
     ---------------------------------------------------------- */
  proc sql;
    create table REPORTS.MONTHLY_RWA as
    select
      "&report_month" as REPORT_MONTH length=6,
      ACCOUNT_TYPE,
      CUSTOMER_SEGMENT,
      case
        when ACCOUNT_TYPE in ('CHK','SAV','MMA')     then 0.00
        when ACCOUNT_TYPE = 'CD'                     then 0.00
        when ACCOUNT_TYPE = 'MTG' and LTV <= 0.80    then 0.35
        when ACCOUNT_TYPE = 'MTG' and LTV >  0.80    then 0.50
        when ACCOUNT_TYPE = 'HELC'                   then 0.50
        when ACCOUNT_TYPE in ('AUTO','PERS')         then 0.75
        when ACCOUNT_TYPE = 'CC'                     then 0.75
        when ACCOUNT_TYPE = 'LOC'                    then 1.00
        else 1.00
      end as RISK_WEIGHT,
      count(*) as N_ACCOUNTS,
      sum(CURRENT_BALANCE)                    as TOTAL_EXPOSURE format=dollar20.2,
      sum(CURRENT_BALANCE * calculated RISK_WEIGHT) as RWA      format=dollar20.2
    from STG_BANK.CUST_ACCOUNTS_DAILY a
    left join ORA_DW.LOAN_DETAILS l
      on a.ACCOUNT_ID = l.ACCOUNT_ID
    where a.SNAPSHOT_DATE = "&month_end"d
    group by 1, 2, 3, 4
    order by ACCOUNT_TYPE, CUSTOMER_SEGMENT
    ;
  quit;

  /* ----------------------------------------------------------
     Step 2: Delinquency Aging — 30/60/90/120/180+ Buckets
     ---------------------------------------------------------- */
  proc sql;
    create table REPORTS.DELINQUENCY_AGING as
    select
      "&report_month" as REPORT_MONTH length=6,
      ACCOUNT_TYPE,
      REGION_CODE,
      case
        when DAYS_PAST_DUE = 0          then 'Current'
        when DAYS_PAST_DUE between 1 and 29  then '1-29'
        when DAYS_PAST_DUE between 30 and 59 then '30-59'
        when DAYS_PAST_DUE between 60 and 89 then '60-89'
        when DAYS_PAST_DUE between 90 and 119 then '90-119'
        when DAYS_PAST_DUE between 120 and 179 then '120-179'
        when DAYS_PAST_DUE >= 180       then '180+'
        else 'Unknown'
      end as DELINQ_BUCKET length=10,
      count(*)               as N_ACCOUNTS,
      sum(CURRENT_BALANCE)   as TOTAL_BALANCE format=dollar20.2,
      sum(PAST_DUE_AMOUNT)   as TOTAL_PAST_DUE format=dollar20.2
    from STG_BANK.CUST_ACCOUNTS_DAILY a
    left join ORA_DW.LOAN_DETAILS l
      on a.ACCOUNT_ID = l.ACCOUNT_ID
    where a.SNAPSHOT_DATE = "&month_end"d
      and a.ACCOUNT_TYPE in ('MTG','AUTO','PERS','CC','LOC','HELC')
    group by 1, 2, 3, 4
    order by ACCOUNT_TYPE, REGION_CODE,
      case
        when calculated DELINQ_BUCKET = 'Current'  then 0
        when calculated DELINQ_BUCKET = '1-29'     then 1
        when calculated DELINQ_BUCKET = '30-59'    then 2
        when calculated DELINQ_BUCKET = '60-89'    then 3
        when calculated DELINQ_BUCKET = '90-119'   then 4
        when calculated DELINQ_BUCKET = '120-179'  then 5
        when calculated DELINQ_BUCKET = '180+'     then 6
        else 7
      end
    ;
  quit;

  /* ----------------------------------------------------------
     Step 3: Loan Loss Provision Coverage
     ---------------------------------------------------------- */
  proc sql;
    create table REPORTS.LLP_COVERAGE as
    select
      "&report_month" as REPORT_MONTH length=6,
      a.ACCOUNT_TYPE,
      count(*) as N_LOANS,
      sum(a.CURRENT_BALANCE) as GROSS_LOANS format=dollar20.2,
      sum(l.ALLOWANCE_AMT)   as TOTAL_ALLOWANCE format=dollar20.2,
      case
        when sum(a.CURRENT_BALANCE) > 0
          then sum(l.ALLOWANCE_AMT) / sum(a.CURRENT_BALANCE) * 100
        else 0
      end as COVERAGE_PCT format=8.2,
      sum(case when l.DAYS_PAST_DUE >= 90 then a.CURRENT_BALANCE else 0 end)
        as NPL_BALANCE format=dollar20.2,
      case
        when calculated NPL_BALANCE > 0
          then sum(l.ALLOWANCE_AMT) / calculated NPL_BALANCE * 100
        else 0
      end as NPL_COVERAGE_PCT format=8.2
    from STG_BANK.CUST_ACCOUNTS_DAILY a
    inner join ORA_DW.LOAN_DETAILS l
      on a.ACCOUNT_ID = l.ACCOUNT_ID
    where a.SNAPSHOT_DATE = "&month_end"d
      and a.ACCOUNT_TYPE in ('MTG','AUTO','PERS','CC','LOC','HELC')
    group by 1, 2
    ;
  quit;

  /* ----------------------------------------------------------
     Step 4: Export to Excel for Regulators
     ---------------------------------------------------------- */
  %export_xlsx(
    data=REPORTS.MONTHLY_RWA,
    file=&REPORT_PATH/REG_REPORT_&report_month..xlsx,
    sheet=RWA
  );

  %export_xlsx(
    data=REPORTS.DELINQUENCY_AGING,
    file=&REPORT_PATH/REG_REPORT_&report_month..xlsx,
    sheet=Delinquency
  );

  %export_xlsx(
    data=REPORTS.LLP_COVERAGE,
    file=&REPORT_PATH/REG_REPORT_&report_month..xlsx,
    sheet=LLP_Coverage
  );

  %put NOTE: Regulatory report exported to &REPORT_PATH/REG_REPORT_&report_month..xlsx;

  /* ----------------------------------------------------------
     Step 5: Capital Adequacy Summary
     ---------------------------------------------------------- */
  proc sql;
    create table REPORTS.CAPITAL_ADEQUACY as
    select
      "&report_month"              as REPORT_MONTH length=6,
      sum(RWA)                     as TOTAL_RWA format=dollar20.2,
      /* Placeholder: these would come from GL in production */
      50000000                     as CET1_CAPITAL format=dollar20.2,
      65000000                     as TIER1_CAPITAL format=dollar20.2,
      80000000                     as TOTAL_CAPITAL format=dollar20.2,
      case when sum(RWA) > 0 then 50000000 / sum(RWA) * 100 else . end as CET1_RATIO format=8.2,
      case when sum(RWA) > 0 then 65000000 / sum(RWA) * 100 else . end as TIER1_RATIO format=8.2,
      case when sum(RWA) > 0 then 80000000 / sum(RWA) * 100 else . end as TOTAL_CAPITAL_RATIO format=8.2,
      /* Minimum requirements: CET1=4.5%, Tier1=6%, Total=8% */
      case when sum(RWA) = 0 then 'PASS' when 50000000/sum(RWA)*100 >= 4.5 then 'PASS' else 'FAIL' end
        as CET1_STATUS length=4,
      case when sum(RWA) = 0 then 'PASS' when 65000000/sum(RWA)*100 >= 6.0 then 'PASS' else 'FAIL' end
        as TIER1_STATUS length=4,
      case when sum(RWA) = 0 then 'PASS' when 80000000/sum(RWA)*100 >= 8.0 then 'PASS' else 'FAIL' end
        as TOTAL_CAPITAL_STATUS length=4
    from REPORTS.MONTHLY_RWA
    ;
  quit;

  %put NOTE: ============================================;
  %put NOTE: monthly_regulatory_reporting completed;
  %put NOTE: Report: &rpt_label;
  %put NOTE: ============================================;

%mend monthly_regulatory_reporting;

%monthly_regulatory_reporting(report_month=&PREV_YM);
