#!/usr/bin/env python3
"""Check the seed data satisfies what Programs/Banking assumes.

Re-implements the entry conditions of each banking program against the
CSVs (referential integrity, the three data-quality exception rules, the
five feed validation rules, the scoring and regulatory populations) so a
broken or regenerated dataset is caught without a SAS licence.

Usage:
    python3 Data/validate_seed_data.py
Exit code 0 when every check passes, 1 otherwise.
"""

import csv
import os
import sys
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
CSV_ROOT = os.path.join(HERE, "csv")
BUSINESS_DATE = datetime(2024, 1, 31).date()

DEPOSIT_TYPES = {"CHK", "SAV", "MMA", "CD", "IRA"}
REVOLVING_TYPES = {"CC", "LOC", "HELC"}
LENDING_TYPES = {"MTG", "AUTO", "PERS", "CC", "LOC", "HELC"}
VALID_TXN_TYPES = {"DEP", "WDR", "TRF", "PMT", "FEE", "INT", "ADJ", "REV", "CHG", "REF"}

failures = []


def check(condition, message):
    status = "ok  " if condition else "FAIL"
    print(f"  [{status}] {message}")
    if not condition:
        failures.append(message)


def read(*parts):
    with open(os.path.join(CSV_ROOT, *parts), newline="") as handle:
        return list(csv.DictReader(handle))


def as_date(value):
    return datetime.strptime(value, "%d%b%Y").date() if value else None


def as_float(value):
    return float(value) if value not in ("", None) else None


def main():
    customers = read("oracle_dw", "CUST_DEMOGRAPHICS.csv")
    accounts = read("oracle_dw", "CUST_ACCOUNTS.csv")
    bureau = read("oracle_dw", "BUREAU_SCORES.csv")
    payments = read("oracle_dw", "PAYMENT_HISTORY.csv")
    collateral = read("oracle_dw", "COLLATERAL.csv")
    loans = read("oracle_dw", "LOAN_DETAILS.csv")
    feed = read("raw_bank", f"TXN_FEED_{BUSINESS_DATE:%Y%m%d}.csv")
    history = read("curated", "DAILY_TRANSACTIONS.csv")

    customer_ids = {c["CUSTOMER_ID"] for c in customers}
    account_ids = {a["ACCOUNT_ID"] for a in accounts}

    print("Referential integrity")
    check(len(customer_ids) == len(customers), "CUST_DEMOGRAPHICS.CUSTOMER_ID is unique")
    check(len(account_ids) == len(accounts), "CUST_ACCOUNTS.ACCOUNT_ID is unique")
    check(all(a["CUSTOMER_ID"] in customer_ids for a in accounts),
          "every account resolves to a customer")
    check(all(b["CUSTOMER_ID"] in customer_ids for b in bureau),
          "every bureau score resolves to a customer")
    for name, rows in (("PAYMENT_HISTORY", payments), ("COLLATERAL", collateral),
                       ("LOAN_DETAILS", loans)):
        check(all(r["ACCOUNT_ID"] in account_ids for r in rows),
              f"every {name} row resolves to an account")
    check(all(t["ACCOUNT_ID"] in account_ids for t in history),
          "every historical transaction resolves to an account")

    print("\nStep 1 — load_customer_accounts snapshot population")
    snapshot = [a for a in accounts
                if a["ACCOUNT_STATUS"] not in ("W", "C")
                and as_date(a["OPEN_DATE"]) <= BUSINESS_DATE]
    check(len(snapshot) > 0, f"snapshot rows: {len(snapshot)}")

    all_by_id = {a["ACCOUNT_ID"]: a for a in accounts}
    by_id = {a["ACCOUNT_ID"]: a for a in snapshot}
    risk_by_customer = {c["CUSTOMER_ID"]: c["RISK_RATING"] for c in customers}

    neg_bal = [a for a in snapshot
               if a["ACCOUNT_TYPE"] in {"CHK", "SAV", "MMA", "CD"}
               and float(a["CURRENT_BALANCE"]) < 0]
    high_util = [a for a in snapshot
                 if a["ACCOUNT_TYPE"] in REVOLVING_TYPES
                 and float(a["CREDIT_LIMIT"]) > 0
                 and float(a["CURRENT_BALANCE"]) / float(a["CREDIT_LIMIT"]) * 100 > 95]
    no_risk = [a for a in snapshot if risk_by_customer[a["CUSTOMER_ID"]] == ""]
    exceptions = len(neg_bal) + len(high_util) + len(no_risk)

    check(len(neg_bal) > 0, f"NEG_BAL exceptions: {len(neg_bal)}")
    check(len(high_util) > 0, f"HIGH_UTIL exceptions: {len(high_util)}")
    check(len(no_risk) > 0, f"NO_RISK exceptions: {len(no_risk)}")
    check(exceptions < 100,
          f"total exceptions {exceptions} stays under the 100-row alert threshold")

    print("\nStep 2 — daily_transaction_processing feed validation")
    rejects = {"missing id": 0, "missing account": 0, "missing amount": 0,
               "over threshold": 0, "invalid type": 0, "future dated": 0}
    accepted = 0
    for txn in feed:
        amount = as_float(txn["TRANSACTION_AMOUNT"])
        if not txn["TRANSACTION_ID"]:
            rejects["missing id"] += 1
        elif not txn["ACCOUNT_ID"]:
            rejects["missing account"] += 1
        elif amount is None:
            rejects["missing amount"] += 1
        elif abs(amount) > 10_000_000:
            rejects["over threshold"] += 1
        elif txn["TRANSACTION_TYPE"] not in VALID_TXN_TYPES:
            rejects["invalid type"] += 1
        elif as_date(txn["TRANSACTION_DATE"]) > BUSINESS_DATE:
            rejects["future dated"] += 1
        else:
            accepted += 1
    for rule, count in rejects.items():
        check(count > 0, f"feed exercises the '{rule}' reject rule ({count} rows)")
    check(accepted > 0, f"accepted feed rows: {accepted}")
    check(all(t["ACCOUNT_ID"] in by_id for t in feed if t["ACCOUNT_ID"]),
          "every feed transaction joins to a snapshot account")

    print("\nStep 3 — credit_risk_scoring inputs")
    scored = [a for a in snapshot if a["ACCOUNT_TYPE"] in LENDING_TYPES]
    bureau_customers = {b["CUSTOMER_ID"] for b in bureau}
    payment_accounts = {p["ACCOUNT_ID"] for p in payments}
    check(len(scored) > 0, f"scoreable accounts: {len(scored)}")
    check(all(a["CUSTOMER_ID"] in bureau_customers for a in scored),
          "every scoreable account has a bureau score")
    check(all(a["ACCOUNT_ID"] in payment_accounts for a in scored),
          "every scoreable account has payment history")

    ltv_source = {c["ACCOUNT_ID"]: float(c["COLLATERAL_VALUE"]) for c in collateral}
    mismatched = [
        loan["ACCOUNT_ID"] for loan in loans
        if loan["LTV"] and loan["ACCOUNT_ID"] in ltv_source
        and abs(float(loan["LTV"])
                - float(all_by_id[loan["ACCOUNT_ID"]]["CURRENT_BALANCE"])
                / ltv_source[loan["ACCOUNT_ID"]]) > 0.0001
    ]
    check(not mismatched,
          "LOAN_DETAILS.LTV agrees with balance / COLLATERAL_VALUE")

    print("\nStep 4 — monthly_regulatory_reporting populations")
    loans_by_id = {loan["ACCOUNT_ID"]: loan for loan in loans}
    delinquent = [loan for loan in loans if int(loan["DAYS_PAST_DUE"]) > 0]
    npl = [loan for loan in loans if int(loan["DAYS_PAST_DUE"]) >= 90]
    check(len(delinquent) > 0, f"delinquent loans: {len(delinquent)}")
    check(len(npl) > 0, f"non-performing loans (90+ DPD): {len(npl)}")
    check(all(a["ACCOUNT_ID"] in loans_by_id for a in scored),
          "every lending account has a LOAN_DETAILS row for RWA and aging")
    check(all(float(loan["ALLOWANCE_AMT"]) >= 0 for loan in loans),
          "loan loss allowances are non-negative")

    print("\nAnomaly baseline")
    feed_accounts = {t["ACCOUNT_ID"] for t in feed if t["ACCOUNT_ID"]}
    history_accounts = {t["ACCOUNT_ID"] for t in history}
    covered = len(feed_accounts & history_accounts) / max(len(feed_accounts), 1)
    check(covered > 0.9,
          f"{covered:.0%} of feed accounts have 90-day history for z-scores")
    earliest = min(as_date(t["TRANSACTION_DATE"]) for t in history)
    check((BUSINESS_DATE - earliest).days <= 90,
          f"history starts {(BUSINESS_DATE - earliest).days} days back, within the z-score window")

    print()
    if failures:
        print(f"{len(failures)} check(s) failed:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("All seed data checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
