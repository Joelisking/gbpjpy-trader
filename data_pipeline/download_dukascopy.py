"""
Download GBPJPY and EURJPY M1/M5 historical data from Dukascopy.

Adapted from the working xauusd-trader implementation.
Free data, no API key required. Goes back to 2003.

Usage:
    uv run python data_pipeline/download_dukascopy.py
    uv run python data_pipeline/download_dukascopy.py --start 2010 --symbol GBPJPY
    uv run python data_pipeline/download_dukascopy.py --no-cache   # re-download all

Outputs:
    data/GBPJPY_M1.parquet
    data/GBPJPY_M5.parquet
    data/EURJPY_M1.parquet
    data/EURJPY_M5.parquet

Resumable — already-downloaded hours are cached in data/_dukascopy_cache/.
"""
from __future__ import annotations

import argparse
import lzma
import struct
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pandas as pd
import requests

DATA_DIR  = Path(__file__).parent.parent / "data"
CACHE_DIR = DATA_DIR / "_dukascopy_cache"

_BASE_URL = (
    "https://datafeed.dukascopy.com/datafeed"
    "/{symbol}/{year}/{month:02d}/{day:02d}/{hour:02d}h_ticks.bi5"
)

# Dukascopy stores prices as integers — divide by 1000 for JPY pairs and gold
_POINT_DIVISOR = 1000.0

_TICK_STRUCT = struct.Struct(">IIIff")   # uint32 ms, uint32 ask, uint32 bid, float ask_vol, float bid_vol
_TICK_SIZE   = _TICK_STRUCT.size         # 20 bytes


# ── Parser ────────────────────────────────────────────────────────────────────

def parse_bi5(data: bytes, hour_start: datetime) -> list[dict]:
    """Parse a raw (still-compressed) bi5 file into a list of tick dicts."""
    if not data or len(data) < 4:
        return []
    try:
        decompressed = lzma.decompress(data)
    except lzma.LZMAError:
        return []

    n_ticks = len(decompressed) // _TICK_SIZE
    ticks = []
    for i in range(n_ticks):
        ms, ask_raw, bid_raw, ask_vol, bid_vol = _TICK_STRUCT.unpack_from(decompressed, i * _TICK_SIZE)
        tick_time = hour_start + timedelta(milliseconds=ms)
        ask    = ask_raw / _POINT_DIVISOR
        bid    = bid_raw / _POINT_DIVISOR
        spread = round(ask - bid, 3)
        ticks.append({
            "time":   tick_time,
            "bid":    bid,
            "ask":    ask,
            "mid":    (ask + bid) / 2.0,
            "spread": spread,
            "volume": ask_vol + bid_vol,
        })
    return ticks


# ── Downloader ────────────────────────────────────────────────────────────────

def download_hour(symbol: str, dt: datetime, session: requests.Session, use_cache: bool = True) -> list[dict]:
    """Download and parse ticks for one hour. Returns empty list on failure/no data."""
    cache_file = CACHE_DIR / symbol / f"{dt.year}/{dt.month:02d}/{dt.day:02d}/{dt.hour:02d}.bi5"

    if use_cache and cache_file.exists():
        data = cache_file.read_bytes()
        return parse_bi5(data, dt) if data else []

    url = _BASE_URL.format(
        symbol=symbol,
        year=dt.year,
        month=dt.month - 1,   # Dukascopy months are 0-indexed
        day=dt.day,
        hour=dt.hour,
    )

    try:
        resp = session.get(url, timeout=15)
        cache_file.parent.mkdir(parents=True, exist_ok=True)
        if resp.status_code == 200 and resp.content:
            cache_file.write_bytes(resp.content)
            return parse_bi5(resp.content, dt)
        else:
            cache_file.write_bytes(b"")   # mark as confirmed empty
            return []
    except requests.RequestException:
        return []


# ── Aggregation ───────────────────────────────────────────────────────────────

def ticks_to_bars(ticks: list[dict], timeframe: str) -> pd.DataFrame:
    """Resample tick list to OHLCV bars."""
    if not ticks:
        return pd.DataFrame()

    tf_map = {"M1": "1min", "M5": "5min"}
    rule = tf_map[timeframe]

    df = pd.DataFrame(ticks)
    df["time"] = pd.to_datetime(df["time"], utc=True)
    df = df.set_index("time")

    ohlc       = df["mid"].resample(rule).ohlc().dropna()
    vol        = df["volume"].resample(rule).sum()
    spread_avg = df["spread"].resample(rule).mean()
    tick_count = df["mid"].resample(rule).count()

    result = pd.DataFrame({
        "open":        ohlc["open"],
        "high":        ohlc["high"],
        "low":         ohlc["low"],
        "close":       ohlc["close"],
        "tick_volume": tick_count.loc[ohlc.index],
        "spread":      (spread_avg.loc[ohlc.index] * _POINT_DIVISOR).astype(int),
        "real_volume": vol.loc[ohlc.index],
    }, index=ohlc.index)

    result.index = result.index.tz_localize(None)   # strip UTC — matches MT5 format
    result.index.name = "timestamp"
    return result


# ── Main download loop ────────────────────────────────────────────────────────

# Flush M1/M5 bars to disk every N hours to keep memory bounded
_FLUSH_EVERY_HOURS = 24 * 30  # monthly


def download_symbol(
    symbol: str,
    start_year: int,
    end_dt: datetime,
    use_cache: bool = True,
) -> dict[str, pd.DataFrame]:
    """
    Download tick data hour-by-hour, resample to M1/M5 immediately,
    and flush to disk monthly. Keeps memory bounded regardless of date range.
    """
    start = datetime(start_year, 1, 1, tzinfo=timezone.utc)
    end   = min(end_dt, datetime.now(timezone.utc))

    total_hours = int((end - start).total_seconds() / 3600)
    print(f"\nDownloading {symbol}: {start.date()} → {end.date()} ({total_hours:,} hours)")
    print(f"Cache: {CACHE_DIR / symbol}\n")

    session = requests.Session()
    session.headers["User-Agent"] = "Mozilla/5.0 (compatible; trading-research/1.0)"
    session.headers["Referer"]    = "https://freeserv.dukascopy.com"

    # Accumulate bars (not ticks) — ~60 M1 bars/hour vs ~1000 ticks/hour
    m1_chunks: list[pd.DataFrame] = []
    m5_chunks: list[pd.DataFrame] = []
    hour_bars: list[dict] = []  # ticks for current hour only

    # Chunk parquet files written to disk during the run
    chunk_dir = DATA_DIR / f"_{symbol}_chunks"
    chunk_dir.mkdir(exist_ok=True)
    chunk_index = 0

    current     = start
    processed   = 0
    bars_m1     = 0
    last_report = time.time()
    flush_count = 0

    def flush_to_disk():
        nonlocal chunk_index, m1_chunks, m5_chunks, bars_m1
        if not m1_chunks:
            return
        df_m1 = pd.concat(m1_chunks)
        df_m5 = pd.concat(m5_chunks)
        p = chunk_dir / f"chunk_{chunk_index:04d}.parquet"
        df_m1.to_parquet(p)
        df_m5.to_parquet(chunk_dir / f"chunk_{chunk_index:04d}_m5.parquet")
        print(f"\n  [flush] chunk {chunk_index}: {len(df_m1):,} M1 bars → {p.name}")
        chunk_index += 1
        m1_chunks = []
        m5_chunks = []
        bars_m1   = 0

    while current < end:
        ticks = download_hour(symbol, current, session, use_cache=use_cache)

        if ticks:
            h_m1 = ticks_to_bars(ticks, "M1")
            h_m5 = ticks_to_bars(ticks, "M5")
            if not h_m1.empty:
                m1_chunks.append(h_m1)
                m5_chunks.append(h_m5)
                bars_m1 += len(h_m1)

        processed += 1
        current   += timedelta(hours=1)

        # Flush to disk periodically to free memory
        if processed % _FLUSH_EVERY_HOURS == 0:
            flush_to_disk()
            flush_count += 1

        if time.time() - last_report >= 5.0 or processed == total_hours:
            pct = 100 * processed / total_hours
            eta = (total_hours - processed) * 0.05 / 60  # ~0.05s/req
            print(
                f"\r  {pct:5.1f}%  {current.strftime('%Y-%m-%d')}  "
                f"M1 bars (in mem): {bars_m1:,}  ETA: {eta:.0f}min",
                end="", flush=True,
            )
            last_report = time.time()

        time.sleep(0.05)

    print()
    flush_to_disk()  # final flush

    # Combine all chunks from disk
    print(f"  Combining {chunk_index} chunks...")
    all_m1 = sorted(chunk_dir.glob("chunk_*[0-9].parquet"))
    all_m5 = sorted(chunk_dir.glob("chunk_*_m5.parquet"))

    if not all_m1:
        print(f"  ERROR: No data for {symbol}")
        return {}

    df_m1 = pd.concat([pd.read_parquet(f) for f in all_m1])
    df_m5 = pd.concat([pd.read_parquet(f) for f in all_m5])

    df_m1 = df_m1[~df_m1.index.duplicated(keep="last")].sort_index()
    df_m5 = df_m5[~df_m5.index.duplicated(keep="last")].sort_index()

    # Clean up chunk files
    import shutil
    shutil.rmtree(chunk_dir)

    return {"M1": df_m1, "M5": df_m5}


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Download GBPJPY/EURJPY M1+M5 data from Dukascopy")
    parser.add_argument("--start",    type=int, default=2003,     help="Start year (default: 2003)")
    parser.add_argument("--symbol",   type=str, default=None,     help="Single symbol (default: both GBPJPY and EURJPY)")
    parser.add_argument("--no-cache", action="store_true",        help="Re-download all (ignore cache)")
    args = parser.parse_args()

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    symbols   = [args.symbol] if args.symbol else ["GBPJPY", "EURJPY"]
    end_dt    = datetime.now(timezone.utc)
    use_cache = not args.no_cache

    for symbol in symbols:
        bars = download_symbol(symbol, args.start, end_dt, use_cache)

        for tf, df in bars.items():
            if df.empty:
                print(f"  WARNING: No {tf} bars for {symbol}")
                continue

            out_path = DATA_DIR / f"{symbol}_{tf}.parquet"

            if out_path.exists():
                out_path.rename(out_path.with_suffix(".parquet.bak"))

            df.to_parquet(out_path)
            print(f"  Saved {len(df):,} {tf} bars → {out_path}")
            print(f"  Range: {df.index[0]} to {df.index[-1]}")

    print("\nDone. Run: uv run python data_pipeline/data_validator.py")


if __name__ == "__main__":
    main()
