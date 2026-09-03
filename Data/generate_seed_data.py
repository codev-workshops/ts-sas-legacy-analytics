#!/usr/bin/env python3
"""Generate the deterministic banking seed data used by Programs/Banking.

Produces the CSV extracts that stand in for the Oracle DW source tables, the
daily raw transaction feed, and the curated transaction history that the
anomaly z-score baseline reads. Output is byte-for-byte reproducible: the RNG
is seeded and rows are written in a fixed order.

Usage:
    python3 Data/generate_seed_data.py [--out Data/csv]
"""

import argparse
import csv
import hashlib
import os
import random
from datetime import date, timedelta

BUSINESS_DATE = date(2024, 1, 31)
HISTORY_DAYS = 90
N_CUSTOMERS = 250
SEED = 20240131

DEPOSIT_TYPES = ("CHK", "SAV", "MMA", "CD", "IRA")
REVOLVING_TYPES = ("CC", "LOC", "HELC")
TERM_TYPES = ("MTG", "AUTO", "PERS")
SECURED_TYPES = ("MTG", "AUTO", "HELC")

ACCOUNT_TYPE_WEIGHTS = {
    "CHK": 22, "SAV": 16, "MMA": 6, "CD": 5, "IRA": 4,
    "CC": 18, "LOC": 4, "HELC": 4,
    "MTG": 9, "AUTO": 7, "PERS": 5,
}
STATUS_WEIGHTS = {"A": 85, "D": 4, "F": 2, "R": 2, "S": 2, "P": 1, "C": 3, "W": 1}
REGIONS = ("NE", "SE", "MW", "SW", "W", "NW")
SEGMENTS = ("RET", "PREM", "PB", "SMB", "COMM", "CORP")
LOAN_PURPOSES = ("PURCH", "REFI", "CASHOUT", "CONST", "RENO", "CONSOL", "EDUC", "MEDIC")
CHANNELS = ("BRANCH", "ATM", "ONLINE", "MOBILE", "ACH", "WIRE", "POS")
MERCHANT_CATEGORIES = ("5411", "5541", "5812", "5912", "6011", "7011", "4900", "0000")

FIRST_NAMES = (
    "James", "Mary", "Robert", "Patricia", "John", "Jennifer", "Michael", "Linda",
    "David", "Elizabeth", "William", "Barbara", "Richard", "Susan", "Joseph",
    "Jessica", "Thomas", "Sarah", "Charles", "Karen", "Daniel", "Nancy", "Matthew",
    "Lisa", "Anthony", "Betty", "Mark", "Margaret", "Donald", "Sandra", "Steven",
    "Ashley", "Paul", "Kimberly", "Andrew", "Emily", "Joshua", "Donna", "Kenneth",
    "Michelle", "Kevin", "Carol", "Brian", "Amanda", "George", "Dorothy", "Edward",
    "Melissa", "Ronald", "Deborah",
)
LAST_NAMES = (
    "Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis",
    "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez", "Wilson", "Anderson",
    "Thomas", "Taylor", "Moore", "Jackson", "Martin", "Lee", "Perez", "Thompson",
    "White", "Harris", "Sanchez", "Clark", "Ramirez", "Lewis", "Robinson", "Walker",
    "Young", "Allen", "King", "Wright", "Scott", "Torres", "Nguyen", "Hill",
    "Flores", "Green", "Adams", "Nelson", "Baker", "Hall", "Rivera", "Campbell",
    "Mitchell", "Carter", "Roberts",
)

MONTHS = ("JAN", "FEB", "MAR", "APR", "MAY", "JUN",
          "JUL", "AUG", "SEP", "OCT", "NOV", "DEC")


def sas_date(value):
    """Format a date as a SAS DATE9. literal, or empty for a missing value."""
    if value is None:
        return ""
    return f"{value.day:02d}{MONTHS[value.month - 1]}{value.year}"


def money(value):
    return f"{value:.2f}"


def weighted_choice(rng, weights):
    population = list(weights)
    return rng.choices(population, weights=[weights[k] for k in population], k=1)[0]


def write_csv(path, header, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(header)
        writer.writerows(rows)
    print(f"  {path}: {len(rows)} rows")


def build_customers(rng):
    customers = []
    for i in range(1, N_CUSTOMERS + 1):
        customer_id = f"C{i:07d}"
        first = rng.choice(FIRST_NAMES)
        last = rng.choice(LAST_NAMES)
        segment = rng.choices(SEGMENTS, weights=[55, 18, 6, 11, 7, 3], k=1)[0]
        # 4% of customers have no risk rating -> NO_RISK exceptions downstream.
        risk_rating = "" if rng.random() < 0.04 else rng.choices(
            [1, 2, 3, 4, 5, 6, 7], weights=[12, 22, 27, 18, 11, 7, 3], k=1)[0]
        customers.append({
            "CUSTOMER_ID": customer_id,
            "FIRST_NAME": first,
            "LAST_NAME": last,
            "SSN_HASH": hashlib.sha256(f"{customer_id}-ssn".encode()).hexdigest()[:32],
            "DATE_OF_BIRTH": BUSINESS_DATE - timedelta(days=rng.randint(21, 78) * 365 + rng.randint(0, 364)),
            "CUSTOMER_SEGMENT": segment,
            "RISK_RATING": risk_rating,
            "REGION_CODE": rng.choice(REGIONS),
            "PRIMARY_EMAIL": f"{first.lower()}.{last.lower()}{i}@example.com",
            "PHONE_NUMBER": f"555-{rng.randint(200, 989):03d}-{rng.randint(0, 9999):04d}",
        })
    return customers


def build_accounts(rng, customers):
    accounts = []
    seq = 0
    for customer in customers:
        for _ in range(rng.choices([1, 2, 3, 4], weights=[35, 38, 20, 7], k=1)[0]):
            seq += 1
            account_type = weighted_choice(rng, ACCOUNT_TYPE_WEIGHTS)
            status = weighted_choice(rng, STATUS_WEIGHTS)
            open_date = BUSINESS_DATE - timedelta(days=rng.randint(45, 6200))
            close_date = None
            if status in ("C", "W"):
                close_date = open_date + timedelta(days=rng.randint(30, 3000))
                if close_date > BUSINESS_DATE:
                    close_date = BUSINESS_DATE - timedelta(days=rng.randint(1, 90))

            credit_limit = 0.0
            if account_type == "CC":
                credit_limit = float(rng.choice([1500, 3000, 5000, 7500, 10000, 15000, 25000]))
                balance = round(credit_limit * rng.betavariate(2, 3), 2)
            elif account_type == "LOC":
                credit_limit = float(rng.choice([10000, 25000, 50000, 100000]))
                balance = round(credit_limit * rng.betavariate(2, 4), 2)
            elif account_type == "HELC":
                credit_limit = float(rng.choice([50000, 75000, 100000, 150000, 250000]))
                balance = round(credit_limit * rng.betavariate(2, 4), 2)
            elif account_type == "MTG":
                balance = round(rng.uniform(85000, 850000), 2)
            elif account_type == "AUTO":
                balance = round(rng.uniform(4000, 62000), 2)
            elif account_type == "PERS":
                balance = round(rng.uniform(1500, 45000), 2)
            elif account_type in ("MMA", "CD", "IRA"):
                balance = round(rng.lognormvariate(10.5, 1.1), 2)
            else:
                balance = round(rng.lognormvariate(8.4, 1.4), 2)

            # A handful of deposit accounts are overdrawn -> NEG_BAL exceptions.
            if account_type in DEPOSIT_TYPES and status == "A" and rng.random() < 0.035:
                balance = -round(rng.uniform(25, 2400), 2)
            # A handful of revolving accounts are over limit -> HIGH_UTIL exceptions.
            if account_type in REVOLVING_TYPES and status == "A" and rng.random() < 0.07:
                balance = round(credit_limit * rng.uniform(0.96, 1.08), 2)

            if account_type in REVOLVING_TYPES:
                available = round(max(credit_limit - balance, 0.0), 2)
            else:
                available = round(max(balance - rng.uniform(0, 250), 0.0), 2)

            rates = {
                "CHK": 0.0010, "SAV": 0.0325, "MMA": 0.0410, "CD": 0.0485, "IRA": 0.0450,
                "CC": 0.2249, "LOC": 0.1150, "HELC": 0.0895,
                "MTG": 0.0665, "AUTO": 0.0795, "PERS": 0.1395,
            }
            interest_rate = round(rates[account_type] * rng.uniform(0.88, 1.12), 4)

            last_activity = BUSINESS_DATE - timedelta(days=rng.choices(
                [rng.randint(0, 14), rng.randint(15, 120), rng.randint(121, 364), rng.randint(366, 900)],
                weights=[62, 24, 9, 5], k=1)[0])
            if last_activity < open_date:
                last_activity = open_date

            accounts.append({
                "ACCOUNT_ID": f"A{seq:08d}",
                "CUSTOMER_ID": customer["CUSTOMER_ID"],
                "ACCOUNT_TYPE": account_type,
                "ACCOUNT_STATUS": status,
                "OPEN_DATE": open_date,
                "CLOSE_DATE": close_date,
                "CURRENT_BALANCE": balance,
                "AVAILABLE_BALANCE": available,
                "CREDIT_LIMIT": credit_limit,
                "INTEREST_RATE": interest_rate,
                "BRANCH_ID": f"B{rng.randint(1, 48):03d}",
                "OFFICER_ID": f"O{rng.randint(1, 120):04d}",
                "LAST_ACTIVITY_DATE": last_activity,
            })
    return accounts


def build_bureau_scores(rng, customers):
    rows = []
    for customer in customers:
        base_fico = rng.randint(520, 830)
        for score_date in (date(2023, 10, 31), date(2023, 12, 31)):
            fico = max(300, min(850, base_fico + rng.randint(-18, 18)))
            rows.append([
                customer["CUSTOMER_ID"],
                sas_date(score_date),
                fico,
                max(300, min(850, fico + rng.randint(-25, 25))),
                rng.choices([0, 1, 2, 3, 5, 8], weights=[38, 26, 16, 10, 7, 3], k=1)[0],
                rng.randint(1, 24),
                rng.choices([0, 1, 2, 4], weights=[74, 15, 8, 3], k=1)[0],
                f"{rng.uniform(2, 98):.2f}",
                rng.randint(6, 420),
            ])
    return rows


def build_payment_history(rng, accounts):
    rows = []
    for account in accounts:
        if account["ACCOUNT_TYPE"] not in REVOLVING_TYPES + TERM_TYPES:
            continue
        late30 = rng.choices([0, 1, 2, 3, 5], weights=[70, 16, 8, 4, 2], k=1)[0]
        late60 = 0 if late30 == 0 else rng.randint(0, max(1, late30 - 1))
        late90 = 0 if late60 == 0 else rng.randint(0, late60)
        ontime = max(0, 12 - late30)
        max_dpd = 0 if late30 == 0 else rng.choice([31, 45, 62, 91, 128, 185])
        rows.append([
            account["ACCOUNT_ID"],
            ontime, late30, late60, late90, max_dpd,
            "" if max_dpd == 0 else rng.randint(1, 36),
            f"{rng.uniform(0.05, 1.0):.4f}",
        ])
    return rows


def build_collateral(rng, accounts):
    rows = []
    for account in accounts:
        if account["ACCOUNT_TYPE"] not in SECURED_TYPES:
            continue
        # LTV mostly healthy, with a tail of underwater loans.
        ltv = rng.choices(
            [rng.uniform(0.30, 0.60), rng.uniform(0.60, 0.80),
             rng.uniform(0.80, 1.00), rng.uniform(1.00, 1.25)],
            weights=[26, 44, 22, 8], k=1)[0]
        value = round(max(account["CURRENT_BALANCE"], 1000.0) / ltv, 2)
        rows.append([
            account["ACCOUNT_ID"],
            money(value),
            sas_date(BUSINESS_DATE - timedelta(days=rng.randint(30, 1500))),
        ])
    return rows


def build_loan_details(rng, accounts):
    rows = []
    for account in accounts:
        if account["ACCOUNT_TYPE"] not in REVOLVING_TYPES + TERM_TYPES:
            continue
        days_past_due = rng.choices(
            [0, rng.randint(1, 29), rng.randint(30, 59), rng.randint(60, 89),
             rng.randint(90, 119), rng.randint(120, 179), rng.randint(180, 400)],
            weights=[78, 9, 5, 3, 2, 2, 1], k=1)[0]
        balance = max(account["CURRENT_BALANCE"], 0.0)
        past_due = 0.0 if days_past_due == 0 else round(balance * rng.uniform(0.01, 0.09), 2)
        if days_past_due >= 90:
            allowance = round(balance * rng.uniform(0.25, 0.65), 2)
        elif days_past_due >= 30:
            allowance = round(balance * rng.uniform(0.05, 0.20), 2)
        else:
            allowance = round(balance * rng.uniform(0.004, 0.02), 2)
        orig_date = account["OPEN_DATE"]
        rows.append([
            account["ACCOUNT_ID"],
            rng.choice(LOAN_PURPOSES),
            money(round(balance * rng.uniform(1.05, 1.9), 2)),
            sas_date(orig_date),
            rng.choice([12, 24, 36, 48, 60, 84, 120, 180, 240, 360]),
            "",  # LTV is filled in from the collateral file by the caller
            days_past_due,
            money(past_due),
            money(allowance),
        ])
    return rows


def _txn_amount(rng, account_type, txn_type):
    if txn_type in ("FEE", "CHG"):
        return round(rng.choice([3.00, 9.95, 12.00, 25.00, 35.00]), 2)
    if txn_type == "INT":
        return round(rng.uniform(0.15, 240.00), 2)
    if account_type in ("MTG", "AUTO", "PERS"):
        return round(rng.uniform(180, 3200), 2)
    if account_type in REVOLVING_TYPES:
        return round(rng.uniform(8, 1800), 2)
    return round(rng.lognormvariate(4.2, 1.3), 2)


def _txn_row(rng, seq, account, txn_date, prefix):
    account_type = account["ACCOUNT_TYPE"]
    if account_type in DEPOSIT_TYPES:
        txn_type = rng.choices(
            ["DEP", "WDR", "TRF", "FEE", "INT", "ADJ", "REV"],
            weights=[30, 34, 18, 8, 6, 2, 2], k=1)[0]
    else:
        txn_type = rng.choices(
            ["PMT", "CHG", "FEE", "INT", "REF", "ADJ"],
            weights=[38, 34, 10, 12, 4, 2], k=1)[0]
    amount = _txn_amount(rng, account_type, txn_type)
    if txn_type in ("TRF", "ADJ") and rng.random() < 0.5:
        amount = -amount
    return [
        f"{prefix}{seq:09d}",
        account["ACCOUNT_ID"],
        sas_date(txn_date),
        txn_type,
        money(amount),
        rng.choice(CHANNELS),
        rng.choice(MERCHANT_CATEGORIES),
        f"{txn_type} {rng.choice(CHANNELS)} REF{rng.randint(100000, 999999)}",
        sas_date(txn_date + timedelta(days=rng.choices([0, 1], weights=[85, 15], k=1)[0])),
        "USD",
    ]


TXN_HEADER = [
    "TRANSACTION_ID", "ACCOUNT_ID", "TRANSACTION_DATE", "TRANSACTION_TYPE",
    "TRANSACTION_AMOUNT", "CHANNEL", "MERCHANT_CATEGORY", "DESCRIPTION",
    "POST_DATE", "CURRENCY_CODE",
]


def build_txn_history(rng, accounts):
    """90 days of curated history — the baseline for anomaly z-scores."""
    active = [a for a in accounts if a["ACCOUNT_STATUS"] == "A"]
    rows = []
    seq = 0
    for offset in range(HISTORY_DAYS, 0, -1):
        txn_date = BUSINESS_DATE - timedelta(days=offset)
        for account in active:
            if rng.random() > 0.35:
                continue
            for _ in range(rng.choices([1, 2, 3], weights=[65, 26, 9], k=1)[0]):
                seq += 1
                rows.append(_txn_row(rng, seq, account, txn_date, "H"))
    return rows


def build_txn_feed(rng, accounts):
    """The daily feed, including deliberately malformed rows for the
    validation step and outliers that trip anomaly detection."""
    active = [a for a in accounts if a["ACCOUNT_STATUS"] == "A"]
    rows = []
    seq = 0
    for account in active:
        for _ in range(rng.choices([0, 1, 2, 3, 6], weights=[22, 40, 22, 12, 4], k=1)[0]):
            seq += 1
            row = _txn_row(rng, seq, account, BUSINESS_DATE, "T")
            # Outliers: large withdrawals that trip HIGH_AMOUNT / OVERDRAFT.
            if rng.random() < 0.012:
                row[3] = "WDR"
                row[4] = money(round(abs(account["CURRENT_BALANCE"]) * rng.uniform(1.1, 3.0) + 500, 2))
            rows.append(row)

    def bad(account, mutate):
        nonlocal seq
        seq += 1
        row = _txn_row(rng, seq, account, BUSINESS_DATE, "T")
        mutate(row)
        rows.append(row)

    sample = rng.sample(active, 12)
    for account in sample[0:2]:
        bad(account, lambda r: r.__setitem__(0, ""))                       # missing TRANSACTION_ID
    for account in sample[2:4]:
        bad(account, lambda r: r.__setitem__(1, ""))                       # missing ACCOUNT_ID
    for account in sample[4:6]:
        bad(account, lambda r: r.__setitem__(4, ""))                       # missing amount
    for account in sample[6:8]:
        bad(account, lambda r: r.__setitem__(4, money(rng.uniform(1.1e7, 4e7))))  # over threshold
    for account in sample[8:10]:
        bad(account, lambda r: r.__setitem__(3, rng.choice(["XFR", "MISC"])))     # invalid type
    for account in sample[10:12]:
        bad(account, lambda r: r.__setitem__(
            2, sas_date(BUSINESS_DATE + timedelta(days=rng.randint(1, 5)))))      # future dated
    return rows


def build_daily_rates(rng):
    rows = []
    for offset in range(HISTORY_DAYS, -1, -1):
        rate_date = BUSINESS_DATE - timedelta(days=offset)
        for rate_type, base in (("PRIME", 0.0850), ("FEDFUNDS", 0.0533),
                                ("SOFR", 0.0531), ("LIBOR_3M", 0.0559),
                                ("MTG_30YR", 0.0669)):
            rows.append([sas_date(rate_date), rate_type,
                         f"{base + rng.uniform(-0.0006, 0.0006):.6f}"])
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "csv"))
    args = parser.parse_args()

    rng = random.Random(SEED)
    customers = build_customers(rng)
    accounts = build_accounts(rng, customers)

    print(f"Generating seed data for business date {sas_date(BUSINESS_DATE)}")

    write_csv(
        os.path.join(args.out, "oracle_dw", "CUST_DEMOGRAPHICS.csv"),
        ["CUSTOMER_ID", "FIRST_NAME", "LAST_NAME", "SSN_HASH", "DATE_OF_BIRTH",
         "CUSTOMER_SEGMENT", "RISK_RATING", "REGION_CODE", "PRIMARY_EMAIL", "PHONE_NUMBER"],
        [[c["CUSTOMER_ID"], c["FIRST_NAME"], c["LAST_NAME"], c["SSN_HASH"],
          sas_date(c["DATE_OF_BIRTH"]), c["CUSTOMER_SEGMENT"], c["RISK_RATING"],
          c["REGION_CODE"], c["PRIMARY_EMAIL"], c["PHONE_NUMBER"]] for c in customers],
    )

    write_csv(
        os.path.join(args.out, "oracle_dw", "CUST_ACCOUNTS.csv"),
        ["ACCOUNT_ID", "CUSTOMER_ID", "ACCOUNT_TYPE", "ACCOUNT_STATUS", "OPEN_DATE",
         "CLOSE_DATE", "CURRENT_BALANCE", "AVAILABLE_BALANCE", "CREDIT_LIMIT",
         "INTEREST_RATE", "BRANCH_ID", "OFFICER_ID", "LAST_ACTIVITY_DATE"],
        [[a["ACCOUNT_ID"], a["CUSTOMER_ID"], a["ACCOUNT_TYPE"], a["ACCOUNT_STATUS"],
          sas_date(a["OPEN_DATE"]), sas_date(a["CLOSE_DATE"]), money(a["CURRENT_BALANCE"]),
          money(a["AVAILABLE_BALANCE"]), money(a["CREDIT_LIMIT"]), a["INTEREST_RATE"],
          a["BRANCH_ID"], a["OFFICER_ID"], sas_date(a["LAST_ACTIVITY_DATE"])] for a in accounts],
    )

    write_csv(
        os.path.join(args.out, "oracle_dw", "BUREAU_SCORES.csv"),
        ["CUSTOMER_ID", "SCORE_DATE", "FICO_SCORE", "VANTAGE_SCORE", "BUREAU_INQS_6MO",
         "BUREAU_TRADES_OPEN", "BUREAU_DEROGS", "BUREAU_UTIL_PCT", "BUREAU_OLDEST_TRADE_MO"],
        build_bureau_scores(rng, customers),
    )

    write_csv(
        os.path.join(args.out, "oracle_dw", "PAYMENT_HISTORY.csv"),
        ["ACCOUNT_ID", "PMT_ONTIME_12MO", "PMT_LATE_30_12MO", "PMT_LATE_60_12MO",
         "PMT_LATE_90_12MO", "MAX_DAYS_PAST_DUE_EVER", "MONTHS_SINCE_LAST_DPD",
         "AVG_PMT_RATIO_12MO"],
        build_payment_history(rng, accounts),
    )

    collateral = build_collateral(rng, accounts)
    write_csv(
        os.path.join(args.out, "oracle_dw", "COLLATERAL.csv"),
        ["ACCOUNT_ID", "COLLATERAL_VALUE", "LAST_APPRAISAL_DATE"],
        collateral,
    )

    # LOAN_DETAILS.LTV mirrors the collateral file so the regulatory risk
    # weights and the scorecard agree on the same loan-to-value.
    balances = {a["ACCOUNT_ID"]: a["CURRENT_BALANCE"] for a in accounts}
    ltv_by_account = {
        row[0]: f"{balances[row[0]] / float(row[1]):.4f}" for row in collateral
    }
    loan_details = build_loan_details(rng, accounts)
    for row in loan_details:
        row[5] = ltv_by_account.get(row[0], "")
    write_csv(
        os.path.join(args.out, "oracle_dw", "LOAN_DETAILS.csv"),
        ["ACCOUNT_ID", "LOAN_PURPOSE", "ORIG_AMOUNT", "ORIG_DATE", "TERM_MONTHS",
         "LTV", "DAYS_PAST_DUE", "PAST_DUE_AMOUNT", "ALLOWANCE_AMT"],
        loan_details,
    )

    write_csv(
        os.path.join(args.out, "curated", "DAILY_TRANSACTIONS.csv"),
        TXN_HEADER, build_txn_history(rng, accounts),
    )

    feed_name = f"TXN_FEED_{BUSINESS_DATE:%Y%m%d}.csv"
    write_csv(os.path.join(args.out, "raw_bank", feed_name),
              TXN_HEADER, build_txn_feed(rng, accounts))

    write_csv(os.path.join(args.out, "raw_bank", "DAILY_RATES.csv"),
              ["RATE_DATE", "RATE_TYPE", "RATE_VALUE"], build_daily_rates(rng))


if __name__ == "__main__":
    main()
