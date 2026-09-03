/*=====================================================================
  banking_formats.sas — Custom Formats for Banking Domain
  Purpose: Define value formats and informats used across
           all banking programs for account types, status codes,
           risk ratings, and transaction categories.
  Output: Format catalog BANKING.FORMATS
  Last Modified: 2024-01-10
=====================================================================*/

libname BANKING "/data/sas/formats/banking";

proc format library=BANKING;

  /* Account Type Codes */
  value $ACCTTYPE
    'CHK'  = 'Checking'
    'SAV'  = 'Savings'
    'MMA'  = 'Money Market'
    'CD'   = 'Certificate of Deposit'
    'IRA'  = 'Individual Retirement'
    'LOC'  = 'Line of Credit'
    'MTG'  = 'Mortgage'
    'AUTO' = 'Auto Loan'
    'PERS' = 'Personal Loan'
    'CC'   = 'Credit Card'
    'HELC' = 'Home Equity LOC'
    OTHER  = 'Unknown'
  ;

  /* Account Status */
  value $ACCTSTAT
    'A'  = 'Active'
    'C'  = 'Closed'
    'D'  = 'Dormant'
    'F'  = 'Frozen'
    'R'  = 'Restricted'
    'S'  = 'Suspended'
    'P'  = 'Pending'
    'W'  = 'Written Off'
    OTHER = 'Unknown'
  ;

  /* Risk Rating */
  value RISKRATE
    1    = 'Minimal Risk'
    2    = 'Low Risk'
    3    = 'Moderate Risk'
    4    = 'Elevated Risk'
    5    = 'High Risk'
    6    = 'Very High Risk'
    7    = 'Loss Expected'
    OTHER = 'Not Rated'
  ;

  /* Transaction Category */
  value $TXNCAT
    'DEP'  = 'Deposit'
    'WDR'  = 'Withdrawal'
    'TRF'  = 'Transfer'
    'PMT'  = 'Payment'
    'FEE'  = 'Fee'
    'INT'  = 'Interest'
    'ADJ'  = 'Adjustment'
    'REV'  = 'Reversal'
    'CHG'  = 'Charge'
    'REF'  = 'Refund'
    OTHER  = 'Other'
  ;

  /* Delinquency Buckets */
  value DELQBKT
    0        = 'Current'
    1-29     = '1-29 Days'
    30-59    = '30-59 Days'
    60-89    = '60-89 Days'
    90-119   = '90-119 Days'
    120-179  = '120-179 Days'
    180-HIGH = '180+ Days'
  ;

  /* Balance Ranges for Reporting */
  value BALRANGE
    LOW-<0        = 'Negative'
    0             = 'Zero'
    0<-<1000      = '$0-$999'
    1000-<5000    = '$1K-$4,999'
    5000-<25000   = '$5K-$24,999'
    25000-<100000 = '$25K-$99,999'
    100000-<500000= '$100K-$499,999'
    500000-HIGH   = '$500K+'
  ;

  /* Branch Region */
  value $REGION
    'NE' = 'Northeast'
    'SE' = 'Southeast'
    'MW' = 'Midwest'
    'SW' = 'Southwest'
    'W'  = 'West'
    'NW' = 'Northwest'
    'HQ' = 'Headquarters'
    OTHER = 'Unknown'
  ;

  /* Customer Segment */
  value $CUSTSEG
    'RET'  = 'Retail'
    'PREM' = 'Premium'
    'PB'   = 'Private Banking'
    'SMB'  = 'Small Business'
    'COMM' = 'Commercial'
    'CORP' = 'Corporate'
    OTHER  = 'Unclassified'
  ;

  /* Loan Purpose */
  value $LNPURP
    'PURCH' = 'Purchase'
    'REFI'  = 'Refinance'
    'CASHOUT'= 'Cash-Out Refinance'
    'CONST' = 'Construction'
    'RENO'  = 'Renovation'
    'CONSOL'= 'Debt Consolidation'
    'EDUC'  = 'Education'
    'MEDIC' = 'Medical'
    OTHER   = 'Other'
  ;

run;

%put NOTE: Banking formats loaded to BANKING.FORMATS;
