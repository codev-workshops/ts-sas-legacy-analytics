/*=====================================================================
  policy_valuation.sas — Monthly Policy Book Valuation
  Purpose: Calculate in-force policy metrics, premium adequacy,
           loss ratios, and reserve estimates for the insurance
           book of business.
  Inputs:  RAW_INS.POLICIES, RAW_INS.CLAIMS, RAW_INS.PREMIUMS,
           TERA_DW.ACTUARIAL_TABLES
  Outputs: STG_INS.POLICY_VALUATION, REPORTS.LOSS_RATIO_SUMMARY,
           REPORTS.RESERVE_ADEQUACY
  Schedule: Monthly 5th business day via Control-M INS_MONTHLY_01
  Last Modified: 2024-01-10
=====================================================================*/

%include "/opt/sas/custom/macros/parmv.sas";
%include "/opt/sas/custom/macros/nobs.sas";

%macro policy_valuation(val_date=&CURR_DT, lob=ALL);

  %parmv(val_date, _req=1)
  %parmv(lob, _req=0, _val=ALL AUTO HOME WL TL UL HLTH)

  %local val_ym;
  %let val_ym = %sysfunc(putn("&val_date"d, yymmn6.));

  %put NOTE: ============================================;
  %put NOTE: policy_valuation started;
  %put NOTE: Valuation Date: &val_date;
  %put NOTE: Line of Business: &lob;
  %put NOTE: ============================================;

  /* ----------------------------------------------------------
     Step 1: Extract In-Force Policies
     ---------------------------------------------------------- */
  proc sql;
    create table WORK.INFORCE as
    select
      p.POLICY_ID,
      p.CUSTOMER_ID,
      p.POLICY_TYPE,
      p.EFFECTIVE_DATE,
      p.EXPIRATION_DATE,
      p.ANNUAL_PREMIUM,
      p.SUM_INSURED,
      p.DEDUCTIBLE,
      p.RISK_CATEGORY,
      p.UNDERWRITING_CLASS,
      p.AGENT_ID,
      p.BRANCH_CODE,
      intck('month', p.EFFECTIVE_DATE, "&val_date"d) as POLICY_AGE_MONTHS,
      intck('month', "&val_date"d, p.EXPIRATION_DATE) as MONTHS_TO_EXPIRY,
      case
        when p.EXPIRATION_DATE <= intnx('month', "&val_date"d, 3)
          then 'Y'
        else 'N'
      end as RENEWAL_DUE_FLAG length=1,
      /* Earned premium calculation (monthly pro-rata) */
      p.ANNUAL_PREMIUM / 12 *
        min(12, intck('month',
          max(p.EFFECTIVE_DATE, intnx('year', "&val_date"d, 0, 'B')),
          min("&val_date"d, p.EXPIRATION_DATE))) as YTD_EARNED_PREMIUM
        format=dollar18.2
    from RAW_INS.POLICIES p
    where p.STATUS = 'ACTIVE'
      and p.EFFECTIVE_DATE <= "&val_date"d
      and p.EXPIRATION_DATE >= "&val_date"d
      %if &lob ne ALL %then %do;
        and p.POLICY_TYPE = "&lob"
      %end;
    order by p.POLICY_ID
    ;
  quit;

  %put NOTE: In-force policies: %nobs(WORK.INFORCE);

  /* ----------------------------------------------------------
     Step 2: Claims Experience (12-month window)
     ---------------------------------------------------------- */
  proc sql;
    create table WORK.CLAIMS_EXP as
    select
      c.POLICY_ID,
      count(distinct c.CLAIM_ID) as NUM_CLAIMS,
      sum(c.INCURRED_AMOUNT) as TOTAL_INCURRED format=dollar18.2,
      sum(c.PAID_AMOUNT)     as TOTAL_PAID format=dollar18.2,
      sum(c.RESERVED_AMOUNT) as TOTAL_RESERVED format=dollar18.2,
      max(c.LOSS_DATE)       as LAST_CLAIM_DATE format=date9.,
      sum(case when c.CLAIM_STATUS in ('OPEN','INV','ADJ','PEND')
        then c.RESERVED_AMOUNT else 0 end) as OPEN_RESERVES
        format=dollar18.2,
      sum(case when c.CLAIM_STATUS = 'DENY' then 1 else 0 end)
        as DENIED_CLAIMS
    from RAW_INS.CLAIMS c
    where c.LOSS_DATE >= intnx('month', "&val_date"d, -12)
      and c.LOSS_DATE <= "&val_date"d
    group by c.POLICY_ID
    ;
  quit;

  /* ----------------------------------------------------------
     Step 3: Premium Collections
     ---------------------------------------------------------- */
  proc sql;
    create table WORK.PREMIUM_COLL as
    select
      POLICY_ID,
      sum(PREMIUM_AMOUNT) as COLLECTED_PREMIUM format=dollar18.2,
      sum(case when PAYMENT_STATUS = 'RETURNED'
        then PREMIUM_AMOUNT else 0 end) as RETURNED_PREMIUM
        format=dollar18.2,
      max(PAYMENT_DATE)   as LAST_PAYMENT_DATE format=date9.,
      count(case when PAYMENT_STATUS = 'LATE' then 1 end)
        as LATE_PAYMENTS
    from RAW_INS.PREMIUMS
    where PAYMENT_DATE >= intnx('year', "&val_date"d, 0, 'B')
      and PAYMENT_DATE <= "&val_date"d
    group by POLICY_ID
    ;
  quit;

  /* ----------------------------------------------------------
     Step 4: Merge and Calculate Valuation Metrics
     ---------------------------------------------------------- */
  data STG_INS.POLICY_VALUATION(label="Monthly Policy Valuation &val_ym");
    merge WORK.INFORCE(in=a)
          WORK.CLAIMS_EXP(in=b)
          WORK.PREMIUM_COLL(in=c);
    by POLICY_ID;

    if a;  /* Keep only in-force policies */

    format POLICY_TYPE $POLTYPE.
           RISK_CATEGORY $RISKCAT.
    ;

    /* Loss Ratio */
    if YTD_EARNED_PREMIUM > 0 then
      LOSS_RATIO = coalesce(TOTAL_INCURRED, 0) / YTD_EARNED_PREMIUM;
    else
      LOSS_RATIO = .;
    format LOSS_RATIO percent8.2;

    /* Combined Ratio (simplified: loss + 30% expense load) */
    if YTD_EARNED_PREMIUM > 0 then
      COMBINED_RATIO = LOSS_RATIO + 0.30;
    else
      COMBINED_RATIO = .;
    format COMBINED_RATIO percent8.2;

    /* Premium Adequacy Flag */
    if COMBINED_RATIO = . then PREMIUM_ADEQUATE = 'N';
    else if COMBINED_RATIO > 1.0 then PREMIUM_ADEQUATE = 'N';
    else PREMIUM_ADEQUATE = 'Y';

    /* IBNR Estimate (basic: 15% of earned premium - paid) */
    IBNR_ESTIMATE = max(0, YTD_EARNED_PREMIUM * 0.15 - coalesce(TOTAL_PAID, 0));
    format IBNR_ESTIMATE dollar18.2;

    /* Total Reserve = Open Case + IBNR */
    TOTAL_RESERVE = coalesce(OPEN_RESERVES, 0) + IBNR_ESTIMATE;
    format TOTAL_RESERVE dollar18.2;

    VALUATION_DATE = "&val_date"d;
    format VALUATION_DATE date9.;
  run;

  /* ----------------------------------------------------------
     Step 5: Loss Ratio Summary by Line of Business
     ---------------------------------------------------------- */
  proc means data=STG_INS.POLICY_VALUATION noprint nway;
    class POLICY_TYPE;
    var YTD_EARNED_PREMIUM TOTAL_INCURRED TOTAL_PAID
        TOTAL_RESERVE IBNR_ESTIMATE;
    output out=REPORTS.LOSS_RATIO_SUMMARY(drop=_TYPE_ _FREQ_)
      n=N_POLICIES
      sum(YTD_EARNED_PREMIUM)=TOTAL_EARNED
      sum(TOTAL_INCURRED)=TOTAL_INCURRED
      sum(TOTAL_PAID)=TOTAL_PAID
      sum(TOTAL_RESERVE)=TOTAL_RESERVES
      sum(IBNR_ESTIMATE)=TOTAL_IBNR
    ;
  run;

  /* Add calculated loss ratios */
  data REPORTS.LOSS_RATIO_SUMMARY;
    set REPORTS.LOSS_RATIO_SUMMARY;
    if TOTAL_EARNED > 0 then do;
      AGG_LOSS_RATIO = TOTAL_INCURRED / TOTAL_EARNED;
      AGG_COMBINED_RATIO = AGG_LOSS_RATIO + 0.30;
    end;
    format AGG_LOSS_RATIO AGG_COMBINED_RATIO percent8.2
           TOTAL_EARNED TOTAL_INCURRED TOTAL_PAID
           TOTAL_RESERVES TOTAL_IBNR dollar20.2;
  run;

  %put NOTE: ============================================;
  %put NOTE: policy_valuation completed;
  %put NOTE: Policies valued: %nobs(STG_INS.POLICY_VALUATION);
  %put NOTE: ============================================;

  proc datasets lib=WORK nolist;
    delete INFORCE CLAIMS_EXP PREMIUM_COLL;
  quit;

%mend policy_valuation;

%policy_valuation(val_date=&CURR_DT);
