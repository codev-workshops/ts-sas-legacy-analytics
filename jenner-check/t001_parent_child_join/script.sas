/* Derived from Programs/Parent-Child-Index.sas
   (codev-workshops/ts-sas-legacy-codebase).

   The program models an account parent-child hierarchy: a fact table of
   account amounts joined to a dimension of account names. This bundle ships
   two of the program's own data steps verbatim -- the indexed `source`
   hierarchy and the `dim_acct_names` dimension built with an accumulator and
   `infile datalines dsd dlm="|"` -- and joins them with PROC SQL the same way
   the program joins its fact and dimension tables (a LEFT JOIN on the account
   key). Account names and amounts are the program's own sample data. */

data source (index=(acct));
  length acct parent $3 amount 8;
  input acct parent amount;
  datalines;
A1  .   10
A2  A1  20
A3  A2  30
A4  A2  20
A5  A1  10
A6  A5  10
A7  .   10
A8  A7  20
A9  A7  30
A10 A9  20
A11 A4  5
A12 A9  5
A13 A11 5
A14 A12 5
;
run;

data dim_acct_names (index=(acct name_id));
  length Name_Id 8 Acct $3 Acct_Name $100;
  infile datalines dsd dlm="|";
  input Acct Acct_Name;
  Name_Id+1;
  datalines;
A1  | IBM Australia
A2  | New South Wales
A3  | Newcastle
A4  | Sydney
A5  | Victoria
A6  | Melbourne
A7  | HP India
A8  | Chennai
A9  | New Delhi
A10 | Roganjosh
A11 | CBD
A12 | Vindaloo
A13 | Pitt St. Branch
A14 | Korma
;
run;

proc sql;
  create table fact_named as
  select
     n.acct_name
    ,s.acct
    ,s.parent
    ,s.amount
  from
    source s
  left join
    dim_acct_names n
  on
    s.acct = n.acct
  order by
    s.amount descending, s.acct
  ;
quit;

proc print data=fact_named noobs; run;
