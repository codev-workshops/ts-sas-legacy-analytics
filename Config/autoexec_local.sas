/*=====================================================================
  autoexec_local.sas — Standalone / Non-Production Environment
  Purpose: Same library and macro-variable contract as autoexec.sas,
           but every library is a local directory under &DATA_ROOT and
           the Oracle/Teradata SAS/ACCESS engines are replaced by BASE
           libraries loaded from the CSV seed data in Data/csv.
           Lets Programs/Banking run end to end without a warehouse.
  Environment: any SAS 9.4 M5+ (Base SAS, SAS OnDemand, SAS Viya)
  Usage: sas -autoexec Config/autoexec_local.sas \
             -set SAS_REPO_ROOT /path/to/ts-sas-legacy-analytics
=====================================================================*/

/* ---------------------------------------------------------------
   Roots — overridable with -set so nothing is hard-coded to a host
   --------------------------------------------------------------- */
%let REPO_ROOT = %sysget(SAS_REPO_ROOT);
%if %length(&REPO_ROOT) = 0 %then %let REPO_ROOT = /opt/sas/custom;

%let DATA_ROOT = %sysget(SAS_DATA_ROOT);
%if %length(&DATA_ROOT) = 0 %then %let DATA_ROOT = /data/sas;

/* ---------------------------------------------------------------
   System Options — mirrors production except for the autocall path
   --------------------------------------------------------------- */
options
  mautosource
  sasautos=("&REPO_ROOT/Macro" SASAUTOS)
  mrecall
  mprint
  compress=yes
  fmtsearch=(BANKING INSURANCE COMMON WORK LIBRARY)
  validvarname=v7
  nofmterr
  yearcutoff=1920
  obs=MAX
  msglevel=i
  noerrorabend
;

/* ---------------------------------------------------------------
   Libraries — local directories, created by bootstrap_local_env.sh
   --------------------------------------------------------------- */
libname RAW      "&DATA_ROOT/raw";
libname RAW_BANK "&DATA_ROOT/raw/banking";
libname RAW_INS  "&DATA_ROOT/raw/insurance";

libname STAGING  "&DATA_ROOT/staging";
libname STG_BANK "&DATA_ROOT/staging/banking";
libname STG_INS  "&DATA_ROOT/staging/insurance";

libname CURATED  "&DATA_ROOT/curated";
libname REPORTS  "&DATA_ROOT/reports";
libname ARCHIVE  "&DATA_ROOT/archive";

libname BANKING  "&DATA_ROOT/formats/banking";
libname INSURANCE "&DATA_ROOT/formats/insurance";
libname COMMON   "&DATA_ROOT/formats/common";

/* Stand-ins for the SAS/ACCESS warehouse librefs. Same member names
   and columns as production, loaded from Data/csv by load_seed_data.sas. */
libname ORA_DW  "&DATA_ROOT/oracle_dw";
libname TERA_DW "&DATA_ROOT/teradata_dw";

/* ---------------------------------------------------------------
   Global Macro Variables
   The seed data is generated for a fixed business date so that
   every run produces the same exceptions, anomalies and report.
   --------------------------------------------------------------- */
%let ENVIRONMENT = LOCAL;
%let BASE_PATH   = &DATA_ROOT;
%let LOG_PATH    = &DATA_ROOT/logs;
%let REPORT_PATH = &DATA_ROOT/reports/output;
%let ARCHIVE_PATH= &DATA_ROOT/archive;
%let CURR_DT     = 31JAN2024;
%let CURR_YM     = 202401;
%let PREV_YM     = 202401;
%let FY_START    = 01JAN2024;

%let EMAIL_DL    = sas-ops@corp.internal;
%let EMAIL_ONCALL= oncall-data@corp.internal;

%let MAX_OBS_WARN = 10000000;
%let ABORT_ON_ERR = Y;

/* ---------------------------------------------------------------
   Autocall Macro Paths
   --------------------------------------------------------------- */
filename MACROS "&REPO_ROOT/Macro";

%put NOTE: ========================================;
%put NOTE: autoexec_local.sas loaded successfully;
%put NOTE: Environment: &ENVIRONMENT;
%put NOTE: Repo Root: &REPO_ROOT;
%put NOTE: Data Root: &DATA_ROOT;
%put NOTE: Business Date: &CURR_DT;
%put NOTE: Reporting Period: &PREV_YM;
%put NOTE: ========================================;
