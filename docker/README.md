# Legacy SAS runtime in Docker

A container that runs this estate's banking pipeline the way the production
batch server does — same `/opt/sas/custom` layout, same `sas -autoexec … -sysin …`
command line, same `/data/sas` library tree — without a SAS licence. It is the
"before" system of the SAS → Databricks migration: it produces the golden
outputs that the converted models are reconciled against.

```
docker compose -f docker/compose.yml build                       # ~5 min first time (builds OpenSAS)
docker compose -f docker/compose.yml run --rm sas                # full banking run + golden export
docker compose -f docker/compose.yml run --rm sas bash           # poke around inside
docker compose -f docker/compose.yml run --rm sas sas -help      # the SAS-style CLI
```

A successful run ends with the eight output row counts and
`run-banking: row counts match /opt/sas/custom/docker/expected/row_counts.csv`.
Anything else is a failure and the container exits non-zero.

## What is inside

| Piece | Where | Notes |
|---|---|---|
| Interpreter | `/usr/local/libexec/opensas/sas` | [OpenSAS](https://github.com/kirha-ai/opensas) `v0.6.5` (Apache-2.0), built from source in stage 1 of the Dockerfile with `docker/opensas/0001-banking-estate-compat.patch` applied (see below). |
| `sas` command | `/usr/local/bin/sas` | Bash wrapper giving OpenSAS the SAS 9.4 batch CLI: `-sysin`, `-autoexec`, `-log`, `-print`, `-set NAME VALUE`, `-sasautos`, and the no-op display flags `-nodms -noterminal -batch -nonews -noovp …`. Anything else is rejected with exit 2 — it never silently ignores a flag. |
| The estate | `/opt/sas/custom` | This repository, copied at build time (read-only in spirit: nothing in the container edits it). `macros/` = `Macro/` + the four shims; `programs/` → `Programs/`, matching the absolute paths hard-coded in the batch jobs. |
| Library tree | `/data/sas` (volume `sasdata`) | Created empty by the entrypoint: `raw/banking`, `staging/banking`, `curated`, `reports/output`, `oracle_dw`, `formats/*`, `logs`, `golden`, … exactly the LIBNAMEs in `Config/autoexec_local.sas`. |
| Driver | `docker/sas/run_banking.sas` via `run-banking` | Formats → `Data/load_seed_data.sas` → `docker/sas/env_overrides.sas` → local `sendmail` → the four `Programs/Banking/*.sas` in dependency order. |
| Golden export | `docker/sas/export_golden.sas` | Writes every output table to `/data/sas/golden/*.csv` plus `row_counts.csv`, `controls.csv`, `manifest.json`. |

The container runs as the unprivileged `sas` user. Environment: `SAS_REPO_ROOT=/opt/sas/custom`,
`SAS_DATA_ROOT=/data/sas`, `SASAUTOS=/opt/sas/custom/macros`.

## `run-banking`

```
run-banking            wipe /data/sas, rebuild the libraries from Data/csv, run, export golden outputs
run-banking --keep     same, but on top of whatever is already in /data/sas
run-banking --check    re-scan the last logs without re-running
```

Exit status is 0 only if all of these hold:

1. the interpreter returned 0;
2. `logs/run_local_banking.log` and `logs/export_golden.log` contain no `ERROR`, no
   `UNSUPPORTED`, and no unresolved macro / symbolic reference;
3. `golden/row_counts.csv` equals `docker/expected/row_counts.csv`.

Business `WARNING`s are expected and do not fail the run; the clean run has ten:
`32 data quality exceptions found`, and nine `PROC APPEND … dropped (FORCE)` lines
(see *Known estate behaviour*).

The wipe-first default exists because the programs *append* into `CURATED.*`; a second run
on the same volume would otherwise double the anomaly and risk-score counts.

### Artifacts (`/data/sas`, volume `sasdata`)

```
logs/run_local_banking.log      full SAS log
logs/run_local_banking.lst      listing (PROC PRINT / summary output)
logs/export_golden.log
logs/row_counts.diff            empty when counts match
golden/stg_bank__cust_accounts_daily.csv     466 rows
golden/stg_bank__acct_exceptions.csv          32
golden/curated__daily_transactions.csv     18903
golden/curated__txn_anomalies.csv             46
golden/curated__risk_scores.csv              236
golden/reports__monthly_rwa.csv               59
golden/reports__delinquency_aging.csv         70
golden/reports__llp_coverage.csv               6
golden/row_counts.csv                         TABLE_NAME,N_ROWS
golden/controls.csv                           anomaly split, txn amount total, RWA total …
golden/manifest.json                          estate commit, runtime, business date, timestamps, counts
reports/output/REG_REPORT_202401_*.csv        what monthly_regulatory_reporting "exported to Excel"
```

Copy them out with `docker cp` from a stopped container, or mount a host directory over
`/data/sas` instead of the named volume. The migration repository's reconciliation harness
consumes `golden/` directly (`verify/reconcile.py --sas-golden <dir>`).

## Compatibility layer — what was needed to run the estate unmodified

None of the programs, formats, seed data or the estate's own driver were changed. Three
kinds of glue sit around them:

### 1. OpenSAS patch (`docker/opensas/0001-banking-estate-compat.patch`)

Generated with `git format-patch v0.6.5` from a local OpenSAS branch; every change ships
with a unit test or corpus fixture and the full OpenSAS suites stay green
(`zig build test && zig build corpus && zig build programs`). What it adds:

| Estate idiom | OpenSAS gap closed |
|---|---|
| `options sasautos=("&REPO_ROOT/Macro" SASAUTOS) mautosource;` | multi-directory autocall, `SASAUTOS=`, `MAUTOSOURCE`/`NOMAUTOSOURCE` |
| `%include "&REPO_ROOT/Formats/banking_formats.sas";` | macro variables resolved inside `%include` paths |
| `select count(*) into :n trimmed from …` | `TRIMMED` on `INTO :` (`NOTRIM` still fails loud) |
| `%let x = %sysfunc(…)` inside macro bodies | `%LET` trims after expansion without eating `%SYSFUNC` result blanks |
| `%macro m /*--- header ---*/ (a, b=2) / minoperator;` | block comment between macro name and parameter list |
| `sum(EAD * calculated RW) as RWA … group by …` | aggregates over a `CALCULATED` non-aggregate alias fold the alias per row (was `.`) |

To bump OpenSAS: change `OPENSAS_REF` in the Dockerfile, re-apply the patch, drop the
hunks that have landed upstream.

### 2. Shims (`docker/shims/*.sas`, copied over `Macro/` into `/opt/sas/custom/macros`)

Operational macros whose production bodies talk to infrastructure the container does not
have. Each shim keeps the production signature so call sites are untouched, and each says
what it did in the log:

| Macro | Production behaviour | Container behaviour |
|---|---|---|
| `%parmv` | full parameter validation library | required-parameter check only; still sets `parmerr` and logs `ERROR:` |
| `%nobs` | `open()/attrn(NLOBS)` with extra options | same core, `mvar=` supported |
| `%lock` | SAS/SHARE-style dataset locking with retries | logs `[lock suppressed]` |
| `%export_xlsx` | `PROC EXPORT dbms=xlsx` (SAS/ACCESS PC Files) | `PROC EXPORT dbms=csv` to `<file>_<sheet>.csv`, logs `[export_xlsx -> csv]` |
| `%sendmail` | SMTP via the SAS server | the estate's own `Data/local/sendmail.sas` no-op (not a container shim) |

### 3. Environment overrides (`docker/sas/env_overrides.sas`)

Corrections to the estate's *local stand-in* environment, applied after the seed loader and
before the programs — the container equivalent of a DBA fixing a landing table. Currently one:

* **OVR-001** `STG_BANK.ACCT_EXCEPTIONS`: `Data/load_seed_data.sas` builds a 5-column shell,
  but `load_customer_accounts.sas` does `insert into STG_BANK.ACCT_EXCEPTIONS select * from
  WORK.ACCT_EXCEPTIONS` with 29 columns — SAS 9.4 rejects that too, so the estate's own
  `Data/run_local_banking.sas` cannot complete as shipped. The override recreates the shell
  in the shape the program writes. This is an estate defect worth carrying into the
  migration's exception list (the exception rows also carry no `EXCEPTION_CODE`, because
  the step's `drop` applies to both output datasets).

## Known estate behaviour (not container issues)

* `PROC APPEND … FORCE` into `CURATED.DAILY_TRANSACTIONS` drops the nine enrichment columns
  (`ACCOUNT_TYPE`, `CUSTOMER_ID`, `PRE_TXN_BALANCE`, …) because the 90-day history in
  `Data/csv/curated/DAILY_TRANSACTIONS.csv` does not have them. SAS 9.4 behaves the same
  way and logs the same warnings. The golden `curated__daily_transactions.csv` therefore has
  the ten history columns.
* `RISK_RATING` is numeric (`RISKRATE.` format) in the estate; a target that models it as
  text has to map it.

## Not supported (fails loud)

* Anything not in the `sas -help` list: `sas -bogus …` → `sas: option '-bogus' is not
  supported by the container runtime`, exit 2.
* SAS/ACCESS engines (`libname ORA_DW oracle …`, Teradata), `PROC EXPORT dbms=xlsx`, real
  e-mail, `%lock` semantics. `Config/autoexec.sas` (the production autoexec) is therefore not
  usable here — the container runs `Config/autoexec_local.sas`, which the estate ships for
  exactly this purpose.
* The insurance programs and `Programs/Reports/customer_profitability.sas` are packaged but
  have no seed data and are not exercised by `run-banking`.
* OpenSAS reports any SAS statement it does not implement as `UNSUPPORTED:` in the log;
  `run-banking` treats that as a failure rather than an omission.
