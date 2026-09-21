%macro export_xlsx(data=, path=, file=, sheet=, replace=Y);
  %local out;
  %let out=%sysfunc(tranwrd(%superq(file),.xlsx,_&sheet..csv));
  %if %length(&out)=0 %then %let out=&path;
  %put NOTE: [export_xlsx -> csv] &data => &out;
  proc export data=&data outfile="&out" dbms=csv replace; run;
%mend export_xlsx;
