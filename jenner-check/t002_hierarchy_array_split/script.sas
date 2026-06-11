/* Derived from Programs/Parent-Child-Index.sas
   (codev-workshops/ts-sas-legacy-codebase).

   A distinctive step in the program flattens a "|"-delimited account
   hierarchy path into one column per level (Lev1, Lev2, ...). It walks an
   array with `scan(hier, i, "|")` and forward-fills missing levels to mimic
   a COALESCE, so that a short path is padded to full depth. This bundle ships
   that transformation verbatim, fed by the `hier` paths the program derives
   for its own sample accounts. */

data option2;
  length acct $3 hier $200;
  input acct $ hier $;
  datalines;
A1 A1
A2 A1|A2
A3 A1|A2|A3
A4 A1|A2|A4
A5 A1|A5
A6 A1|A5|A6
A7 A7
A8 A7|A8
A9 A7|A9
A10 A7|A9|A10
;
run;

%let max_hier=3;

data dim_acct;
  length Lev1-Lev&max_hier $3;
  set option2;
  array lev{*} Lev1-Lev&max_hier;
  do i=1 to dim(lev);
    lev{i}=scan(hier,i,"|");
    if missing(lev{i}) then lev{i}=lev{i-1};  * mimic coalesce function ;
  end;
  keep Lev1-Lev&max_hier acct;
run;

proc print data=dim_acct noobs; run;
