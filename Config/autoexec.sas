/*=====================================================================
  autoexec.sas — Global Environment Configuration
  Purpose: Library assignments, macro variable initialization,
           system options, and autocall path setup.
  Environment: SAS 9.4 M7 on Linux (RHEL 7)
  Last Modified: 2024-01-15
=====================================================================*/

/* ---------------------------------------------------------------
   System Options
   --------------------------------------------------------------- */
options
  mautosource
  sasautos=("/opt/sas/config/Lev1/SASApp/SASMacro"
            "/opt/sas/custom/macros"
            SASAUTOS)
  mrecall
  mlogic
  mprint
  symbolgen
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
   Base Data Library — Raw Data Landing Zone
   --------------------------------------------------------------- */
libname RAW      "/data/sas/raw"          access=readonly;
libname RAW_BANK "/data/sas/raw/banking"  access=readonly;
libname RAW_INS  "/data/sas/raw/insurance" access=readonly;

/* ---------------------------------------------------------------
   Staging Libraries — Intermediate Processing
   --------------------------------------------------------------- */
libname STAGING  "/data/sas/staging";
libname STG_BANK "/data/sas/staging/banking";
libname STG_INS  "/data/sas/staging/insurance";

/* ---------------------------------------------------------------
   Curated / Reporting Libraries
   --------------------------------------------------------------- */
libname CURATED  "/data/sas/curated";
libname REPORTS  "/data/sas/reports";
libname ARCHIVE  "/data/sas/archive";

/* ---------------------------------------------------------------
   Format Catalogs
   --------------------------------------------------------------- */
libname BANKING  "/data/sas/formats/banking";
libname INSURANCE "/data/sas/formats/insurance";
libname COMMON   "/data/sas/formats/common";

/* ---------------------------------------------------------------
   Database Connections — SAS/ACCESS to Oracle, Teradata
   --------------------------------------------------------------- */
libname ORA_DW oracle
  path="FINPROD"
  schema="DW_BANKING"
  user=&ora_uid
  pw=&ora_pwd
  access=readonly
  readbuff=5000
  insertbuff=2000
;

libname TERA_DW teradata
  server="tdprod.internal.corp"
  database="ANALYTICS"
  user=&tera_uid
  pw=&tera_pwd
  access=readonly
  bulkload=yes
;

/* ---------------------------------------------------------------
   Global Macro Variables
   --------------------------------------------------------------- */
%let ENVIRONMENT = PROD;
%let BASE_PATH   = /data/sas;
%let LOG_PATH    = /data/sas/logs;
%let REPORT_PATH = /data/sas/reports/output;
%let ARCHIVE_PATH= /data/sas/archive;
%let CURR_DT     = %sysfunc(today(), date9.);
%let CURR_YM     = %sysfunc(today(), yymmn6.);
%let PREV_YM     = %sysfunc(intnx(month, %sysfunc(today()), -1), yymmn6.);
%let FY_START    = %sysfunc(intnx(year, %sysfunc(today()), 0, B), date9.);

/* Email notification list */
%let EMAIL_DL    = sas-ops@corp.internal;
%let EMAIL_ONCALL= oncall-data@corp.internal;

/* Batch control */
%let MAX_OBS_WARN = 10000000;
%let ABORT_ON_ERR = Y;

/* ---------------------------------------------------------------
   Autocall Macro Paths
   --------------------------------------------------------------- */
filename MACROS  "/opt/sas/custom/macros";
filename BANKING "/opt/sas/custom/macros/banking";
filename INSURNC "/opt/sas/custom/macros/insurance";
filename UTILITY "/opt/sas/custom/macros/utility";

/* ---------------------------------------------------------------
   Initialization Log
   --------------------------------------------------------------- */
%put NOTE: ========================================;
%put NOTE: autoexec.sas loaded successfully;
%put NOTE: Environment: &ENVIRONMENT;
%put NOTE: Date: &CURR_DT;
%put NOTE: Reporting Period: &PREV_YM;
%put NOTE: ========================================;
