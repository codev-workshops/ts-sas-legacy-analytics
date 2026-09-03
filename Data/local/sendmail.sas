/*=====================================================================
  sendmail.sas — Local no-op override
  Purpose: The production %sendmail routes through an SMTP-enabled SAS
           server. Standalone runs have no mail transport, so this
           definition logs the notification instead of sending it.
           %include this AFTER the autoexec and BEFORE any program that
           can raise a notification.
  Note:    Deliberately accepts and ignores the same keyword parameters
           as Macro/sendmail.sas so call sites need no change.
=====================================================================*/

%macro sendmail(to=, cc=, bcc=, subject=, body=, data=, attach=, from=);
  %put NOTE: [sendmail suppressed] TO=&to SUBJECT=&subject;
  %if %length(&body) %then %put NOTE: [sendmail suppressed] BODY=&body;
%mend sendmail;

%put NOTE: Local no-op %nrstr(%sendmail) override loaded;
