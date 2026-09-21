%macro lock(member, action, timeout=, retry=, onFail=, unlock=, email=);
  %put NOTE: [lock suppressed] &member &action;
%mend lock;
