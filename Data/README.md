# Seed Data — Banking

Everything the `Programs/Banking/` pipeline reads, as CSV. The production
programs source their inputs from Oracle (`ORA_DW`), a daily flat-file feed
(`RAW_BANK`) and the curated history (`CURATED`); this directory supplies the
same members and columns from files so the estate runs with nothing but Base
SAS.

The legacy programs are **unmodified** — they are the migration source of
truth. Standalone execution works by recreating the paths they expect
(`/opt/sas/custom/...`, `/data/sas/...`) rather than by rewriting them.

## Layout

```
Data/
├── csv/
│   ├── oracle_dw/                 # stands in for the SAS/ACCESS Oracle libref
│   │   ├── CUST_ACCOUNTS.csv      # 487 accounts across 250 customers
│   │   ├── CUST_DEMOGRAPHICS.csv  # segment, region, risk rating
│   │   ├── BUREAU_SCORES.csv      # FICO/Vantage, two score dates per customer
│   │   ├── PAYMENT_HISTORY.csv    # 12-month delinquency counters
│   │   ├── COLLATERAL.csv         # secured-loan appraisals (MTG/AUTO/HELC)
│   │   └── LOAN_DETAILS.csv       # DPD, past-due, allowance, LTV
│   ├── raw_bank/
│   │   ├── TXN_FEED_20240131.csv  # the daily feed for the business date
│   │   └── DAILY_RATES.csv        # PRIME/SOFR/FEDFUNDS/MTG_30YR history
│   └── curated/
│       └── DAILY_TRANSACTIONS.csv # 90 days of prior activity (z-score baseline)
├── local/sendmail.sas             # no-op %sendmail for hosts with no SMTP
├── generate_seed_data.py          # deterministic regeneration
├── validate_seed_data.py          # checks the data against the programs' assumptions
├── load_seed_data.sas             # CSV -> ORA_DW / RAW_BANK / CURATED
├── run_local_banking.sas          # formats -> load -> 4 banking programs -> counts
└── bootstrap_local_env.sh         # creates /data/sas and /opt/sas/custom, then runs the above
```

## Business date

All data is generated for **31JAN2024**, which `Config/autoexec_local.sas` sets
as `CURR_DT`. `PREV_YM` is deliberately set to `202401` (not December) so that
`monthly_regulatory_reporting`'s month-end matches the account snapshot date —
otherwise the regulatory report reads an empty snapshot.

## Running the pipeline

```bash
./Data/bootstrap_local_env.sh          # needs sudo for /data/sas and /opt/sas
```

Or, when the paths already exist:

```bash
sas -autoexec Config/autoexec_local.sas \
    -set SAS_REPO_ROOT "$PWD" \
    -sysin Data/run_local_banking.sas
```

`SAS_DATA_ROOT` relocates the library tree (defaults to `/data/sas`). Note that
`Formats/banking_formats.sas` hard-codes `/data/sas/formats/banking`, so a
relocated root writes the catalog to the legacy path regardless.

`run_local_banking.sas` builds the format catalog, loads the seed data, runs
`load_customer_accounts` → `daily_transaction_processing` →
`credit_risk_scoring` → `monthly_regulatory_reporting`, and prints the output
row counts — the numbers to reconcile against a migrated Snowflake or
Databricks target.

## What the data deliberately exercises

| Program | Behaviour | Seeded so that |
|---|---|---|
| `load_customer_accounts` | `NEG_BAL` exception | overdrawn deposit accounts exist |
| | `HIGH_UTIL` exception | revolving accounts sit above 95% utilisation |
| | `NO_RISK` exception | ~4% of customers have no risk rating |
| | exception email | the total stays under the 100-row alert threshold |
| | `DORMANCY_FLAG` | some accounts have >365 days of inactivity |
| `daily_transaction_processing` | all five reject rules | the feed carries rows with a missing ID, missing account, missing amount, an amount over $10M, an invalid type, and a future date |
| | `HIGH_AMOUNT` / `OVERDRAFT` anomalies | outsized withdrawals against 90 days of baseline history |
| `credit_risk_scoring` | every scorecard branch | FICO, utilisation, DPD, account age and LTV bands are all populated, including underwater LTVs |
| `monthly_regulatory_reporting` | every delinquency bucket and risk weight | DPD spans 0 to 400 days across all account types; NPLs (90+ DPD) are present |

## Regenerating

```bash
python3 Data/generate_seed_data.py      # deterministic: same seed, same bytes
python3 Data/validate_seed_data.py      # exit 1 if the data breaks any assumption
```

`validate_seed_data.py` re-implements the entry conditions of each program
(referential integrity, the three exception rules, the five feed validation
rules, the scoring and regulatory populations) so the dataset can be checked
without a SAS licence.

## Known limitations

- `monthly_regulatory_reporting` finishes by calling `%export_xlsx`, which needs
  SAS/ACCESS to PC Files. Without it, the four report tables are still built in
  `REPORTS`; only the workbook export fails.
- Insurance (`RAW_INS`, `Programs/Insurance/`) has no seed data yet — this
  covers the banking pipeline only.
- `TERA_DW` is declared as an empty local library; no program under
  `Programs/Banking/` reads from it.
