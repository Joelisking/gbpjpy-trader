"""
Download historical tick data from Dukascopy and resample to M1 / M5 OHLCV.

Free data back to 2003. No account required.

Usage:
    uv run python data_pipeline/download_dukascopy.py

Outputs:
    data/GBPJPY_M1.parquet   (replaces the broker-limited version)
    data/GBPJPY_M5.parquet
    data/EURJPY_M1.parquet
    data/EURJPY_M5.parquet

Runtime: ~2-4 hours for full GBPJPY M1 history (2003-present).
The script is resumable — it skips hours already downloaded.
"""
import lzma
import os
import struct
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pandas as pd
import requests

DATA_DIR = Path(__file__).parent.parent / "data"
CACHE_DIR = Path(__file__).parent.parent / "data" / "_dukascopy_cache"

BASE_URL = "https://datafeed.dukascopy.com/datafeed/{symbol}/{year}/{month:02d}/{day:02d}/{hour:02d}h_ticks.bi5"

SYMBOLS = ["GBPJPY", "EURJPY"]
START_YEAR = 2003
END_DATE = datetime.now(timezone.utc)

# Dukascopy price divisor — applies to all pairs including JPY crosses
PRICE_DIVISOR = 100_000.0

SESSION = requests.Session()
SESSION.headers["User-Agent"] = "Mozilla/5.0"


# ── Binary parser ─────────────────────────────────────────────────────────────

def parse_bi5(data: bytes, hour_dt: datetime) -> pd.DataFrame:
    """
    Parse a Dukascopy .bi5 tick file into a DataFrame.

    Each tick record = 20 bytes (big-endian):
      uint32  time_ms   — milliseconds since start of the hour
      uint32  ask       — ask price * 100000
      uint32  bid       — bid price * 100000
      float32 ask_vol
      float32 bid_vol
    """
    if not data:
        return pd.DataFrame()

    record_size = 20
    n_records = len(data) // record_size
    if n_records == 0:
        return pd.DataFrame()

    rows = []
    hour_ts = hour_dt.timestamp() * 1000  # ms

    for i in range(n_records):
        offset = i * record_size
        time_ms, ask_raw, bid_raw, ask_vol, bid_vol = struct.unpack_from(
            ">IIIff", data, offset
        )
        ts = pd.Timestamp((hour_ts + time_ms) / 1000, unit="s", tz="UTC")
        mid = ((ask_raw + bid_raw) / 2) / PRICE_DIVISOR
        rows.append((ts, ask_raw / PRICE_DIVISOR, bid_raw / PRICE_DIVISOR, mid))

    df = pd.DataFrame(rows, columns=["timestamp", "ask", "bid", "mid"])
    df = df.set_index("timestamp")
    return df


# ── Downloader ────────────────────────────────────────────────────────────────

def download_hour(symbol: str, year: int, month: int, day: int, hour: int) -> bytes | None:
    """Download and decompress one hour of tick data. Returns None on 404."""
    cache_path = CACHE_DIR / symbol / f"{year}" / f"{month:02d}" / f"{day:02d}_{hour:02d}.bi5"

    if cache_path.exists():
        return cache_path.read_bytes() or None  # empty file = confirmed 404

    url = BASE_URL.format(symbol=symbol, year=year, month=month - 1, day=day, hour=hour)

    for attempt in range(3):
        try:
            resp = SESSION.get(url, timeout=30)
            if resp.status_code == 404:
                cache_path.parent.mkdir(parents=True, exist_ok=True)
                cache_path.write_bytes(b"")  # mark as confirmed empty
                return None
            resp.raise_for_status()
            compressed = resp.content
            decompressed = lzma.decompress(compressed)
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_bytes(decompressed)
            return decompressed
        except lzma.LZMAError:
            # Some hours have no data (returns non-lzma content)
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_bytes(b"")
            return None
        except requests.RequestException as e:
            if attempt == 2:
                print(f"    WARNING: Failed to download {url}: {e}")
                return None
            time.sleep(2 ** attempt)

    return None


def download_symbol_ticks(symbol: str) -> pd.DataFrame:
    """Download all available tick data for a symbol, return as DataFrame."""
    print(f"\nDownloading {symbol} tick data from Dukascopy (2003 → now)...")
    print(f"Cache: {CACHE_DIR / symbol}")
    print("This will take 2-4 hours for full M1 history. Resumable if interrupted.\n")

    all_chunks = []
    current = datetime(START_YEAR, 1, 1, tzinfo=timezone.utc)
    end = END_DATE.replace(minute=0, second=0, microsecond=0)

    total_hours = int((end - current).total_seconds() / 3600)
    processed = 0
    ticks_total = 0

    while current <= end:
        raw = download_hour(symbol, current.year, current.month, current.day, current.hour)

        if raw:
            chunk = parse_bi5(raw, current)
            if not chunk.empty:
                all_chunks.append(chunk)
                ticks_total += len(chunk)

        processed += 1
        if processed % 500 == 0:
            pct = processed / total_hours * 100
            print(f"  Progress: {pct:.1f}% | {current.date()} | ticks so far: {ticks_total:,}")

        current = current + timedelta(hours=1)

    if not all_chunks:
        print(f"  ERROR: No data downloaded for {symbol}")
        return pd.DataFrame()

    print(f"\n  Combining {len(all_chunks)} hourly chunks ({ticks_total:,} total ticks)...")
    df = pd.concat(all_chunks)
    df = df[~df.index.duplicated(keep="last")]
    df = df.sort_index()
    df.index = df.index.tz_convert(None)  # strip UTC, store as naive (matches MT5)
    return df


# ── Resampler ─────────────────────────────────────────────────────────────────

def resample_to_ohlcv(tick_df: pd.DataFrame, timeframe: str) -> pd.DataFrame:
    """Resample tick mid prices to OHLCV bars."""
    tf_map = {"M1": "1min", "M5": "5min", "H1": "1h", "H4": "4h"}
    rule = tf_map[timeframe]

    mid = tick_df["mid"]
    ohlcv = mid.resample(rule).agg(["first", "max", "min", "last"])
    ohlcv.columns = ["open", "high", "low", "close"]
    ohlcv["volume"] = mid.resample(rule).count()
    ohlcv = ohlcv.dropna(subset=["open"])
    ohlcv.index.name = "timestamp"
    return ohlcv


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    for symbol in SYMBOLS:
        tick_df = download_symbol_ticks(symbol)
        if tick_df.empty:
            continue

        for tf in ["M1", "M5"]:
            print(f"  Resampling {symbol} → {tf}...")
            bars = resample_to_ohlcv(tick_df, tf)
            out_path = DATA_DIR / f"{symbol}_{tf}.parquet"
            bars.to_parquet(out_path)
            print(f"  Saved {len(bars):,} {tf} bars → {out_path}")
            print(f"  Range: {bars.index[0]} to {bars.index[-1]}")

        # Free memory before next symbol
        del tick_df

    print("\nDukascopy download complete.")
    print("Run: uv run python data_pipeline/data_validator.py")


if __name__ == "__main__":
    main()
