/*=====================================================================
  insurance_formats.sas — Custom Formats for Insurance Domain
  Purpose: Define value formats for policy types, claim status,
           coverage codes, and actuarial risk categories.
  Output: Format catalog INSURANCE.FORMATS
  Last Modified: 2024-01-10
=====================================================================*/

libname INSURANCE "/data/sas/formats/insurance";

proc format library=INSURANCE;

  /* Policy Type */
  value $POLTYPE
    'WL'   = 'Whole Life'
    'TL'   = 'Term Life'
    'UL'   = 'Universal Life'
    'VL'   = 'Variable Life'
    'AUTO'  = 'Auto Insurance'
    'HOME'  = 'Homeowners'
    'RENT'  = 'Renters'
    'UMBR'  = 'Umbrella'
    'HLTH'  = 'Health'
    'DNTL'  = 'Dental'
    'VIS'   = 'Vision'
    'DISAB' = 'Disability'
    'LTCI'  = 'Long-Term Care'
    OTHER   = 'Unknown'
  ;

  /* Claim Status */
  value $CLMSTAT
    'NEW'  = 'New'
    'OPEN' = 'Open'
    'INV'  = 'Under Investigation'
    'ADJ'  = 'Adjusting'
    'PEND' = 'Pending Approval'
    'APPR' = 'Approved'
    'DENY' = 'Denied'
    'PAID' = 'Paid'
    'CLOS' = 'Closed'
    'REOP' = 'Reopened'
    'SUSP' = 'Suspended'
    'LITI' = 'In Litigation'
    OTHER  = 'Unknown'
  ;

  /* Risk Category */
  value $RISKCAT
    'STD'  = 'Standard'
    'PREF' = 'Preferred'
    'SPRM' = 'Super Preferred'
    'SUB'  = 'Substandard'
    'DEC'  = 'Declined'
    OTHER  = 'Unrated'
  ;

  /* Coverage Type */
  value $COVTYPE
    'COMP' = 'Comprehensive'
    'COLL' = 'Collision'
    'LIAB' = 'Liability'
    'PIP'  = 'Personal Injury Protection'
    'UMBI' = 'Uninsured Motorist BI'
    'UMPD' = 'Uninsured Motorist PD'
    'MED'  = 'Medical Payments'
    'TOW'  = 'Towing'
    'RENT' = 'Rental Reimbursement'
    OTHER  = 'Other'
  ;

  /* Loss Amount Ranges */
  value LOSSRANGE
    LOW-<0          = 'Recovery'
    0               = 'No Loss'
    0<-<5000        = '$0-$4,999'
    5000-<25000     = '$5K-$24,999'
    25000-<100000   = '$25K-$99,999'
    100000-<500000  = '$100K-$499,999'
    500000-HIGH     = '$500K+'
  ;

run;

%put NOTE: Insurance formats loaded to INSURANCE.FORMATS;
