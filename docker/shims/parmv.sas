%macro parmv(_parm, _val=, _req=0, _words=0, _case=U, _msg=, _varchk=0, _def=);
  %global parmerr s_msg;
  %if %length(&parmerr)=0 %then %let parmerr=0;
  %if &_req=1 and %length(&&&_parm)=0 %then %do;
    %let parmerr=1;
    %put ERROR: [parmv] &_parm is required. &_msg;
  %end;
%mend parmv;
