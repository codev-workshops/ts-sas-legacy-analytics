/*=====================================================================
  claims_processing.sas — Daily Claims Intake and Processing
  Purpose: Ingest new claims from feed, validate against policy
           data, apply auto-adjudication rules, route for manual
           review, and update claims register.
  Inputs:  RAW_INS.CLAIMS_FEED_YYYYMMDD, RAW_INS.POLICIES,
           TERA_DW.FRAUD_INDICATORS
  Outputs: STG_INS.CLAIMS_REGISTER, STG_INS.CLAIMS_REVIEW_QUEUE,
           STG_INS.FRAUD_ALERTS
  Schedule: Daily 08:00 via Control-M INS_DAILY_01
  Last Modified: 2024-01-13
=====================================================================*/

%include "/opt/sas/custom/macros/parmv.sas";
%include "/opt/sas/custom/macros/nobs.sas";
%include "/opt/sas/custom/macros/sendmail.sas";

%macro claims_processing(proc_date=&CURR_DT);

  %parmv(proc_date, _req=1)

  %local feed_ds nobs_new nobs_auto nobs_review nobs_fraud;
  %let feed_ds = CLAIMS_FEED_%sysfunc(putn("&proc_date"d, yymmddn8.));

  %put NOTE: ============================================;
  %put NOTE: claims_processing started;
  %put NOTE: Processing Date: &proc_date;
  %put NOTE: ============================================;

  /* ----------------------------------------------------------
     Step 1: Ingest and Validate
     ---------------------------------------------------------- */
  %if %sysfunc(exist(RAW_INS.&feed_ds)) = 0 %then %do;
    %put ERROR: Claims feed RAW_INS.&feed_ds not found;
    %goto ABORT;
  %end;

  data WORK.CLAIMS_VALID(label="Validated Claims")
       WORK.CLAIMS_INVALID(label="Invalid Claims");

    set RAW_INS.&feed_ds;

    length VALIDATION_ERROR $200;

    /* Check policy exists and is active */
    if _N_ = 1 then do;
      declare hash h_pol(dataset: "RAW_INS.POLICIES(where=(STATUS='ACTIVE'))");
      h_pol.definekey('POLICY_ID');
      h_pol.definedata('POLICY_TYPE', 'EFFECTIVE_DATE', 'EXPIRATION_DATE',
                       'SUM_INSURED', 'DEDUCTIBLE');
      h_pol.definedone();
    end;

    length POLICY_TYPE $10 SUM_INSURED DEDUCTIBLE 8;
    format EFFECTIVE_DATE EXPIRATION_DATE date9.;

    rc = h_pol.find();

    if rc ne 0 then do;
      VALIDATION_ERROR = catx(' ', 'Policy not found or inactive:', POLICY_ID);
      output WORK.CLAIMS_INVALID;
      return;
    end;

    /* Check loss date within policy period */
    if LOSS_DATE < EFFECTIVE_DATE or LOSS_DATE > EXPIRATION_DATE then do;
      VALIDATION_ERROR = catx(' ', 'Loss date', put(LOSS_DATE, date9.),
        'outside policy period',
        put(EFFECTIVE_DATE, date9.), '-', put(EXPIRATION_DATE, date9.));
      output WORK.CLAIMS_INVALID;
      return;
    end;

    /* Check claimed amount vs sum insured */
    if CLAIMED_AMOUNT > SUM_INSURED then do;
      VALIDATION_ERROR = catx(' ', 'Claimed amount',
        put(CLAIMED_AMOUNT, dollar18.2), 'exceeds sum insured',
        put(SUM_INSURED, dollar18.2));
      output WORK.CLAIMS_INVALID;
      return;
    end;

    output WORK.CLAIMS_VALID;
    drop VALIDATION_ERROR rc;
  run;

  %let nobs_new = %nobs(WORK.CLAIMS_VALID);
  %put NOTE: Valid new claims: &nobs_new;

  /* ----------------------------------------------------------
     Step 2: Fraud Screening
     ---------------------------------------------------------- */
  proc sql;
    create table WORK.FRAUD_CHECK as
    select
      c.*,
      f.FRAUD_SCORE,
      f.INDICATOR_FLAGS,
      case
        when f.FRAUD_SCORE >= 80 then 'HIGH'
        when f.FRAUD_SCORE >= 50 then 'MEDIUM'
        else 'LOW'
      end as FRAUD_RISK length=6
    from WORK.CLAIMS_VALID c
    left join TERA_DW.FRAUD_INDICATORS f
      on c.POLICY_ID = f.POLICY_ID
      and c.CLAIMANT_ID = f.CLAIMANT_ID
    ;
  quit;

  /* Separate high-risk for SIU review */
  data WORK.FRAUD_ALERTS;
    set WORK.FRAUD_CHECK;
    where FRAUD_RISK = 'HIGH';
    ALERT_REASON = catx('; ',
      catx(' ', 'Fraud score:', put(FRAUD_SCORE, 4.)),
      INDICATOR_FLAGS);
    ALERT_DATE = "&proc_date"d;
    format ALERT_DATE date9.;
  run;

  %let nobs_fraud = %nobs(WORK.FRAUD_ALERTS);

  /* ----------------------------------------------------------
     Step 3: Auto-Adjudication Rules
     ---------------------------------------------------------- */
  data WORK.AUTO_ADJUDICATED(label="Auto-Adjudicated Claims")
       WORK.MANUAL_REVIEW(label="Claims for Manual Review");

    set WORK.FRAUD_CHECK;

    length ADJUDICATION_RESULT $20 ADJUDICATION_REASON $200
           APPROVED_AMOUNT 8;

    /* Auto-deny: fraud high risk */
    if FRAUD_RISK = 'HIGH' then do;
      ADJUDICATION_RESULT = 'DENY';
      ADJUDICATION_REASON = 'High fraud risk - SIU referral';
      APPROVED_AMOUNT = 0;
      output WORK.MANUAL_REVIEW;
      return;
    end;

    /* Auto-approve: low risk, under deductible threshold */
    if FRAUD_RISK = 'LOW'
      and CLAIMED_AMOUNT <= 5000
      and POLICY_TYPE in ('AUTO','HOME','RENT')
    then do;
      ADJUDICATION_RESULT = 'APPR';
      ADJUDICATION_REASON = 'Auto-approved: low risk, small claim';
      APPROVED_AMOUNT = max(0, CLAIMED_AMOUNT - DEDUCTIBLE);
      output WORK.AUTO_ADJUDICATED;
      return;
    end;

    /* Auto-approve: standard claim within limits */
    if FRAUD_RISK = 'LOW'
      and CLAIMED_AMOUNT <= SUM_INSURED * 0.25
      and CLAIMED_AMOUNT <= 50000
    then do;
      ADJUDICATION_RESULT = 'APPR';
      ADJUDICATION_REASON = 'Auto-approved: within 25% of sum insured';
      APPROVED_AMOUNT = max(0, CLAIMED_AMOUNT - DEDUCTIBLE);
      output WORK.AUTO_ADJUDICATED;
      return;
    end;

    /* Everything else goes to manual review */
    ADJUDICATION_RESULT = 'PEND';
    ADJUDICATION_REASON = catx('; ',
      ifc(FRAUD_RISK='MEDIUM', 'Medium fraud risk', ''),
      ifc(CLAIMED_AMOUNT > 50000, 'Large claim', ''),
      ifc(CLAIMED_AMOUNT > SUM_INSURED * 0.25, 'Exceeds 25% threshold', ''));
    APPROVED_AMOUNT = .;
    output WORK.MANUAL_REVIEW;
  run;

  %let nobs_auto = %nobs(WORK.AUTO_ADJUDICATED);
  %let nobs_review = %nobs(WORK.MANUAL_REVIEW);

  /* ----------------------------------------------------------
     Step 4: Update Claims Register
     ---------------------------------------------------------- */
  data WORK.CLAIMS_COMBINED;
    set WORK.AUTO_ADJUDICATED
        WORK.MANUAL_REVIEW;

    PROCESSING_DATE = "&proc_date"d;
    CLAIM_STATUS = ADJUDICATION_RESULT;
    format PROCESSING_DATE date9.
           CLAIM_STATUS $CLMSTAT.;
  run;

  proc append base=STG_INS.CLAIMS_REGISTER
              data=WORK.CLAIMS_COMBINED force;
  run;

  /* Manual review queue */
  proc append base=STG_INS.CLAIMS_REVIEW_QUEUE
              data=WORK.MANUAL_REVIEW force;
  run;

  /* Fraud alerts */
  %if &nobs_fraud > 0 %then %do;
    proc append base=STG_INS.FRAUD_ALERTS
                data=WORK.FRAUD_ALERTS force;
    run;

    %sendmail(
      to=&EMAIL_ONCALL,
      subject=SIU ALERT: &nobs_fraud high-risk claims on &proc_date,
      body=&nobs_fraud claims flagged for SIU review. See STG_INS.FRAUD_ALERTS.
    );
  %end;

  %put NOTE: ============================================;
  %put NOTE: claims_processing completed;
  %put NOTE: New claims: &nobs_new;
  %put NOTE: Auto-adjudicated: &nobs_auto;
  %put NOTE: Manual review: &nobs_review;
  %put NOTE: Fraud alerts: &nobs_fraud;
  %put NOTE: ============================================;

  %goto EXIT;

  %ABORT:
  %put ERROR: claims_processing ABORTED;

  %EXIT:

  proc datasets lib=WORK nolist;
    delete CLAIMS_VALID CLAIMS_INVALID FRAUD_CHECK FRAUD_ALERTS
           AUTO_ADJUDICATED MANUAL_REVIEW CLAIMS_COMBINED;
  quit;

%mend claims_processing;

%claims_processing(proc_date=&CURR_DT);
