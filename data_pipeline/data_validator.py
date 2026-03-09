"""
Validate exported MT5 data before feeding into the AI training pipeline.

Usage:
    python data_pipeline/data_validator.py

Checks:
  - File existence and row counts
  - Duplicate timestamps
  - NaN / zero values in OHLC
  - Invalid OHLC relationships (high < low, etc.)
  - Gaps > 5 minutes in M1 data
  - Date range coverage
  - GBP/JPY minimum pip value sanity (1 pip ≈ 0.01)
"""
import os
import sys

import pandas as pd

DATA_DIR = os.path.join(os.path.dirname(__file__), "..", "data")

REQUIRED_FILES = {
    "GBPJPY_M1.parquet": {"min_rows": 4_000_000, "tf_minutes": 1},
    "GBPJPY_M5.parquet": {"min_rows": 800_000, "tf_minutes": 5},
    "GBPJPY_H1.parquet": {"min_rows": 50_000, "tf_minutes": 60},
    "GBPJPY_H4.parquet": {"min_rows": 15_000, "tf_minutes": 240},
    "GBPJPY_W1.parquet": {"min_rows": 1_000, "tf_minutes": None},
    "EURJPY_M1.parquet": {"min_rows": 4_000_000, "tf_minutes": 1},
    "EURJPY_M5.parquet": {"min_rows": 800_000, "tf_minutes": 5},
    "EURJPY_H1.parquet": {"min_rows": 50_000, "tf_minutes": 60},
}

GBPJPY_PRICE_RANGE = (80.0, 250.0)   # sanity bounds — pips checked against 0.01 unit
MIN_DATE = pd.Timestamp("2003-01-01")


def validate_file(filename: str, config: dict) -> dict:
    filepath = os.path.join(DATA_DIR, filename)
    result = {"file": filename, "errors": [], "warnings": [], "ok": True}

    if not os.path.exists(filepath):
        result["errors"].append("FILE NOT FOUND")
        result["ok"] = False
        return result

    df = pd.read_parquet(filepath)
    result["rows"] = len(df)
    result["start"] = str(df.index.min())
    result["end"] = str(df.index.max())

    # Row count
    if len(df) < config["min_rows"]:
        result["warnings"].append(
            f"Only {len(df):,} rows — expected ≥ {config['min_rows']:,}. "
            "Download more history from MT5 History Center."
        )

    # Date range
    if df.index.min() > MIN_DATE + pd.Timedelta(days=30):
        result["warnings"].append(f"Data starts {df.index.min()} — should start near 2003-01-01")

    # Duplicate timestamps
    dupes = df.index.duplicated().sum()
    if dupes > 0:
        result["warnings"].append(f"{dupes} duplicate timestamps")

    # NaN in OHLC
    nans = df[["open", "high", "low", "close"]].isna().sum().sum()
    if nans > 0:
        result["errors"].append(f"{nans} NaN values in OHLC columns")
        result["ok"] = False

    # Zero or negative prices
    bad_prices = (df[["open", "high", "low", "close"]] <= 0).any().any()
    if bad_prices:
        result["errors"].append("Zero or negative prices found")
        result["ok"] = False

    # Price sanity range
    price_min = df["close"].min()
    price_max = df["close"].max()
    if "GBPJPY" in filename:
        lo, hi = GBPJPY_PRICE_RANGE
        if price_min < lo or price_max > hi:
            result["warnings"].append(
                f"Price range {price_min:.2f}–{price_max:.2f} outside expected {lo}–{hi}"
            )

    # OHLC consistency
    bad_hl = (df["high"] < df["low"]).sum()
    bad_ho = (df["high"] < df["open"]).sum()
    bad_hc = (df["high"] < df["close"]).sum()
    bad_lo = (df["low"] > df["open"]).sum()
    bad_lc = (df["low"] > df["close"]).sum()
    total_bad = bad_hl + bad_ho + bad_hc + bad_lo + bad_lc
    if total_bad > 0:
        result["warnings"].append(f"{total_bad} candles with OHLC consistency violations")

    # Gap analysis for M1 data
    tf_min = config["tf_minutes"]
    if tf_min == 1:
        time_diffs = df.index.to_series().diff().dropna()
        gap_threshold = pd.Timedelta(minutes=5)
        gaps = time_diffs[time_diffs > gap_threshold]
        result["gaps_over_5min"] = len(gaps)
        if len(gaps) > 100:
            result["warnings"].append(
                f"{len(gaps)} gaps > 5 minutes in M1 — check Dukascopy download for complete history"
            )
        # Weekend gaps are normal — count weekday gaps only
        weekday_gaps = gaps[gaps.index.dayofweek < 5]
        if len(weekday_gaps) > 50:
            result["warnings"].append(f"{len(weekday_gaps)} weekday gaps > 5 min in M1")

    return result


def print_result(r: dict) -> None:
    status = "✅ OK" if r["ok"] and not r.get("warnings") else (
        "⚠️  WARN" if r["ok"] else "❌ FAIL"
    )
    print(f"\n{status}  {r['file']}")
    if "rows" in r:
        print(f"       Rows: {r['rows']:,}  |  {r['start']} → {r['end']}")
    for e in r["errors"]:
        print(f"       ERROR: {e}")
    for w in r["warnings"]:
        print(f"       WARN:  {w}")


def main():
    print("GBP/JPY Bot — Data Validation Report")
    print("=" * 50)

    any_fail = False
    for filename, config in REQUIRED_FILES.items():
        result = validate_file(filename, config)
        print_result(result)
        if not result["ok"]:
            any_fail = True

    print("\n" + "=" * 50)
    if any_fail:
        print("❌ Validation FAILED — fix errors before proceeding to Phase 3 (AI training)")
        sys.exit(1)
    else:
        print("✅ All files passed validation. Ready for feature engineering.")


if __name__ == "__main__":
    main()
