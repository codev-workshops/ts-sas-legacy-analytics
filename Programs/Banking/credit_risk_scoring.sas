/*=====================================================================
  credit_risk_scoring.sas — Credit Risk Model Execution
  Purpose: Apply the approved credit risk scorecard model to the
           current portfolio, produce PD/LGD/EAD estimates, and
           update risk ratings. Uses logistic regression coefficients
           from the validated model (Model ID: CRM-2023-Q4-v2).
  Inputs:  STG_BANK.CUST_ACCOUNTS_DAILY, ORA_DW.BUREAU_SCORES,
           ORA_DW.PAYMENT_HISTORY, ORA_DW.COLLATERAL
  Outputs: CURATED.RISK_SCORES, CURATED.RISK_MIGRATION,
           REPORTS.RISK_SUMMARY
  Schedule: Weekly Sunday 02:00 via Control-M BANK_WEEKLY_01
  Last Modified: 2024-01-08
=====================================================================*/

%include "/opt/sas/custom/macros/parmv.sas";
%include "/opt/sas/custom/macros/nobs.sas";

%macro credit_risk_scoring(score_date=&CURR_DT, model_id=CRM-2023-Q4-v2);

  %parmv(score_date, _req=1)
  %parmv(model_id, _req=1)

  %put NOTE: ============================================;
  %put NOTE: credit_risk_scoring started;
  %put NOTE: Score Date: &score_date;
  %put NOTE: Model: &model_id;
  %put NOTE: ============================================;

  /* ----------------------------------------------------------
     Step 1: Assemble Scoring Input Features
     ---------------------------------------------------------- */
  proc sql;
    create table WORK.SCORE_INPUT as
    select
      a.ACCOUNT_ID,
      a.CUSTOMER_ID,
      a.ACCOUNT_TYPE,
      a.CURRENT_BALANCE,
      a.CREDIT_LIMIT,
      a.ACCT_AGE_MONTHS,
      a.DAYS_INACTIVE,
      a.UTILIZATION_PCT,
      a.CUSTOMER_SEGMENT,
      a.REGION_CODE,

      /* Bureau scores */
      b.FICO_SCORE,
      b.VANTAGE_SCORE,
      b.BUREAU_INQS_6MO,
      b.BUREAU_TRADES_OPEN,
      b.BUREAU_DEROGS,
      b.BUREAU_UTIL_PCT,
      b.BUREAU_OLDEST_TRADE_MO,

      /* Payment behavior */
      p.PMT_ONTIME_12MO,
      p.PMT_LATE_30_12MO,
      p.PMT_LATE_60_12MO,
      p.PMT_LATE_90_12MO,
      p.MAX_DAYS_PAST_DUE_EVER,
      p.MONTHS_SINCE_LAST_DPD,
      p.AVG_PMT_RATIO_12MO,

      /* Collateral (secured loans) */
      c.COLLATERAL_VALUE,
      c.LAST_APPRAISAL_DATE,
      case
        when c.COLLATERAL_VALUE > 0
          then a.CURRENT_BALANCE / c.COLLATERAL_VALUE
        else .
      end as LTV format=8.4

    from STG_BANK.CUST_ACCOUNTS_DAILY a
    left join ORA_DW.BUREAU_SCORES b
      on a.CUSTOMER_ID = b.CUSTOMER_ID
      and b.SCORE_DATE = (select max(SCORE_DATE) from ORA_DW.BUREAU_SCORES
                          where CUSTOMER_ID = b.CUSTOMER_ID
                            and SCORE_DATE <= "&score_date"d)
    left join ORA_DW.PAYMENT_HISTORY p
      on a.ACCOUNT_ID = p.ACCOUNT_ID
    left join ORA_DW.COLLATERAL c
      on a.ACCOUNT_ID = c.ACCOUNT_ID
    where a.SNAPSHOT_DATE = "&score_date"d
      and a.ACCOUNT_TYPE in ('MTG','AUTO','PERS','CC','LOC','HELC')
    ;
  quit;

  /* ----------------------------------------------------------
     Step 2: Apply Scorecard Model
     Coefficients from validated Model CRM-2023-Q4-v2
     ---------------------------------------------------------- */
  data WORK.SCORED;
    set WORK.SCORE_INPUT;

    /* Logistic regression: log-odds calculation */
    INTERCEPT = -3.2145;

    /* FICO score contribution (normalized) */
    if not missing(FICO_SCORE) then do;
      if FICO_SCORE >= 760      then WOE_FICO = -1.204;
      else if FICO_SCORE >= 720 then WOE_FICO = -0.812;
      else if FICO_SCORE >= 680 then WOE_FICO = -0.356;
      else if FICO_SCORE >= 640 then WOE_FICO =  0.198;
      else if FICO_SCORE >= 600 then WOE_FICO =  0.654;
      else WOE_FICO = 1.102;
    end;
    else WOE_FICO = 0.198;  /* Population average for missing */

    /* Utilization contribution */
    if not missing(UTILIZATION_PCT) then do;
      if UTILIZATION_PCT <= 10      then WOE_UTIL = -0.956;
      else if UTILIZATION_PCT <= 30 then WOE_UTIL = -0.521;
      else if UTILIZATION_PCT <= 50 then WOE_UTIL = -0.102;
      else if UTILIZATION_PCT <= 70 then WOE_UTIL =  0.334;
      else if UTILIZATION_PCT <= 90 then WOE_UTIL =  0.789;
      else WOE_UTIL = 1.245;
    end;
    else WOE_UTIL = 0;

    /* Payment history contribution */
    if not missing(PMT_LATE_90_12MO) then do;
      if PMT_LATE_90_12MO = 0      then WOE_DPD = -0.678;
      else if PMT_LATE_90_12MO = 1  then WOE_DPD =  0.445;
      else WOE_DPD = 1.567;
    end;
    else WOE_DPD = 0;

    /* Account age contribution */
    if not missing(ACCT_AGE_MONTHS) then do;
      if ACCT_AGE_MONTHS >= 120     then WOE_AGE = -0.534;
      else if ACCT_AGE_MONTHS >= 60 then WOE_AGE = -0.289;
      else if ACCT_AGE_MONTHS >= 24 then WOE_AGE =  0.045;
      else WOE_AGE = 0.456;
    end;
    else WOE_AGE = 0;

    /* LTV contribution (secured only) */
    if ACCOUNT_TYPE in ('MTG','AUTO','HELC') then do;
      if not missing(LTV) then do;
        if LTV <= 0.60      then WOE_LTV = -0.712;
        else if LTV <= 0.80 then WOE_LTV = -0.234;
        else if LTV <= 1.00 then WOE_LTV =  0.356;
        else WOE_LTV = 0.889;
      end;
      else WOE_LTV = 0;
    end;
    else WOE_LTV = 0;

    /* Calculate log-odds and PD */
    LOG_ODDS = INTERCEPT
      + 0.412 * WOE_FICO
      + 0.198 * WOE_UTIL
      + 0.289 * WOE_DPD
      + 0.067 * WOE_AGE
      + 0.134 * WOE_LTV;

    PD = 1 / (1 + exp(-LOG_ODDS));
    format PD percent8.4;

    /* LGD estimation */
    if ACCOUNT_TYPE in ('MTG','AUTO','HELC') then do;
      if not missing(LTV) then
        LGD = max(0, min(1, (LTV - 0.5) * 0.8));
      else
        LGD = 0.40;
    end;
    else if ACCOUNT_TYPE = 'CC' then LGD = 0.75;
    else LGD = 0.50;
    format LGD percent8.4;

    /* EAD estimation */
    if ACCOUNT_TYPE in ('CC','LOC','HELC') then
      EAD = CURRENT_BALANCE + 0.50 * (CREDIT_LIMIT - CURRENT_BALANCE);
    else
      EAD = CURRENT_BALANCE;
    format EAD dollar18.2;

    /* Expected Loss */
    EXPECTED_LOSS = PD * LGD * EAD;
    format EXPECTED_LOSS dollar18.2;

    /* Risk Rating Assignment */
    if PD < 0.005      then NEW_RISK_RATING = 1;
    else if PD < 0.01  then NEW_RISK_RATING = 2;
    else if PD < 0.03  then NEW_RISK_RATING = 3;
    else if PD < 0.07  then NEW_RISK_RATING = 4;
    else if PD < 0.15  then NEW_RISK_RATING = 5;
    else if PD < 0.30  then NEW_RISK_RATING = 6;
    else NEW_RISK_RATING = 7;

    SCORE_DATE = "&score_date"d;
    MODEL_ID = "&model_id";
    SCORE_TIMESTAMP = datetime();
    format SCORE_DATE date9. SCORE_TIMESTAMP datetime20.;

    drop INTERCEPT WOE_FICO WOE_UTIL WOE_DPD WOE_AGE WOE_LTV LOG_ODDS;
  run;

  /* ----------------------------------------------------------
     Step 3: Risk Migration Matrix
     ---------------------------------------------------------- */
  proc sql;
    create table WORK.RISK_MIGRATION as
    select
      "&score_date"d as SCORE_DATE format=date9.,
      a.ACCOUNT_ID,
      a.RISK_RATING as PREV_RATING,
      s.NEW_RISK_RATING as CURR_RATING,
      case
        when a.RISK_RATING is null then 'NEW'
        when s.NEW_RISK_RATING < a.RISK_RATING then 'UPGRADE'
        when s.NEW_RISK_RATING > a.RISK_RATING then 'DOWNGRADE'
        else 'STABLE'
      end as MIGRATION_DIRECTION length=10,
      s.PD,
      s.EXPECTED_LOSS
    from WORK.SCORED s
    inner join STG_BANK.CUST_ACCOUNTS_DAILY a
      on s.ACCOUNT_ID = a.ACCOUNT_ID
    where a.SNAPSHOT_DATE = "&score_date"d
      and (a.RISK_RATING ne s.NEW_RISK_RATING
      or a.RISK_RATING is null)
    ;
  quit;

  /* ----------------------------------------------------------
     Step 4: Load Scores and Migration to Curated
     ---------------------------------------------------------- */
  %lock(CURATED.RISK_SCORES);

  proc append base=CURATED.RISK_SCORES data=WORK.SCORED force;
  run;

  %lock(CURATED.RISK_SCORES, unlock);

  %lock(CURATED.RISK_MIGRATION);

  proc append base=CURATED.RISK_MIGRATION data=WORK.RISK_MIGRATION force;
  run;

  %lock(CURATED.RISK_MIGRATION, unlock);

  /* ----------------------------------------------------------
     Step 5: Risk Summary Report
     ---------------------------------------------------------- */
  proc means data=WORK.SCORED noprint nway;
    class ACCOUNT_TYPE NEW_RISK_RATING;
    var PD LGD EAD EXPECTED_LOSS;
    output out=REPORTS.RISK_SUMMARY(drop=_TYPE_ _FREQ_)
      n=N_ACCOUNTS
      mean(PD)=AVG_PD
      mean(LGD)=AVG_LGD
      sum(EAD)=TOTAL_EAD
      sum(EXPECTED_LOSS)=TOTAL_EL
    ;
  run;

  %put NOTE: ============================================;
  %put NOTE: credit_risk_scoring completed;
  %put NOTE: Accounts scored: %nobs(WORK.SCORED);
  %put NOTE: Risk migrations: %nobs(WORK.RISK_MIGRATION);
  %put NOTE: ============================================;

  proc datasets lib=WORK nolist;
    delete SCORE_INPUT SCORED RISK_MIGRATION;
  quit;

%mend credit_risk_scoring;

%credit_risk_scoring(score_date=&CURR_DT);
