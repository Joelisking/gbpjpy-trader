"""
Export historical price data from MetaTrader 5 to Parquet/CSV.

Usage (on Windows VPS with MT5 installed):
    python data_pipeline/export_mt5_data.py

Exports:
    data/GBPJPY_M1.parquet
    data/GBPJPY_M5.parquet
    data/GBPJPY_H1.parquet
    data/GBPJPY_H4.parquet
    data/GBPJPY_W1.parquet
    data/EURJPY_M1.parquet
    data/EURJPY_M5.parquet
    data/EURJPY_H1.parquet
"""
import os
import sys
from datetime import datetime

import pandas as pd

DATA_DIR = os.path.join(os.path.dirname(__file__), "..", "data")
EXPORT_START = datetime(2003, 1, 1)
EXPORT_END = datetime.now()

SYMBOLS_AND_TIMEFRAMES = [
    ("GBPJPY", "M1"),
    ("GBPJPY", "M5"),
    ("GBPJPY", "H1"),
    ("GBPJPY", "H4"),
    ("GBPJPY", "W1"),
    ("EURJPY", "M1"),
    ("EURJPY", "M5"),
    ("EURJPY", "H1"),
]


def get_mt5_timeframe(tf_str: str):
    """Map timeframe string to MT5 constant."""
    import MetaTrader5 as mt5
    mapping = {
        "M1": mt5.TIMEFRAME_M1,
        "M5": mt5.TIMEFRAME_M5,
        "H1": mt5.TIMEFRAME_H1,
        "H4": mt5.TIMEFRAME_H4,
        "W1": mt5.TIMEFRAME_W1,
    }
    return mapping[tf_str]


CHUNK_SIZE = 99_000  # MT5 hard cap is 100k bars per call — stay just under


def export_symbol(symbol: str, tf_str: str) -> pd.DataFrame:
    """Fetch all available history in chunks to work around MT5's 100k bar limit."""
    import MetaTrader5 as mt5

    tf = get_mt5_timeframe(tf_str)
    chunks = []
    fetch_end = EXPORT_END

    print(f"  Fetching in chunks (MT5 limit: 100k bars/call)...")

    while True:
        rates = mt5.copy_rates_range(symbol, tf, EXPORT_START, fetch_end)

        if rates is None or len(rates) == 0:
            break

        chunk = pd.DataFrame(rates)
        chunk["time"] = pd.to_datetime(chunk["time"], unit="s")
        chunk = chunk.set_index("time")
        chunk = chunk.sort_index()
        chunks.append(chunk)

        earliest = chunk.index[0]
        print(f"    Chunk: {len(chunk):,} bars | {earliest} → {chunk.index[-1]}")

        # If we got fewer bars than the chunk size, we've reached the full history
        if len(rates) < CHUNK_SIZE:
            break

        # If the earliest bar is already at or before our target start, done
        if earliest <= pd.Timestamp(EXPORT_START):
            break

        # Move the end window back by 1 minute before the earliest bar we got
        fetch_end = (earliest - pd.Timedelta(minutes=1)).to_pydatetime()

    if not chunks:
        print(f"  WARNING: No data returned for {symbol} {tf_str}")
        return pd.DataFrame()

    df = pd.concat(chunks)
    df = df[~df.index.duplicated(keep="last")]
    df = df.sort_index()
    df = df.rename(columns={
        "open": "open",
        "high": "high",
        "low": "low",
        "close": "close",
        "tick_volume": "volume",
        "spread": "spread",
        "real_volume": "real_volume",
    })
    df.index.name = "timestamp"
    return df


def validate_dataframe(df: pd.DataFrame, symbol: str, tf_str: str) -> bool:
    """Basic data quality checks."""
    ok = True

    if df.empty:
        print(f"  ERROR: Empty dataframe for {symbol} {tf_str}")
        return False

    # Check for duplicate timestamps
    dupes = df.index.duplicated().sum()
    if dupes > 0:
        print(f"  WARNING: {dupes} duplicate timestamps — dropping")
        df.drop_duplicates(inplace=True)

    # Check for NaN values
    nans = df[["open", "high", "low", "close"]].isna().sum().sum()
    if nans > 0:
        print(f"  WARNING: {nans} NaN values in OHLC — forward-filling")
        df[["open", "high", "low", "close"]] = df[["open", "high", "low", "close"]].ffill()

    # Check for negative prices
    if (df[["open", "high", "low", "close"]] <= 0).any().any():
        print(f"  ERROR: Negative or zero prices found in {symbol} {tf_str}")
        ok = False

    # Check OHLC consistency
    invalid_ohlc = (df["high"] < df["low"]) | (df["high"] < df["open"]) | (df["high"] < df["close"])
    if invalid_ohlc.any():
        print(f"  WARNING: {invalid_ohlc.sum()} candles with invalid OHLC relationships")

    return ok


def check_gaps(df: pd.DataFrame, tf_str: str) -> None:
    """Report on gaps in M1 data (should be < 5 minutes for quality)."""
    if tf_str != "M1" or df.empty:
        return

    time_diffs = df.index.to_series().diff().dropna()
    gap_threshold = pd.Timedelta(minutes=5)
    gaps = time_diffs[time_diffs > gap_threshold]

    if len(gaps) > 0:
        print(f"  INFO: {len(gaps)} gaps > 5 minutes in M1 data")
        largest = gaps.nlargest(5)
        for ts, gap in largest.items():
            print(f"    Gap at {ts}: {gap}")
    else:
        print(f"  OK: No gaps > 5 minutes in M1 data")


def main():
    try:
        import MetaTrader5 as mt5
    except ImportError:
        print("MetaTrader5 package not found. Install with: pip install MetaTrader5")
        print("Note: MT5 must be running on a Windows machine.")
        sys.exit(1)

    if not mt5.initialize():
        print(f"MT5 initialization failed: {mt5.last_error()}")
        sys.exit(1)

    print(f"MT5 connected. Terminal version: {mt5.terminal_info().build}")
    os.makedirs(DATA_DIR, exist_ok=True)

    for symbol, tf_str in SYMBOLS_AND_TIMEFRAMES:
        filename = f"{symbol}_{tf_str}.parquet"
        filepath = os.path.join(DATA_DIR, filename)

        print(f"\nExporting {symbol} {tf_str}...")
        df = export_symbol(symbol, tf_str)

        if df.empty:
            continue

        valid = validate_dataframe(df, symbol, tf_str)
        check_gaps(df, tf_str)

        if valid:
            df.to_parquet(filepath)
            print(f"  Saved {len(df):,} bars → {filepath}")
            print(f"  Range: {df.index[0]} to {df.index[-1]}")
        else:
            print(f"  SKIPPED due to validation errors")

    mt5.shutdown()
    print("\nExport complete.")


if __name__ == "__main__":
    main()
