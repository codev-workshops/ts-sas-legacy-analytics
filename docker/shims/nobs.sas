/*=====================================================================
  nobs.sas — Container stand-in for Macro/nobs.sas
  Purpose: Return the observation count of a dataset as a function-style
           macro. The production %nobs relies on %GOTO-based parameter
           validation that the container runtime (OpenSAS) does not
           implement; this version keeps the same call signature.
=====================================================================*/
%macro nobs(data, mvar=)/minoperator;
%local dsid rc n;%let n=0;%let dsid=%sysfunc(open(&data));%if &dsid > 0 %then %do;%let n=%sysfunc(attrn(&dsid,NLOBS));%let rc=%sysfunc(close(&dsid));%end;%if %length(&mvar) %then %do;%global &mvar;%let &mvar=&n;%end;%else &n;%mend nobs;
