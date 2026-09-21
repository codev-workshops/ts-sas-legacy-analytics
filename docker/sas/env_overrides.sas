/*=====================================================================
  env_overrides.sas — container-environment fixes applied AFTER the
  estate's own seed loader (Data/load_seed_data.sas) and BEFORE the
  banking programs run.

  The estate is the migration's source of truth and is packaged
  read-only under /opt/sas/custom, so anything its *local* stand-in
  environment gets wrong is corrected here, in the runtime layer,
  exactly as a production DBA would fix a landing table — never by
  editing the programs or the seed loader.

  Each override records the estate defect it works around so the
  migration team can carry it into the target's exception list.
=====================================================================*/

/* ----------------------------------------------------------
   OVR-001  STG_BANK.ACCT_EXCEPTIONS landing table

   Defect: Data/load_seed_data.sas creates a 5-column shell
   (ACCOUNT_ID, CUSTOMER_ID, EXCEPTION_CODE, EXCEPTION_DESC,
   SNAPSHOT_DATE), but load_customer_accounts.sas does
       insert into STG_BANK.ACCT_EXCEPTIONS select * from WORK.ACCT_EXCEPTIONS;
   where WORK.ACCT_EXCEPTIONS carries the full 29-column account
   snapshot — the step's `drop EXCEPTION_CODE EXCEPTION_DESC;` applies
   to BOTH output datasets, so the exception rows never carry a code.
   SAS 9.4 and OpenSAS both reject the 29-into-5 INSERT with an ERROR,
   so the estate's local driver cannot complete as shipped.

   Fix: recreate the shell with the shape the program actually writes
   (the production landing table's shape). Row count is unaffected.
   ---------------------------------------------------------- */
data STG_BANK.ACCT_EXCEPTIONS(label="Account Data Quality Exceptions");
  length ACCOUNT_ID $12 CUSTOMER_ID $10 ACCOUNT_TYPE $4 ACCOUNT_STATUS $1
         OPEN_DATE CLOSE_DATE CURRENT_BALANCE AVAILABLE_BALANCE CREDIT_LIMIT
         INTEREST_RATE 8 BRANCH_ID $6 OFFICER_ID $6 LAST_ACTIVITY_DATE 8
         FIRST_NAME $30 LAST_NAME $30 SSN_HASH $32 DATE_OF_BIRTH 8
         CUSTOMER_SEGMENT $4 RISK_RATING 8 REGION_CODE $2 PRIMARY_EMAIL $80
         PHONE_NUMBER $16 ACCT_AGE_MONTHS DAYS_INACTIVE UTILIZATION_PCT 8
         DORMANCY_FLAG $1 HIGH_BALANCE_FLAG $1 SNAPSHOT_DATE LOAD_TIMESTAMP 8;
  format OPEN_DATE CLOSE_DATE LAST_ACTIVITY_DATE DATE_OF_BIRTH SNAPSHOT_DATE date9.
         CURRENT_BALANCE AVAILABLE_BALANCE CREDIT_LIMIT dollar18.2
         LOAD_TIMESTAMP datetime20.;
  stop;
run;
%put NOTE: [env_overrides] OVR-001 applied: STG_BANK.ACCT_EXCEPTIONS shell recreated with the 29-column snapshot shape;
