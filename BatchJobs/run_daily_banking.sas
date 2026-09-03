/*=====================================================================
  run_daily_banking.sas — Daily Banking Batch Orchestrator
  Purpose: Master control program for the daily banking ETL batch.
           Executes programs in dependency order, tracks status
           in control table, handles errors, and sends notifications.
  Schedule: Daily 05:45 via Control-M BANK_MASTER
  Last Modified: 2024-01-15
=====================================================================*/

%include "/opt/sas/config/Lev1/SASApp/autoexec.sas";

%macro run_daily_banking(run_date=&CURR_DT, restart_from=);

  %local batch_id job_count job_pass job_fail start_tm rc;
  %let start_tm = %sysfunc(datetime());
  %let batch_id = BANK_%sysfunc(putn("&run_date"d, yymmddn8.))_%sysfunc(putn(%sysfunc(datetime()), B8601DT.));
  %let job_count = 0;
  %let job_pass  = 0;
  %let job_fail  = 0;

  %put NOTE: ========================================================;
  %put NOTE: DAILY BANKING BATCH STARTED;
  %put NOTE: Batch ID: &batch_id;
  %put NOTE: Run Date: &run_date;
  %put NOTE: Restart From: %sysfunc(coalescec(&restart_from, BEGINNING));
  %put NOTE: ========================================================;

  /* ----------------------------------------------------------
     Control Table: Track each step's execution
     ---------------------------------------------------------- */
  data WORK.BATCH_CONTROL;
    length BATCH_ID $60 STEP_NUM 8 STEP_NAME $50 PROGRAM_PATH $200
           STATUS $10 START_TIME END_TIME 8 DURATION 8 ERROR_MSG $500;
    format START_TIME END_TIME datetime20. DURATION time8.;
    stop;
  run;

  /* ----------------------------------------------------------
     Macro to execute a step with error handling
     ---------------------------------------------------------- */
  %let _batch_abort = 0;

  %macro run_step(step_num, step_name, program);

    %local step_start step_rc;

    /* Skip if batch was aborted by a prior step */
    %if &_batch_abort = 1 %then %return;

    /* Skip if restarting past this step */
    %if %length(&restart_from) > 0 %then %do;
      %if &step_num < &restart_from %then %do;
        %put NOTE: Skipping step &step_num (&step_name) — restart from &restart_from;
        %return;
      %end;
    %end;

    %let job_count = %eval(&job_count + 1);
    %let step_start = %sysfunc(datetime());

    %put NOTE: ----------------------------------------;
    %put NOTE: Step &step_num: &step_name;
    %put NOTE: Program: &program;
    %put NOTE: ----------------------------------------;

    %let step_rc = 0;
    %local _saved_syscc;
    %let _saved_syscc = &SYSCC;
    %let SYSCC = 0;

    /* Propagate run_date to child programs via CURR_DT */
    %let CURR_DT = &run_date;

    %include "&program" / source2;

    %if &SYSCC > 4 %then %let step_rc = &SYSCC;
    %let SYSCC = &_saved_syscc;

    /* Log to control table */
    proc sql;
      insert into WORK.BATCH_CONTROL
      values(
        "&batch_id",
        &step_num,
        "&step_name",
        "&program",
        ifc(&step_rc = 0, "PASS", "FAIL"),
        &step_start,
        %sysfunc(datetime()),
        %sysevalf(%sysfunc(datetime()) - &step_start),
        ifc(&step_rc = 0, "", "SYSCC=&step_rc")
      );
    quit;

    %if &step_rc = 0 %then %do;
      %let job_pass = %eval(&job_pass + 1);
      %put NOTE: Step &step_num PASSED;
    %end;
    %else %do;
      %let job_fail = %eval(&job_fail + 1);
      %put ERROR: Step &step_num FAILED (SYSCC=&step_rc);

      %if &ABORT_ON_ERR = Y %then %do;
        %put ERROR: ABORT_ON_ERR=Y — halting batch;

        %sendmail(
          to=&EMAIL_ONCALL,
          subject=BATCH FAILURE: &batch_id at step &step_num,
          body=Step &step_num (&step_name) failed with SYSERR=&step_rc. Batch halted. Restart with restart_from=&step_num.
        );

        %let _batch_abort = 1;
      %end;
    %end;

  %mend run_step;

  /* ----------------------------------------------------------
     Step Execution Order (dependency chain)
     ---------------------------------------------------------- */
  %run_step(1, Load Customer Accounts,
    /opt/sas/custom/programs/Banking/load_customer_accounts.sas)

  %run_step(2, Daily Transaction Processing,
    /opt/sas/custom/programs/Banking/daily_transaction_processing.sas)

  %run_step(3, Credit Risk Scoring,
    /opt/sas/custom/programs/Banking/credit_risk_scoring.sas)

  %run_step(4, Monthly Regulatory Reporting,
    /opt/sas/custom/programs/Banking/monthly_regulatory_reporting.sas)

  /* ----------------------------------------------------------
     Batch Summary
     ---------------------------------------------------------- */
  title "Daily Banking Batch Control — &batch_id";
  proc print data=WORK.BATCH_CONTROL noobs;
  run;
  title;

  /* Archive control table */
  proc append base=ARCHIVE.BATCH_HISTORY data=WORK.BATCH_CONTROL force;
  run;

  /* Summary notification */
  %sendmail(
    to=&EMAIL_DL,
    subject=Batch &batch_id: &job_pass pass / &job_fail fail of &job_count steps,
    body=See ARCHIVE.BATCH_HISTORY for details. Duration: %sysfunc(putn(%sysevalf(%sysfunc(datetime())-&start_tm), time8.))
  );

  %put NOTE: ========================================================;
  %put NOTE: DAILY BANKING BATCH COMPLETED;
  %put NOTE: Batch ID: &batch_id;
  %put NOTE: Steps: &job_count | Pass: &job_pass | Fail: &job_fail;
  %put NOTE: Duration: %sysfunc(putn(%sysevalf(%sysfunc(datetime())-&start_tm), time8.));
  %put NOTE: ========================================================;

%mend run_daily_banking;

%run_daily_banking(run_date=&CURR_DT);
