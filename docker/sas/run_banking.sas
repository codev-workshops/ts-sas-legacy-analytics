/*=====================================================================
  run_banking.sas — container driver for the banking pipeline.

  Same sequence as the estate's own Data/run_local_banking.sas
  (formats -> seed load -> local sendmail -> four programs), plus ONE
  extra step: docker/sas/env_overrides.sas between the seed load and
  the programs. The estate itself is not modified; see env_overrides.sas
  for what each override fixes and why.

  Submit (inside the container):
    sas -nodms -noterminal -autoexec Config/autoexec_local.sas
        -set SAS_REPO_ROOT /opt/sas/custom -set SAS_DATA_ROOT /data/sas
        -sysin docker/sas/run_banking.sas
=====================================================================*/

%put NOTE: Running containerised banking pipeline for &CURR_DT;

/* Format catalogs must exist before any program formats a column */
%include "&REPO_ROOT/Formats/banking_formats.sas";

/* ORA_DW / RAW_BANK / CURATED stand-ins, exactly as the estate ships them */
%include "&REPO_ROOT/Data/load_seed_data.sas";

/* Container-environment corrections to the local stand-ins (OVR-nnn) */
%include "&REPO_ROOT/docker/sas/env_overrides.sas";

/* Email is a no-op locally — see Data/local/sendmail.sas */
%include "&REPO_ROOT/Data/local/sendmail.sas";

%include "&REPO_ROOT/Programs/Banking/load_customer_accounts.sas";
%include "&REPO_ROOT/Programs/Banking/daily_transaction_processing.sas";
%include "&REPO_ROOT/Programs/Banking/credit_risk_scoring.sas";
%include "&REPO_ROOT/Programs/Banking/monthly_regulatory_reporting.sas";
